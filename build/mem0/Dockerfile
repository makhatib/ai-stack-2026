# aistack-mem0 — built locally from pinned inputs (NOM-413).
# BASE comes from versions.env (PYBASE_*), digest-pinned.  Python deps come from
# requirements.lock, which carries a sha256 for EVERY wheel (--require-hashes), so
# the image contents are a function of this directory plus the base digest.
ARG BASE
FROM ${BASE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.lock .
RUN pip install --require-hashes --no-deps -r requirements.lock
COPY app.py .
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin aistack && mkdir /data && chown 10001 /data
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
