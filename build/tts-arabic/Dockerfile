# aistack-tts-arabic — built locally from pinned inputs (NOM-415, profile voice-arabic).
# BASE comes from versions.env (PYBASE_*), digest-pinned.  Python deps come from
# requirements.lock (sha256 for every wheel, CPU-only torch); the weights come
# from models.lock (one Hugging Face revision, sha256 and licence per file).
# The image needs no network at run time and has none.
ARG BASE
FROM ${BASE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HUB_DISABLE_TELEMETRY=1
WORKDIR /app
COPY requirements.lock .
RUN pip install --require-hashes --no-deps -r requirements.lock
COPY models.lock fetch_models.py ./
RUN python fetch_models.py /models/chatterbox && rm -rf /models/chatterbox/.cache
COPY server.py .
RUN useradd --uid 10004 --no-create-home --shell /usr/sbin/nologin aistack
USER 10004:10004
ENV HF_HUB_OFFLINE=1 NUMBA_CACHE_DIR=/tmp/numba
EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
