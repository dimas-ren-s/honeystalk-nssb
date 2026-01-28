#!/bin/bash
set -e

echo "[+] Honeypot Auto Deployment (FINAL v3 - Anti Lockout)"

BASE_DIR="/opt/honeypot-stack"
TIMEZONE="Asia/Jakarta"

# ===== ROOT CHECK =====
if [[ $EUID -ne 0 ]]; then
  echo "[-] Please run as root (sudo)"
  exit 1
fi

# ===== DETECT SSH PORT (ANTI LOCKOUT) =====
echo "[+] Detecting active SSH port"
SSH_PORT=$(ss -tlpn | grep sshd | awk '{print $4}' | sed 's/.*://')

if [[ -z "$SSH_PORT" ]]; then
  echo "[-] SSH port detection failed. Aborting for safety."
  exit 1
fi

echo "[✓] Detected SSH port: $SSH_PORT"

# ===== TIMEZONE =====
timedatectl set-timezone $TIMEZONE

# ===== BASE PACKAGES =====
apt update -y
apt install -y ca-certificates curl gnupg lsb-release ufw

# ===== INSTALL DOCKER (OFFICIAL) =====
if ! command -v docker &> /dev/null; then
  echo "[+] Installing Docker (official repo)"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl enable docker --now

# ===== DIRECTORY STRUCTURE =====
echo "[+] Preparing directories"
mkdir -p $BASE_DIR/{cowrie,dionaea,fluent-bit}
cd $BASE_DIR

# ===== DOCKER COMPOSE =====
echo "[+] Writing docker-compose.yml"
cat > docker-compose.yml <<'EOF'
services:
  cowrie:
    image: cowrie/cowrie:latest
    container_name: cowrie
    restart: unless-stopped
    ports:
      - "2222:2222"
      - "2223:2223"
    volumes:
      - cowrie-logs:/cowrie/cowrie-git/var/log/cowrie

  dionaea:
    image: dinotools/dionaea:latest
    container_name: dionaea
    restart: unless-stopped
    network_mode: host
    volumes:
      - dionaea-logs:/opt/dionaea/var/log
      - dionaea-binaries:/opt/dionaea/var/lib/dionaea

  fluent-bit:
    image: fluent/fluent-bit:latest
    container_name: fluent-bit
    restart: unless-stopped
    depends_on:
      - cowrie
      - dionaea
    volumes:
      - cowrie-logs:/logs/cowrie:ro
      - dionaea-logs:/logs/dionaea:ro
      - ./fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf
    command: ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/etc/fluent-bit.conf"]

volumes:
  cowrie-logs:
  dionaea-logs:
  dionaea-binaries:
EOF

# ===== FLUENT BIT CONFIG =====
echo "[+] Writing Fluent Bit config"
cat > fluent-bit/fluent-bit.conf <<'EOF'
[SERVICE]
    Flush        5
    Log_Level    info

[INPUT]
    Name   tail
    Path   /logs/cowrie/*.json
    Tag    cowrie.*

[INPUT]
    Name   tail
    Path   /logs/dionaea/*
    Tag    dionaea.*

[OUTPUT]
    Name   stdout
    Match  *
EOF

# ===== FIREWALL (ANTI LOCKOUT) =====
echo "[+] Configuring firewall safely"

# Allow detected SSH port
ufw allow ${SSH_PORT}/tcp comment 'SSH Admin Port'

# Allow honeypot ports
ufw allow 2222/tcp comment 'Cowrie SSH'
ufw allow 2223/tcp comment 'Cowrie Telnet'
ufw allow 21/tcp   comment 'Dionaea FTP'
ufw allow 445/tcp  comment 'Dionaea SMB'
ufw allow 1433/tcp comment 'Dionaea MSSQL'

ufw --force enable

# ===== DEPLOY =====
echo "[+] Starting honeypot containers"
docker compose pull
docker compose up -d

# ===== STATUS =====
echo "[+] Deployment status:"
docker ps --format "table {{.Names}}\t{{.Status}}"

echo "[✓] Honeypot deployment completed successfully (SSH SAFE)"
