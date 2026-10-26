# aistack-openclaw-sandbox — where OpenClaw's agent runs its tools (NOM-415).
#
# OpenClaw's own sandbox backends are Docker (needs the Docker socket: refused,
# I6), Podman (the same thing) and SSH.  This is the SSH target: a plain shell
# box that OpenClaw's gateway reaches over one pairwise bridge and nothing
# else can reach.  It runs under gVisor (runsc), has no route off the host, a
# read-only root and a tmpfs workspace.  `exec`, `read`, `write`, `edit` and
# `apply_patch` from the agent all happen here, not in the gateway.
#
# OpenClaw's remote contract: /bin/sh, python3, GNU stat and readlink — the
# python base provides all four.  sshd is the one package added, at a pinned
# version from the base image's own pinned Debian snapshot.
ARG BASE
FROM ${BASE}
ARG DEBIAN_SNAPSHOT=20261020T213255Z
ARG OPENSSH_VERSION=1:10.0p1-7+deb13u4
RUN set -eu; \
    printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/%s\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n\nTypes: deb\nURIs: http://snapshot.debian.org/archive/debian-security/%s\nSuites: trixie-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' \
      "$DEBIAN_SNAPSHOT" "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list.d/debian.sources; \
    apt-get -o Acquire::Check-Valid-Until=false update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      "openssh-server=${OPENSSH_VERSION}" "openssh-client=${OPENSSH_VERSION}" "openssh-sftp-server=${OPENSSH_VERSION}"; \
    rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*; \
    useradd --uid 10002 --create-home --home-dir /home/sandbox --shell /bin/sh sandbox; \
    mkdir -p /workspace && chown 10002:10002 /workspace
COPY sshd_config /etc/ssh/sshd_config.aistack
USER 10002:10002
WORKDIR /workspace
EXPOSE 2222
# Non-root sshd: it can only ever authenticate the user it runs as, which is
# the one account this box has.  Host key and authorized key arrive as file
# secrets; neither is in the image.
CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config.aistack"]
