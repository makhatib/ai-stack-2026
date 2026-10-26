# syntax=docker/dockerfile:1.7
# aistack-docling-arabic — Docling on CPU with Arabic OCR (NOM-415, profile docs-arabic).
#
# BASE is the official docling-serve-cpu image, digest-pinned in versions.env
# (DOCLING_CPU_*).  It ships Tesseract 4.1.1 with English only; this adds ONE
# file, the Arabic LSTM model from tesseract-ocr/tessdata_best at a pinned
# commit, checked against the sha256 below.  models.lock carries the same row
# with its licence, and CI (I19) fails if the two disagree.
ARG BASE
FROM ${BASE}
USER 0
ADD --checksum=sha256:ab9d157d8e38ca00e7e39c7d5363a5239e053f5b0dbdb3167dde9d8124335896 \
    https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/e12c65a915945e4c28e237a9b52bc4a8f39a0cec/ara.traineddata \
    /usr/share/tesseract/tessdata/ara.traineddata
RUN chmod 0644 /usr/share/tesseract/tessdata/ara.traineddata && tesseract --list-langs | grep -qx ara
USER 1001
