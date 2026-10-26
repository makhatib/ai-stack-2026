# aistack-stt-arabic — built locally from pinned inputs (NOM-415).
# BASE comes from versions.env (PYBASE_*), digest-pinned.  Python deps come from
# requirements.lock (sha256 for every wheel); the model comes from models.lock
# (one Hugging Face revision, sha256 for every file).  The image therefore
# needs no network at run time and has none.
ARG BASE
FROM ${BASE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HUB_DISABLE_TELEMETRY=1
WORKDIR /app
COPY requirements.lock .
RUN pip install --require-hashes --no-deps -r requirements.lock
COPY models.lock fetch_models.py ./
RUN python fetch_models.py /models/whisper-ar && rm -rf /models/whisper-ar/.cache
COPY server.py .
RUN useradd --uid 10003 --no-create-home --shell /usr/sbin/nologin aistack
USER 10003:10003
ENV HF_HUB_OFFLINE=1
EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
