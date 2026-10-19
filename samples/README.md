# Sample data

**Everything here is synthetic.** No real credential, no real customer data,
no real endpoint. The values are deliberately shaped like what they replace
and deliberately useless: `SYNTHETIC-NOT-A-REAL-PASSWORD-0000` is not a
password anyone forgot to rotate.

- `credentials.synthetic.json` — two n8n credentials. They exist so the
  **backup drill can prove credential decryption** rather than reporting
  "0 credentials restored", which proves nothing. Imported with
  `n8n import:credentials`, they are encrypted with the instance key, so a
  restored stack that can read them has demonstrated that the key travelled
  with the archive.
- `corpus/` — a few paragraphs of public-domain text for W1 and W2, so the
  research demo has something local to search.
- `fixtures/` — the demo schema (`schema.sql`) and the generator for the one
  document W2 parses (`make-synthetic-pdf.py`). The PDF is **generated, not
  committed**: a binary fixture has no reviewable diff, and a PDF is the most
  attacker-shaped file format this stack accepts, so the one we ship is a file
  whose every byte is accounted for in source.

```sh
bin/aistack samples setup      # make the demos runnable (W1, W3, W4)
bin/aistack samples run all    # run them and check the outputs
bin/aistack samples teardown   # remove everything setup created

bin/aistack samples load       # import ONLY — what the backup drill needs
```

`samples load` is the old command and still does exactly what the drill needs:
it lands credential ciphertext in n8n so a restore has something real to
decrypt. **It does not make the demos runnable**, which is the whole of
NOM-302: it imported four workflows, exited 0, and not one of them could run.

Four templates are still imported; **three are executable** — W1, W3 and W4.
W2 is deferred by decision ([NOM-321](/NOM/issues/NOM-321),
[NOM-323](/NOM/issues/NOM-323)): n8n has no route to Docling and the release
will not add one to make a demo pass. `samples run` reports it as `DEFERRED`
with the measurement. See [docs/samples.md](../docs/samples.md).
