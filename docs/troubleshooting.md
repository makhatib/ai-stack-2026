# Troubleshooting

Start here:

```sh
bin/aistack doctor
```

It checks health, pins, whether each service can read its own secret, and
what your host is listening on. Most of the page below is things `doctor`
will tell you first.

## Asking for help

```sh
bin/aistack support-bundle
```

This writes a **redacted** archive you can send to someone. Use it instead of
a screenshot of your terminal — a screenshot is outside any control we can
enforce, and terminals contain more than you think.

The redaction removes the literal value of every secret the stack holds, plus
anything shaped like a key, a token, a bearer header or a database URL. It is
a filter, not a guarantee: it cannot catch a secret that an application chose
to print in a shape nobody anticipated. Glance through the bundle before you
send it.

## A service will not start

```sh
bin/aistack logs <service> --tail 50
```

Known causes, all of which we hit while building this:

**"Permission denied" on a file in `/run/secrets/`.** The secret is not
readable by the user that service runs as. Re-run
`sudo ./scripts/gen-secrets.sh` — it computes the right owner per service
from measured values and will tell you the exact `chown` to run if it cannot
apply one itself.

Worth understanding, because it is counter-intuitive: dropping all Linux
capabilities removes root's permission bypass. A container running as uid 0
**cannot** read a `0600` file owned by your user. Several of these failures
look like application bugs and are file modes.

**n8n exits with `Mismatching encryption keys`** or `Deployment key
'signing.hmac' cannot be read`. `N8N_ENCRYPTION_KEY` changed. n8n records the
key in both its data volume and its database, so both disagree now. If you
have no workflows yet, the quickest fix is to clear both. If you do, restore
a backup from before the key changed — see [upgrade.md](upgrade.md).

**Postgres restart-loops with `find: ... Permission denied`.** The container
is missing a capability it needs to traverse an existing data directory. This
should not happen with the shipped compose file; if you edited `cap_add`, put
`DAC_READ_SEARCH` back.

**Authelia exits with only "Errors occurred performing startup checks".** It
swallows the specific reason at the default log level. Set
`AUTHELIA_LOG_LEVEL=trace` and look again. The two we hit were a config file
it could not read and a file it could not write under the read-only root
filesystem.

## An application says a database role does not exist

Symptoms: LiteLLM, n8n or Open WebUI exits with `password authentication
failed for user "…"` or `Role "…" does not exist`, while Postgres itself looks
fine.

Cause: **Postgres only runs its first-boot init scripts on an empty data
directory.** If that first boot was interrupted part way through — an
unreadable secret file, a power cut, a container killed mid-init — every later
start prints `PostgreSQL Database directory appears to contain a database;
Skipping initialization` and the cluster keeps whichever half of the roles it
managed to create.

```sh
bin/aistack doctor      # names the missing roles and databases
bin/aistack db-init     # re-applies the init in place
```

`db-init` is idempotent: every statement is `IF NOT EXISTS`, so it creates
only what is missing and does not touch an existing role, database or
password. It cannot repair a role whose password has diverged from
`secrets/app_db_passwords` — that is a different problem and deleting a live
role is not a repair we will do for you.

Since this release the health check asserts those roles exist, so this state
reports as **unhealthy** instead of healthy, and `bin/aistack up` prints the
missing objects rather than only naming Postgres.

## Postgres warns about a collation version mismatch

Every connection prints something like:

```
WARNING:  database "n8n" has a collation version mismatch
DETAIL:  The database was created using collation version 2.36, but the
         operating system provides version 2.41.
```

This means the postgres **base image changed under an existing PGDATA**. The
data is fine; what is in doubt is every text index, because each was built
with the sort order of the old library and nothing has rebuilt them.

**Do not just silence it.** `ALTER DATABASE … REFRESH COLLATION VERSION` on
its own re-records the version without rebuilding anything, which hides the
warning and keeps the risk.

Fix it:

```sh
bash scripts/backup.sh                      # the way back, first
bash scripts/migrate-collation.sh --dry-run # what is stale; changes nothing
bash scripts/migrate-collation.sh --yes     # REINDEX, then re-record
bash scripts/preflight-collation.sh         # must print both oks
bin/aistack doctor                          # must be clean
```

It REINDEXes every database, so apps block on those locks while it runs. It is
idempotent — a second run finds nothing stale and says so.

**A base swap can move more than one collation provider.** MEASURED 2026-10-23
(NOM-354): Debian 12 → 13 moved glibc 2.36 → 2.41 **and** ICU 153.120 →
153.128. The warning above names only the glibc one, and `ALTER DATABASE …
REFRESH COLLATION VERSION` covers only the database default — after doing
exactly that, this cluster still held **5663 stale `pg_collation` rows**
(2 libc + 807 ICU per database), and `preflight-collation.sh` reported
`ok — all 7 databases record collation version 2.41` over the top of them.
Postgres warns again as soon as such a collation is named explicitly
(`ORDER BY x COLLATE "en_US.utf8"`). Both scripts now check both catalogs; if
you do this by hand, `ALTER COLLATION … REFRESH VERSION` per stale row is the
step people miss.

To see what is actually stale, per database:

```sh
docker exec aistack-postgres psql -U aistack_admin -d <db> -c "
  SELECT collname, collversion, pg_collation_actual_version(oid)
  FROM pg_collation
  WHERE collversion IS NOT NULL AND collversion <> ''
    AND collversion <> coalesce(pg_collation_actual_version(oid), collversion)"
```

**Before you change the base at all**, `scripts/preflight-collation.sh` is
wired into `update.sh` as step 2 and refuses the swap, so an ordinary
`aistack update` cannot walk into this. A fresh install is unaffected — there
is no existing PGDATA to migrate.

## A health check says unhealthy but the service works

Check the probe before the service. Two of the obvious probes are wrong for
these images: `authelia health` is not a command in 4.39.28, and the LiteLLM
image contains neither `curl` nor `wget`. The shipped compose file already
accounts for both.

## A drill or a restore says the lifecycle lock is held

The stack is up. It holds that lock in shared mode for as long as it is up, so
that a restore cannot run against live volumes. `bin/aistack down` first.

`bin/aistack status` names which mode is held and which process holds it.

## `status` says the lock is free while the stack is serving

Then the small process `bin/aistack up` leaves behind to hold it is gone —
killed, or OOM-killed, or lost with the session that started it. `bin/aistack
doctor` reports this as a FAIL and names the container count.

Nothing is wrong with your services and nothing needs restarting:

```sh
bin/aistack up            # idempotent; re-arms the hold, starts nothing new
```

Until you do, a restore drill is refused only by its own check that no
`aistack-*` container exists — a real backstop, but not the lock contract.

### After a reboot, that is the expected state

A reboot is the one route into it that is not a failure of anything. The hold
lives in a tmpfs, so a boot clears it. Every serving service is `restart:
unless-stopped`, so the containers come back without it. The stack serves, and
the lifecycle lock is free until somebody runs `doctor` or `up`.

This repository ships no systemd unit, so nothing re-arms the hold at boot by
itself. Two things already stand in for one:

```sh
bin/aistack doctor   # FAILs: "N container(s) are running and nothing holds the lifecycle lock"
bin/aistack up       # re-arms the hold; starts nothing new
```

and the restore drill refuses, inside its own exclusive hold, whenever any
`aistack-*` container exists. So there is no window in which a drill can touch
live volumes. What is absent in the meantime is the kernel enforcing that
interlock; the drill's own check is doing it instead.

If this host reboots on a schedule, run `bin/aistack doctor` after a boot —
or `bin/aistack up`, which repairs it whether or not it was broken.

## I cannot reach it in a browser

1. `bin/aistack status` — is Caddy running and healthy?
2. Does your hostname resolve on this machine? Try `getent hosts <hostname>`.
3. Are you using `https://`? Plain HTTP redirects, it does not serve.
4. Your browser will warn about the certificate. That is expected: local mode
   uses Caddy's internal certificate authority, because a publicly trusted
   certificate would require a public DNS record.

If you are trying from a **different device**, see the security FAQ. We have
not tested that path and cannot tell you whether it should work.

## Pulling a model does nothing from the web interface

That is correct behaviour. Ollama has no route off the host. Use:

```sh
bin/aistack models pull llama3.2:3b
```

## Disk is filling up

Models, almost certainly. `bin/aistack doctor` warns past 5 GB of documents,
but model weights dwarf that — a handful of language models is 50–100 GB.
Backups deliberately exclude them, because they are re-downloadable and over
90% of the bytes.

### Reclaiming space: delete by name, never by prune

**The rule.** Write down the exact containers, images and volumes you mean to
remove, then remove them by name — `docker rm`, `docker image rm`,
`docker volume rm`. Never `docker system prune`, never `docker image prune -a`,
never `docker volume prune`. Not with filters, and not "only the dangling
ones".

This is not tidiness. A prune takes no list, so there is nothing to review
before it runs, and on this host a prune would have deleted load-bearing state
three separate times:

- **An untagged image with zero containers can be the pin itself.** MEASURED
  2026-10-20 (NOM-354): `pgvector/pgvector@sha256:7a7e9f22…` (660 MB) and
  `ghcr.io/agentgateway/agentgateway@sha256:9d3e6044…` (298 MB) both showed as
  untagged with no container, and both are the committed pins in
  `versions.env`. The postgres one is also the digest in
  `security-exceptions.yaml` E7 (bound by invariant I9) and the pin in
  `gate.json`. `docker image prune -a` would have deleted both. They looked
  unused because **a pin can be ahead of the runtime**: `aistack-postgres` was
  still running the previous digest, so nothing referenced the new one yet.
- **A cache volume is dangling between the runs that mount it.** MEASURED
  (NOM-349): `aistack-trivy-cache` has no container attached between scans and
  is mounted during one.
- **A tag you no longer run can still be pinned elsewhere.**
  `n8nio/n8n:2.43.7` is pinned by the NOM-258 CI and fresh-install copies under
  `~/apps/.nom258-ci` and `~/apps/.nom258-fresh`.

Before deleting an image, prove nothing pins it:

```sh
grep -rl "<image-id-or-digest>" ~/apps --exclude-dir=.git
```

A hit in a `versions.env`, a rendered `.env`, a compose file,
`security-exceptions.yaml` or `gate.json` means the image is pinned. Keep it,
whatever `docker images` says about containers.

**The build cache is the one safe prune** — `docker builder prune -a` — because
it is neither an image nor a volume, so nothing can pin it. Pass `-a`; without
it the command commonly reports 0 B reclaimed.

**Guarded tool.** `~/ops/reclaim/reclaim.sh --dry-run`, then `--apply`. It
deletes only what `reclaim-allowlist` names, and refuses a target that is in
`live-state`, is some container's image, or has its id in a config file under
`~/apps`. `~/ops/reclaim/held` records what was deliberately not reclaimed and
why — read it before adding a line to the allowlist.

**What is safe to delete in this repo:** `security-report-<UTC>/` directories,
via `bash scripts/prune-reports.sh`. It keeps the newest three automatic
reports and never touches a labelled or cited one.
Old backup archives go the same
way, via `bash scripts/prune-backups.sh` — newest three, and a successful
`bin/aistack backup` has already run it. See [backup and
restore](backup-restore.md) for why three.

### The scan says NOT RUN — too little free disk

`bin/aistack security-check` measures free space before its scan half and
stops rather than scanning into a full disk. A scan that fills the host writes
truncated JSON, and truncated JSON parses as FEWER findings — a quieter report
for a worse scan. Other services on the machine start failing before it
finishes, too.

Only the scan is skipped; the audit half always runs, and the skipped scan is
reported as NOT RUN, never as clean. Either free some space, or scan anyway:

```sh
bin/aistack security-check --allow-low-disk
```

What it wants is room for the largest image it is about to read, plus 2 GB for
the vulnerability database and the report. Ask for the number without running
anything:

```sh
scripts/preflight-disk.sh
```
