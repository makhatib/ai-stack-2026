# Backup and restore

```sh
bin/aistack backup            # local rollback backup
bin/aistack restore <archive> # verify, then restore
bin/aistack drill run         # restore into a throwaway project and check it
```

## What it is called, and why that matters

This is a **local rollback backup**. It is not disaster recovery, and the
command will not describe itself that way. A copy of your data on the same
machine as your data protects you from a bad upgrade, not from losing the
machine.

`bin/aistack backup --offsite <dest>` copies the archive elsewhere. That is
still not disaster recovery until someone has **restored from that copy, on a
different host**. Until then it is a file you hope is good.

## What is in it

In: every **connectable** database except the two named below (dumped
individually, plus global roles), `secrets/` including the n8n encryption key,
your `.env`, your pins, your `config/`, and the data volumes for n8n, Open
WebUI, Caddy and Authelia.

Out, deliberately: **every model volume**. They are re-downloadable and they
are over 90% of the bytes. The manifest inside each archive lists what was
excluded and why, so this is checkable rather than a promise.

Also out, deliberately, and this one is about databases:

| database | why it is not dumped | what you therefore do not get back |
|---|---|---|
| `postgres` | the maintenance database; `initdb` recreates it, and a restore applies the global roles *through* it | anything stored directly in `postgres` |
| `template1` | the template new databases are cloned from; it cannot be dropped while it is the default template, so restoring into it is a cluster-wide hazard rather than a restore | objects an operator added to `template1` so new databases would inherit them |

`template0` is never a candidate: it is not connectable, so `pg_dump` cannot
read it, and `initdb` recreates it.

Both exclusions are recorded **inside** each archive, so the restore path can
state them rather than leaving you to infer the set:

```
aistack verify <archive>     # read-only: says what it would restore, changes nothing
```

`aistack restore` prints the same statement, from the same code, before it
asks you to confirm — so the list is in front of you while you are deciding
to overwrite live data, not after. `verify` is that phase and then an exit;
it is not a second implementation, so the two cannot disagree.

Archives written before this was recorded (anything from before 2026-10-23)
dumped only the four app databases — `authelia`, `litellm`, `n8n`,
`openwebui` — and did not carry `aistack`. Restoring one says so: it reports
that the archive does not state what it left out, which is the honest answer
rather than an empty exclusion list.

The n8n encryption key is in the set on purpose. Without it, every credential
in the database dump is undecryptable, and a backup that restores a workflow
list but none of its credentials is not a backup.

## How many archives are kept

Three, newest first. Each archive is about 240 MB, `bin/aistack update` takes
one before every update, and nothing used to remove any of them — so the
folder grew by 240 MB per update, forever. Retention runs at the end of a
successful backup and bounds `backups/` at roughly 720 MB.

Three is the number because of what reads an archive. The drill reads the
newest one only. A rollback reads the backup taken before the update, in the
words of `bin/aistack rollback`, and that archive has to outlive the update
long enough for the update to be trusted — keeping three lets it survive two
further backups.

Change it with `AISTACK_BACKUP_RETAIN=N bin/aistack backup`, or see for
yourself what would go first:

```sh
scripts/prune-backups.sh              # dry run; deletes nothing
```

Only a name of the shape `aistack-<UTC>.tar.gz.enc` is ever pruned. An archive
you renamed or copied in by hand is left alone, and an `--offsite` copy is
never touched from here.

## Two keys, and you must hold both

`secrets/backup.key` encrypts the archive. `secrets/backup.hmac` signs its
contents list. **Copy both off this machine, as files, through your own
channel.** `bin/aistack backup` nags at every run until you confirm you have.

They are separate on purpose: whoever holds an archive must not thereby be
able to forge its manifest. A restore **refuses to start** without the HMAC
key — it does not quietly fall back to checking digests, because those
digests live inside the very manifest it would be unable to verify.

## What a restore checks before it touches anything

In order, and all of it before a single byte of your data is overwritten:

1. Decrypt.
2. Unpack through an extractor that audits **every member as it writes it** —
   no absolute paths, no `..`, nothing resolving outside the target, no
   symlinks, no hardlinks, no devices or FIFOs. The checks run during
   extraction rather than as a pre-pass, because a pre-pass over a file
   someone else can still modify is a race.
3. Verify the HMAC over the manifest.
4. Verify the member set by **equality**: every listed file present, every
   present file listed, no duplicate paths. Recomputing the digest of each
   *listed* member cannot detect an **added** member, and two entries with the
   same name would silently overwrite each other on extraction. A count match
   is not a set match.
5. Recompute and compare every digest.

Any failure refuses, and nothing has changed.

## Testing that a good backup restores

```sh
bin/aistack drill run
```

Restores into a **separate throwaway project** with its own volumes and
networks, then checks that workflows, credentials, documents, permissions and
the stack's own control database all came back, and destroys the project.

The control database (`aistack`) is checked for **contents**, not only for
existence. A `pg_restore` that loads nothing still leaves the database there,
and that used to print one line of warning on a drill that then passed. The
drill project also no longer pre-creates it, so the restore's own
`CREATE DATABASE` path — the one a restore onto a fresh host depends on — runs
in every drill instead of being short-circuited.

Drilling a **pre-NOM-378 archive** is still a valid thing to do: those record
no database kinds and carry no `aistack` dump, so the drill says so in a note
and asserts the four app databases as before.

**A cluster-kind database is expected to carry rows, and the drill fails one
that comes back with none.** `aistack`'s rows are seeded reference data, not
runtime accumulation — 31 rows across 6 tables, all of them in
`action_state_edges` and `aistack_slot` — so "tables but zero rows" means the
load did not happen, which is the whole point of the check.

The consequence, stated here rather than left to be rediscovered: **if you add
a cluster-kind database that has tables and has not been written to yet, a
correct restore of it will FAIL the drill** with "schema only". That is the
accepted trade (NOM-393). Seed it, or change assertion 5 in `scripts/drill.sh`
and record why here. The decision was deliberately not "require rows only
where a manifest says to expect them": that adds a manifest field nothing
produces today and weakens the assertion in the one case it was written for.

Assertion 5 has unit coverage that needs no window: `tests/drill-assertion5.sh`
extracts the shipped block out of `scripts/drill.sh` and drives it against a
stubbed cluster, including the branches a live drill cannot reach (a database
that is missing afterwards, a cluster that does not answer, a non-numeric
count, a name that is not a bare identifier).

### Marking a drill run that was not a real restore test

`drill-log.txt` is appended by every drill: one line, `<date> PASS|FAIL
<archive>`. A FAIL in it reads as "this archive did not restore", so a run that
failed **on purpose** — fault injection while testing the drill itself — has to
say so, or an operator finds unexplained failures during an incident:

```sh
AISTACK_DRILL_NOTE='NOM-392 fault injection: aistack dump not loaded' \
  bin/aistack drill run
```

The note is appended after the archive as ` # NOTE: <text>`, newlines stripped,
so the first three fields of every line stay what they were. Lines beginning
with `#` in that file are operator annotations and are written by hand; nothing
parses the file, and retention never reads it.

It cannot touch your live data, and that is enforced by a lock rather than by
convention: the drill holds an exclusive lock for its whole lifetime and the
running stack holds a shared one, so the kernel refuses to let both exist.
Not a startup check in each direction — those can race — one lock, two modes.

**What the drill proves:** a good backup restores, and a bad one is refused.

**What it does not prove:** that a restored system cannot reach the network
while it is being restored. That needs host firewall rules and is a later
release. The honest summary for this version: *it proves a backup restores
and proves a bad backup is refused; it does not prove a restore cannot reach
the network.*
