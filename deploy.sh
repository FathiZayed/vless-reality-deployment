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

# **NEW: Port selection**
echo -e "${CYAN}Port Configuration:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Select a port for VLESS Reality:"
echo "  1) 443 (default, recommended)"
echo "  2) 8443"
echo "  3) 3000"
echo "  4) 4433"
echo "  5) Custom port"
echo ""
read -p "Enter your choice (1-5) [default: 1]: " port_choice

case $port_choice in
    2)
        SERVER_PORT=8443
        ;;
    3)
        SERVER_PORT=3000
        ;;
    4)
        SERVER_PORT=4433
        ;;
    5)
        read -p "Enter custom port number (1-65535): " custom_port
        if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 1 ] || [ "$custom_port" -gt 65535 ]; then
            echo -e "${RED}✗ Invalid port number. Using default 443${NC}"
            SERVER_PORT=443
        else
            SERVER_PORT=$custom_port
        fi
        ;;
    *)
        SERVER_PORT=443
        ;;
esac

echo -e "${GREEN}✓ Selected port: $SERVER_PORT${NC}"
echo ""

# Update system
echo -e "${YELLOW}[1/8] Updating system packages...${NC}"
apt-get update -qq

# Install required packages
echo -e "${YELLOW}[2/8] Installing required packages...${NC}"
apt-get install -y curl openssl jq wget unzip > /dev/null 2>&1

# Install Docker if not installed
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh || {
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
echo -e "${YELLOW}[3/8] Configuring firewall rules...${NC}"

# Install iptables-persistent
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1

# Add firewall rules for selected port (TCP)
iptables -I INPUT -p tcp --dport "$SERVER_PORT" -j ACCEPT
iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p udp --dport 80 -j ACCEPT

# Save rules
netfilter-persistent save > /dev/null 2>&1

echo -e "${GREEN}✓ Firewall rules configured and saved${NC}"

# Configure IPv6
echo -e "${YELLOW}[4/8] Configuring IPv6 support...${NC}"

# Enable IPv6 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1

# Persist IPv6 forwarding across reboots
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

# Detect the default outbound network interface
DEFAULT_IFACE=$(ip -6 route show default | awk '/default/ {print $5}' | head -1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
fi

# Add IPv6 MASQUERADE for host traffic
ip6tables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true

# Enable IPv6 in Docker daemon
DOCKER_DAEMON_FILE="/etc/docker/daemon.json"
if [ -f "$DOCKER_DAEMON_FILE" ]; then
    if ! grep -q '"ipv6"' "$DOCKER_DAEMON_FILE"; then
        python3 -c "
import json
with open('$DOCKER_DAEMON_FILE', 'r') as f:
    d = json.load(f)
d['ipv6'] = True
d['fixed-cidr-v6'] = 'fd00::/80'
with open('$DOCKER_DAEMON_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
    fi
else
    cat > "$DOCKER_DAEMON_FILE" << 'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80"
}
EOF
fi

# Restart Docker to apply IPv6 config
systemctl restart docker
sleep 2

# Add IPv6 MASQUERADE for Docker container traffic (fd00::/80 range)
ip6tables -t nat -A POSTROUTING -s fd00::/80 -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true

# Save ip6tables rules
netfilter-persistent save > /dev/null 2>&1

echo -e "${GREEN}✓ IPv6 configured (forwarding + NAT + Docker IPv6 enabled)${NC}"
echo -e "${GREEN}  Interface: $DEFAULT_IFACE${NC}"

# Generate new credentials
echo -e "${YELLOW}[5/8] Generating new credentials...${NC}"

# Download Xray binary directly to host
echo "Downloading Xray binary..."

XRAY_BINARY="$INSTALL_DIR/xray"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

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
NEW_PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep "^PrivateKey:" | awk '{print $2}')
NEW_PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep "^Password:" | awk '{print $2}')

if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
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

# Get server IPs
SERVER_IP=$(curl -s https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

SERVER_IPV6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d'/' -f1 | head -1)

echo -e "${GREEN}✓ Credentials generated successfully${NC}"

# Create config.json
echo -e "${YELLOW}[6/8] Creating configuration...${NC}"

cat > "$INSTALL_DIR/config.json" << EOF
{
  "inbounds": [{
    "port": $SERVER_PORT,
    "listen": "::",
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
      "domainStrategy": "UseIPv6v4"
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

# Build Docker image
echo -e "${YELLOW}[7/8] Building Docker image...${NC}"

cat > "$INSTALL_DIR/Dockerfile.build" << 'DOCKERFILE_EOF'
FROM alpine:latest

RUN apk add --no-cache ca-certificates && \
    mkdir -p /usr/local/share/xray /var/log/xray

COPY xray /usr/local/bin/xray
RUN chmod +x /usr/local/bin/xray

RUN mkdir -p /etc/xray /var/log/xray

EXPOSE 443

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ps aux | grep -q '[/]xray' || exit 1

CMD ["/usr/local/bin/xray", "run", "-config", "/etc/xray/config.json"]
DOCKERFILE_EOF

docker build -f "$INSTALL_DIR/Dockerfile.build" -t xray-reality-local "$INSTALL_DIR" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Docker build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker image built successfully${NC}"

# Deploy container
echo -e "${YELLOW}[8/8] Deploying VLESS Reality container...${NC}"

docker run -d \
    --name xray-reality \
    --restart unless-stopped \
    --privileged \
    -p "$SERVER_PORT:$SERVER_PORT/tcp" \
    -p "$SERVER_PORT:$SERVER_PORT/udp" \
    -v "$INSTALL_DIR/config.json":/etc/xray/config.json:ro \
    -v "$INSTALL_DIR/logs":/var/log/xray \
    -e TZ=UTC \
    xray-reality-local > /dev/null 2>&1

# Wait for container to start
sleep 3

if ! docker ps | grep -q xray-reality; then
    echo -e "${RED}✗ Container failed to start. Check logs:${NC}"
    docker logs xray-reality
    exit 1
fi

echo -e "${GREEN}✓ VLESS Reality deployed successfully!${NC}"

mkdir -p "$INSTALL_DIR/logs"

# Save credentials to file
cat > "$INSTALL_DIR/vless-credentials.txt" << EOL
╔════════════════════════════════════════════════════════════════╗
║           VLESS REALITY SERVER CREDENTIALS                     ║
╚════════════════════════════════════════════════════════════════╝

Server Information:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Server IP (IPv4): $SERVER_IP
  Server IP (IPv6): ${SERVER_IPV6:-N/A}
  Port:             $SERVER_PORT
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

Client Configuration String (IPv4):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
vless://${NEW_UUID}@${SERVER_IP}:${SERVER_PORT}?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality

Client Configuration String (IPv6):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
vless://${NEW_UUID}@[${SERVER_IPV6}]:${SERVER_PORT}?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality-IPv6

Alternative SNI:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Change 'sni=speedtest.net' to any option from the list above
Example: sni=cloudflare.com or sni=netflix.com

Generated: $(date)
╚════════════════════════════════════════════════════════════════╝

⚠️  IMPORTANT: Keep this file secure and never share the Private Key!
💡 TIP: You can test different SNI options by changing the 'sni=' parameter
📝 NOTE: IPv6 address may change on reboot (Oracle Cloud dynamic IPv6)
EOL

# Display credentials
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${GREEN}           VLESS REALITY SERVER CREDENTIALS                     ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Server Information:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Server IP (IPv4):${NC} ${MAGENTA}$SERVER_IP${NC}"
echo -e "  ${GREEN}Server IP (IPv6):${NC} ${MAGENTA}${SERVER_IPV6:-N/A}${NC}"
echo -e "  ${GREEN}Port:${NC}             ${MAGENTA}$SERVER_PORT${NC}"
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
echo -e "${CYAN}Client Configuration String (IPv4):${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}vless://${NEW_UUID}@${SERVER_IP}:${SERVER_PORT}?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality${NC}"
echo ""
if [ -n "$SERVER_IPV6" ]; then
echo -e "${CYAN}Client Configuration String (IPv6):${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}vless://${NEW_UUID}@[${SERVER_IPV6}]:${SERVER_PORT}?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality-IPv6${NC}"
echo ""
fi
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
echo -e "${YELLOW}Oracle Cloud IPv6 is dynamic — it may change on reboot.${NC}"
echo ""
