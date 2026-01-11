#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}VLESS Reality Auto-Deploy Script${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

INSTALL_DIR="/opt/vless-reality"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Update system
echo -e "${YELLOW}[1/7] Updating system packages...${NC}"
apt-get update -qq

# Install required packages
echo -e "${YELLOW}[2/7] Installing required packages...${NC}"
apt-get install -y curl openssl jq wget unzip > /dev/null 2>&1

# Install Docker if not installed
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh || {
        # Fallback: manual Docker installation for older Ubuntu
        echo -e "${YELLOW}Trying alternative Docker installation...${NC}"
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null
        apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    }
    systemctl enable docker
    systemctl start docker
    rm -f get-docker.sh
    echo -e "${GREEN}✓ Docker installed${NC}"
else
    echo -e "${GREEN}✓ Docker already installed${NC}"
fi

# Verify Docker is working
if ! docker --version &> /dev/null; then
    echo -e "${RED}Docker installation failed. Please install manually.${NC}"
    exit 1
fi

# Configure firewall
echo -e "${YELLOW}[3/7] Configuring firewall rules...${NC}"

# Install iptables-persistent
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1

# Add firewall rules
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p udp --dport 443 -j ACCEPT
iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
iptables -I INPUT -p udp --dport 8443 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p udp --dport 80 -j ACCEPT

# Save rules
netfilter-persistent save > /dev/null 2>&1

echo -e "${GREEN}✓ Firewall rules configured and saved${NC}"

# Generate new credentials
echo -e "${YELLOW}[4/7] Generating new credentials...${NC}"

# **FIX: Download Xray binary directly to host first**
echo "Downloading Xray binary..."

XRAY_BINARY="$INSTALL_DIR/xray"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

# Download and extract
if ! wget -q -O /tmp/xray.zip "$XRAY_URL"; then
    echo -e "${RED}✗ Failed to download Xray binary${NC}"
    exit 1
fi

if ! unzip -q /tmp/xray.zip -d "$INSTALL_DIR" xray; then
    echo -e "${RED}✗ Failed to extract Xray binary${NC}"
    rm -f /tmp/xray.zip
    exit 1
fi

chmod +x "$XRAY_BINARY"
rm -f /tmp/xray.zip

# Verify Xray was extracted
if [ ! -f "$XRAY_BINARY" ]; then
    echo -e "${RED}✗ Xray binary not found after extraction${NC}"
    exit 1
fi

# Generate UUID
NEW_UUID=$("$XRAY_BINARY" uuid)

if [ -z "$NEW_UUID" ]; then
    echo -e "${RED}✗ Failed to generate UUID${NC}"
    exit 1
fi

# Generate Reality keys
KEYS_OUTPUT=$("$XRAY_BINARY" x25519 2>&1)

# Parse the output - format is "PrivateKey: <key>" and "Password: <key>"
# Note: Xray uses "Password" for the public key equivalent
NEW_PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "^PrivateKey:" | awk '{print $2}')

if [ -z "$NEW_PRIVATE_KEY" ]; then
    echo -e "${RED}✗ Failed to parse Reality keys${NC}"
    echo "Xray output was:"
    echo "$KEYS_OUTPUT"
    exit 1
fi

# For VLESS Reality, we need to generate the public key from the private key
# Use Xray to do this - the Password field is derived from PrivateKey
NEW_PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "^Password:" | awk '{print $2}')

# If we still don't have it, generate again
if [ -z "$NEW_PUBLIC_KEY" ]; then
    # Run x25519 again and extract both values
    KEYS_OUTPUT=$("$XRAY_BINARY" x25519 2>&1)
    NEW_PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "^PrivateKey:" | awk '{print $2}')
    NEW_PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "^Password:" | awk '{print $2}')
fi

if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
    echo -e "${RED}✗ Failed to generate Reality keys${NC}"
    exit 1
fi

# Generate short ID (8 hex characters)
NEW_SHORT_ID=$(openssl rand -hex 4)

# Get server IP
SERVER_IP=$(curl -s https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

echo -e "${GREEN}✓ Credentials generated successfully${NC}"

# Create config.json
echo -e "${YELLOW}[5/7] Creating configuration...${NC}"

cat > "$INSTALL_DIR/config.json" << EOF
{
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "decryption": "none",
      "clients": [{
        "id": "$NEW_UUID",
        "flow": "xtls-rprx-vision",
        "level": 0
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
              "realitySettings": {
        "show": false,
        "dest": "1.1.1.1:443",
        "xver": 0,
        "privateKey": "$NEW_PRIVATE_KEY",
        "publicKey": "$NEW_PUBLIC_KEY",
        "shortIds": ["$NEW_SHORT_ID"],
        "serverNames": [
          "speedtest.net",
          "one.one.one.one",
          "cloudflare.com",
          "office365.emis.gov.eg",
          "haweya.eg",
          "ekb.eg",
          "mcit.gov.eg",
          "playstation.net",
          "warthunder.com",
          "watchit.com",
          "mbc.net",
          "netflix.com",
          "outlook.office365.com",
          "hdm.tedata.net.eg",
          "tedata.net.eg",
          "ims.te.eg",
          "te.eg"
        ]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 30,
        "mark": 255
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {
      "domainStrategy": "UseIPv4"
    },
    "streamSettings": {
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 30,
        "mark": 255
      }
    }
  }]
}
EOF

echo -e "${GREEN}✓ Configuration created${NC}"

# Stop existing container if running
if [ "$(docker ps -aq -f name=xray-reality)" ]; then
    echo -e "${YELLOW}Stopping existing container...${NC}"
    docker stop xray-reality > /dev/null 2>&1
    docker rm xray-reality > /dev/null 2>&1
fi

# Deploy container
echo -e "${YELLOW}[6/7] Building Docker image...${NC}"

# Create Dockerfile in temporary location
cat > "$INSTALL_DIR/Dockerfile.build" << 'DOCKERFILE_EOF'
FROM alpine:latest

# Install Xray
RUN apk add --no-cache ca-certificates && \
    mkdir -p /usr/local/share/xray /var/log/xray

# Copy Xray binary from host
COPY xray /usr/local/bin/xray
RUN chmod +x /usr/local/bin/xray

# Create config directory
RUN mkdir -p /etc/xray /var/log/xray

# Expose port
EXPOSE 443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ps aux | grep -q '[/]xray' || exit 1

# Run Xray
CMD ["/usr/local/bin/xray", "run", "-config", "/etc/xray/config.json"]
DOCKERFILE_EOF

# Build the image
docker build -f "$INSTALL_DIR/Dockerfile.build" -t xray-reality-local "$INSTALL_DIR" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Docker build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker image built successfully${NC}"

# Run container
echo -e "${YELLOW}[7/7] Deploying VLESS Reality container...${NC}"

docker run -d \
    --name xray-reality \
    --restart unless-stopped \
    --privileged \
    -p 443:443/tcp \
    -p 443:443/udp \
    -v "$INSTALL_DIR/config.json":/etc/xray/config.json:ro \
    -v "$INSTALL_DIR/logs":/var/log/xray \
    -e TZ=UTC \
    xray-reality-local > /dev/null 2>&1

# Wait for container to start
sleep 3

# **FIX: Validate container is running**
if ! docker ps | grep -q xray-reality; then
    echo -e "${RED}✗ Container failed to start. Check logs:${NC}"
    docker logs xray-reality
    exit 1
fi

echo -e "${GREEN}✓ VLESS Reality deployed successfully!${NC}"

# Create logs directory if it doesn't exist
mkdir -p "$INSTALL_DIR/logs"

# Save credentials to file
cat > "$INSTALL_DIR/vless-credentials.txt" << EOL
╔════════════════════════════════════════════════════════════════╗
║           VLESS REALITY SERVER CREDENTIALS                     ║
╚════════════════════════════════════════════════════════════════╝

Server Information:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Server IP:        $SERVER_IP
  Port:             443
  Protocol:         VLESS
  Network:          TCP
  Security:         Reality
  Flow:             xtls-rprx-vision

Authentication:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  UUID:             $NEW_UUID

Reality Keys:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Private Key:      $NEW_PRIVATE_KEY (Keep this SECRET!)
  Public Key:       $NEW_PUBLIC_KEY
  Short ID:         $NEW_SHORT_ID

Reality Settings:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Destination:      1.1.1.1:443
  Server Name:      Choose from list below
  Fingerprint:      chrome

Available SNI Options (choose one):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  • speedtest.net              • one.one.one.one         • cloudflare.com
  • netflix.com                • playstation.net
  • office365.emis.gov.eg      • te.eg                   • tedata.net.eg
  • haweya.eg                  • ekb.eg                  • mcit.gov.eg

Client Configuration String:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
vless://${NEW_UUID}@${SERVER_IP}:443?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality

Alternative SNI:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Change 'sni=speedtest.net' to any option from the list above
Example: sni=cloudflare.com or sni=netflix.com

Generated: $(date)
╚════════════════════════════════════════════════════════════════╝

⚠️  IMPORTANT: Keep this file secure and never share the Private Key!
💡 TIP: You can test different SNI options by changing the 'sni=' parameter
EOL

# Display credentials
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${GREEN}           VLESS REALITY SERVER CREDENTIALS                     ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Server Information:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Server IP:${NC}        ${MAGENTA}$SERVER_IP${NC}"
echo -e "  ${GREEN}Port:${NC}             ${MAGENTA}443${NC}"
echo -e "  ${GREEN}Protocol:${NC}         ${MAGENTA}VLESS${NC}"
echo -e "  ${GREEN}Network:${NC}          ${MAGENTA}TCP${NC}"
echo -e "  ${GREEN}Security:${NC}         ${MAGENTA}Reality${NC}"
echo -e "  ${GREEN}Flow:${NC}             ${MAGENTA}xtls-rprx-vision${NC}"
echo ""
echo -e "${CYAN}Authentication:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}UUID:${NC}             ${MAGENTA}$NEW_UUID${NC}"
echo ""
echo -e "${CYAN}Reality Keys:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Public Key:${NC}       ${MAGENTA}$NEW_PUBLIC_KEY${NC}"
echo -e "  ${GREEN}Private Key:${NC}      ${RED}$NEW_PRIVATE_KEY${NC} ${YELLOW}(Keep SECRET!)${NC}"
echo -e "  ${GREEN}Short ID:${NC}         ${MAGENTA}$NEW_SHORT_ID${NC}"
echo ""
echo -e "${CYAN}Client Configuration String:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}vless://${NEW_UUID}@${SERVER_IP}:443?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality${NC}"
echo ""
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Credentials saved to:${NC} ${YELLOW}$INSTALL_DIR/vless-credentials.txt${NC}"
echo ""
echo -e "${CYAN}Container Status:${NC}"
docker ps --filter name=xray-reality --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  View logs:        ${GREEN}docker logs -f xray-reality${NC}"
echo -e "  View credentials: ${GREEN}cat $INSTALL_DIR/vless-credentials.txt${NC}"
echo -e "  Restart:          ${GREEN}docker restart xray-reality${NC}"
echo -e "  Stop:             ${GREEN}docker stop xray-reality${NC}"
echo ""
echo -e "${RED}⚠️  SECURITY WARNING:${NC}"
echo -e "${YELLOW}Keep 'vless-credentials.txt' secure and never share the Private Key!${NC}"
echo ""