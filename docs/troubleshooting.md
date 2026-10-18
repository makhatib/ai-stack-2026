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

## A health check says unhealthy but the service works

Check the probe before the service. Two of the obvious probes are wrong for
these images: `authelia health` is not a command in 4.39.28, and the LiteLLM
image contains neither `curl` nor `wget`. The shipped compose file already
accounts for both.

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
