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

Import them with:

```sh
bin/aistack samples load
```
