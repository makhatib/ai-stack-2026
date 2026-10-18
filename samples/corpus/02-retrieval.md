# Retrieval, plainly

Retrieval-augmented generation is a search engine wearing a hat. The document
is split into chunks, each chunk is turned into a vector, and the vectors go
into a database that can find near neighbours quickly.

When a question arrives it is turned into a vector the same way, the nearest
chunks are fetched, and those chunks are pasted into the prompt. The model
never "learned" the document. It was handed the relevant page and asked to
read it, which is why citations are possible and why a wrong chunk produces a
confidently wrong answer.
