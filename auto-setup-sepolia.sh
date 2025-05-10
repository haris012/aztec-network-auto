#!/bin/bash

# 🚀 Auto Setup Sepolia Geth + Lighthouse for Sequencer
# Assumes system has at least 1TB SSD, 16GB RAM

set -e

# === DEPENDENCY CHECK & INSTALL IF MISSING ===
echo ">>> Checking required dependencies..."

install_if_missing() {
  local cmd="$1"
  local pkg="$2"

  if ! command -v $cmd &> /dev/null; then
    echo "⛔ Missing: $cmd → installing $pkg..."
    sudo apt update
    sudo apt install -y $pkg
  else
    echo "✅ $cmd is already installed."
  fi
}

# Special case: Docker
if ! command -v docker &> /dev/null || ! command -v docker compose &> /dev/null; then
  echo "⛔ Docker or Docker Compose not found. Installing Docker..."

  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -y $pkg || true
  done

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo docker run hello-world
  sudo systemctl enable docker && sudo systemctl restart docker
else
  echo "✅ Docker and Docker Compose are already installed."
fi

# Install other common dependencies
install_if_missing curl curl
install_if_missing openssl openssl

# === CONFIG ===
DATA_DIR="$HOME/sepolia-node"
GETH_DIR="$DATA_DIR/geth"
LIGHTHOUSE_DIR="$DATA_DIR/lighthouse"
JWT_FILE="$DATA_DIR/jwt.hex"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"

# === STEP 1: PREPARE FOLDERS ===
echo ">>> Creating data directories..."
mkdir -p "$GETH_DIR" "$LIGHTHOUSE_DIR"

# === STEP 2: GENERATE JWT SECRET ===
echo ">>> Generating JWT secret..."
openssl rand -hex 32 > "$JWT_FILE"

# === STEP 3: WRITE docker-compose.yml ===
echo ">>> Writing docker-compose.yml..."
cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  geth:
    image: ethereum/client-go:stable
    container_name: geth
    restart: unless-stopped
    volumes:
      - $GETH_DIR:/root/.ethereum
      - $JWT_FILE:/root/jwt.hex
    ports:
      - "8545:8545"
      - "30303:30303"
      - "8551:8551"
    command: >
      --sepolia
      --http --http.addr 0.0.0.0 --http.api eth,web3,net,engine
      --authrpc.addr 0.0.0.0 --authrpc.port 8551
      --authrpc.jwtsecret /root/jwt.hex
      --authrpc.vhosts=*
      --http.corsdomain="*"

  lighthouse:
    image: sigp/lighthouse:latest
    container_name: lighthouse
    restart: unless-stopped
    volumes:
      - $LIGHTHOUSE_DIR:/root/.lighthouse
      - $JWT_FILE:/root/jwt.hex
    ports:
      - "5052:5052"
    depends_on:
      - geth
    command: >
      lighthouse bn
      --network sepolia
      --execution-endpoint http://geth:8551
      --execution-jwt /root/jwt.hex
      --checkpoint-sync-url https://sepolia.checkpoint-sync.ethpandaops.io
      --http
      --http-address 0.0.0.0
EOF

# === STEP 4: START SERVICES ===
echo ">>> Checking port 8545..."
if lsof -i :8545 >/dev/null 2>&1; then
  echo "❌ Port 8545 is already in use. Please stop the process using it before running this script."
  exit 1
fi

echo ">>> Starting Sepolia node with Docker Compose..."
cd "$DATA_DIR"
docker-compose up -d

echo ">>> ✅ Setup complete. Use the following commands to check status:"
echo "  docker logs -f geth"
echo "  docker logs -f lighthouse"
echo "  curl -s -X POST http://localhost:8545 -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}'"
echo "  curl http://localhost:5052/eth/v1/node/health"
