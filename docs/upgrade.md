# Upgrade and rollback

## How upgrades work

```sh
bin/aistack update
```

Ordered, and it stops on the first failure:

1. `docker compose config -q` — the configuration must be valid first.
2. **A backup is taken, and the update aborts if the backup fails.**
3. `versions.env` is copied to `versions.prev.env`.
4. Images are pulled **by digest**.
5. `up -d`, then a bounded health gate.
6. On failure: the failing service is named, its last 50 **redacted** lines
   are printed, and you are given the exact rollback command.

**There is no automatic rollback, and that is on purpose.** Rolling back after
a schema migration has run produces a corrupted database rather than a failed
update. Automatic recovery that corrupts data is worse than stopping.

## What is reversible

| What | Reversible? | How |
|---|---|---|
| image, no migration ran | yes | `bin/aistack rollback` |
| image, **migration ran** (n8n, Authelia, Open WebUI) | **no** | `bin/aistack down`, then `bin/aistack restore <id>`, then `bin/aistack rollback` |
| config | yes | timestamped `.bak`; `bin/aistack config restore <ts>` |
| secret rotation | partly | see below |

**A major-version rollback means restoring a backup.** Those are the words,
and they are the words because the alternative phrasing — "rollback is
supported" — is how people lose a database.

## Stop the stack before you restore

```sh
bin/aistack down
bin/aistack restore <backup.tar.gz.enc>
bin/aistack up          # or `bin/aistack rollback`, which ups for you
```

**`bin/aistack down` is the first line and it is not optional.** A restore
overwrites the databases and the data volumes while the apps still hold them
open: `pg_restore --clean` drops n8n's tables under a running n8n, and the
volume restore empties `aistack-n8n-data` under it. **The restore refuses to
start while any stack container except `aistack-postgres` is up**, names the
ones that are, and changes nothing — so a forgotten `down` costs you a second
command, not a database.

The two neighbouring commands, because they are not the same:

- **`bin/aistack verify <backup>` reads only** and never writes, so it does
  not care whether the stack is up. Run it *before* the `down`: that way you
  learn whether the archive is good while you still have a serving stack.
  Measured — it exits 0 against nine running containers.
- A restore **drill** restores into a throwaway project and never attaches to
  a live volume, so the refusal above does not apply to it. `bin/aistack
  drill` nevertheless needs the stack stopped, for a different reason: it
  takes the lifecycle lock exclusively, and the serving stack holds that lock
  shared for as long as it is up. It says so and names `bin/aistack down`.

If a database fails to load, the restore stops and prints what `pg_restore`
said. It is idempotent: fix what it names and run it again.

## Rotating secrets

Four classes, and they differ in how much they cost you:

- **Free.** LiteLLM virtual keys, Authelia's session pair. Rotate at will.
- **Coordinated.** Postgres roles: `ALTER ROLE`, rewrite the file, recreate
  the consumer, in that order.
- **One-way.** `N8N_ENCRYPTION_KEY`. **Rotating it invalidates every stored
  n8n credential.** The command refuses without an explicit acknowledging flag
  and prints what will break.

  Measured during the build, and worth stating because it is wider than it
  sounds: the old key is recorded in **both** n8n's data volume *and* its
  database. Replacing the key and clearing only the volume leaves n8n
  refusing to start with `Deployment key 'signing.hmac' cannot be read with
  this instance encryption key`. Recovering from an accidental rotation means
  restoring a backup, not deleting a file.
- **Re-bootstrap.** Authelia passwords and second factors.

## Pins

Every image is pinned to a tag **and** a registry digest. `versions.env` is
the source; `aistack install|update|pin` renders it into a delimited block in
`.env`; CI asserts the two match, and `doctor` re-checks — which is what
catches a dependency-bot pull request merged without a re-render.

**Digest pinning is the control.** Signature verification runs opportunistically
for the upstreams that publish signatures, listed per image. There is no
blanket claim that images are verified, because that would not be true.
