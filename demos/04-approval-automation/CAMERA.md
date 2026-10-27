# Demo 4 — Business automation with human approval (MVP W3)

**What the viewer sees:** an n8n workflow writes a daily summary. It does not
send it. It asks *you* first. Only after you approve does it deliver — once,
and only the exact text you approved.

**What is really happening:** W3 → the model writes the summary → an *approval
envelope* in Postgres (the text's SHA-256, who may approve, when it expires) →
you decide with one command → W3 checks the hash again and delivers. The
database itself refuses a second delivery, an expired approval, or a changed
text. Nothing leaves the machine: "deliver" writes a row.

## Before you record

1. `bin/aistack samples setup` (once).
2. Rehearse: `demos/run.sh 4` must say `PASS`.
3. **W3 sends one summary a day.** After a rehearsal it stays quiet for 20 hours
   (that is the point: no second delivery). To record again the same day, start
   the demo data over:
   `bin/aistack samples teardown && bin/aistack samples setup && demos/setup.sh`

## On camera

| Step | You do | You say | You should see |
|---|---|---|---|
| 1 | `bin/aistack samples run W3` | "The robot writes the report, but it may not send it." | `W3.2 … REQUESTS approval and stops`, an envelope id, `nothing delivered`. |
| 2 | Run it again. | "Running it twice does not ask twice." | `W3.3 … still 1 envelope(s), 0 delivery row(s)`. |
| 3 | `bin/aistack samples approve <id>` (copy the id from step 1). Read the summary it shows, type `y`. | "I read it. I approve it." | The approver, the scope, the hash, `recorded: … -> approved`. |
| 4 | `bin/aistack samples run W3` | "Now it is delivered — once." | `W3.5 … delivered … the exact text that was approved`, `a replay claim … affects 0 rows`. |
| 5 | `bin/aistack samples run P2` | "And the ways to cheat are closed." | Six `NEGATIVE` cases, all `PASS`. |

## If it goes wrong

- **No envelope in step 1:** `bin/aistack samples setup` was not run, or the model returned nothing. `bin/aistack logs n8n`.
- **"expired":** an approval is valid for a limited time. Run step 1 again.

## Automatic check

`demos/run.sh 4` runs steps 1–5 in order (step 3 with `--yes`) and passes only if
the request appears, nothing is delivered before the approval, the approved
text is delivered exactly once, and all P2 negative cases are refused.
