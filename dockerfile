# ═══════════════════════════════════════════════════════════════
#  Full Dev Environment
#  SSH + Python + Node.js + Docker-in-Docker + sshx.io tunnel
#  Base: Ubuntu 22.04 LTS
# ═══════════════════════════════════════════════════════════════
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ───────────────────────────────────────────────────────────────
#  1. Core system packages
# ───────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        curl \
        wget \
        gnupg \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        sudo \
        bash \
        iproute2 \
        procps \
        iptables \
        kmod \
        fuse \
        pigz \
        xz-utils \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ───────────────────────────────────────────────────────────────
#  2. Python 3
# ───────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && ln -sf /usr/bin/pip3 /usr/local/bin/pip \
    && pip install --no-cache-dir --upgrade pip \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ───────────────────────────────────────────────────────────────
#  3. Node.js LTS
# ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g npm@latest \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ───────────────────────────────────────────────────────────────
#  4. Docker Engine (Docker-in-Docker)
# ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
    && sh /tmp/get-docker.sh \
    && rm /tmp/get-docker.sh \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Docker Compose
RUN curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
    -o /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/docker-compose

# ───────────────────────────────────────────────────────────────
#  5. sshx.io — install the binary
# ───────────────────────────────────────────────────────────────
RUN curl -sSf https://sshx.io/get | sh

# ───────────────────────────────────────────────────────────────
#  6. SSH Server configuration
# ───────────────────────────────────────────────────────────────
RUN mkdir -p /var/run/sshd /root/.ssh \
    && chmod 700 /root/.ssh

RUN cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

ClientAliveInterval 60
ClientAliveCountMax 10
TCPKeepAlive yes
UseDNS no
UsePAM yes

SyslogFacility AUTH
LogLevel INFO

X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

RUN ssh-keygen -A

# ───────────────────────────────────────────────────────────────
#  7. Users
# ───────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash -G sudo,docker dev \
    && echo 'dev:devpassword' | chpasswd \
    && echo 'root:rootpassword' | chpasswd \
    && echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && mkdir -p /home/dev/.ssh \
    && chmod 700 /home/dev/.ssh \
    && chown dev:dev /home/dev/.ssh

# ───────────────────────────────────────────────────────────────
#  8. Docker storage
# ───────────────────────────────────────────────────────────────
RUN mkdir -p /var/lib/docker
VOLUME /var/lib/docker

# ───────────────────────────────────────────────────────────────
#  9. Entrypoint — starts dockerd, sshd, then sshx
# ───────────────────────────────────────────────────────────────
RUN cat > /usr/local/bin/entrypoint.sh << 'ENTRYEOF'
#!/bin/bash
set -e

# ── Banner ──────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Dev Environment Starting...       ║"
echo "╚══════════════════════════════════════════╝"
echo "  Python  : $(python --version 2>&1)"
echo "  Node    : $(node --version)"
echo "  npm     : $(npm --version)"
echo "  Docker  : $(docker --version)"
echo ""

# ── Start Docker daemon ──────────────────────────
echo "[1/3] Starting Docker daemon..."
dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver=overlay2 \
  --log-level=error \
  &> /var/log/dockerd.log &

# Wait up to 30s for Docker to be ready
for i in $(seq 1 30); do
    if docker info > /dev/null 2>&1; then
        echo "      Docker daemon ready ✓"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "      [!] Docker daemon timeout — check /var/log/dockerd.log"
    fi
    sleep 1
done

# ── Start SSH daemon ─────────────────────────────
echo "[2/3] Starting SSH server..."
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -A
fi
/usr/sbin/sshd

# ── Start sshx and print the link cleanly ────────
echo "[3/3] Starting sshx tunnel..."
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           YOUR SSHX.IO LINK              ║"
echo "╚══════════════════════════════════════════╝"

# Run sshx and extract the link, printing it clearly
sshx 2>&1 | while IFS= read -r line; do
    # sshx prints the link — detect and highlight it
    if echo "$line" | grep -qE 'https://sshx\.io'; then
        LINK=$(echo "$line" | grep -oE 'https://sshx\.io/s/[^ ]+')
        echo ""
        echo "  🔗 Open this link in your browser:"
        echo ""
        echo "     $LINK"
        echo ""
        echo "══════════════════════════════════════════"
    else
        echo "  $line"
    fi
done

# Keep container alive
wait
ENTRYEOF

RUN chmod +x /usr/local/bin/entrypoint.sh

# ───────────────────────────────────────────────────────────────
#  10. Expose SSH port
# ───────────────────────────────────────────────────────────────
EXPOSE 22

# ───────────────────────────────────────────────────────────────
#  11. Start
# ───────────────────────────────────────────────────────────────
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
