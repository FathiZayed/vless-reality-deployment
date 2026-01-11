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

# Update system
echo -e "${YELLOW}[1/6] Updating system packages...${NC}"
apt-get update -qq

# Install required packages
echo -e "${YELLOW}[2/6] Installing required packages...${NC}"
apt-get install -y curl unzip openssl jq > /dev/null 2>&1

# Install Docker if not installed
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
    echo -e "${GREEN}✓ Docker installed${NC}"
else
    echo -e "${GREEN}✓ Docker already installed${NC}"
fi

# Install Docker Compose if not installed
if ! command -v docker-compose &> /dev/null; then
    echo -e "${YELLOW}Installing Docker Compose...${NC}"
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    echo -e "${GREEN}✓ Docker Compose installed${NC}"
else
    echo -e "${GREEN}✓ Docker Compose already installed${NC}"
fi

# Install Xray temporarily for key generation
if ! command -v xray &> /dev/null; then
    echo -e "${YELLOW}Installing Xray for key generation...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
fi

# Configure firewall
echo -e "${YELLOW}[3/6] Configuring firewall rules...${NC}"

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
echo -e "${YELLOW}[4/6] Generating new credentials...${NC}"

# Generate UUID
NEW_UUID=$(xray uuid)

# Generate Reality keys
KEYS=$(xray x25519)
NEW_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
NEW_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')

# Generate short ID
NEW_SHORT_ID=$(openssl rand -hex 8)

# Get server IP
SERVER_IP=$(curl -s https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

echo -e "${GREEN}✓ Credentials generated${NC}"

# Update config.json
echo -e "${YELLOW}[5/6] Updating configuration...${NC}"

if [ ! -f "config.json" ]; then
    echo -e "${RED}Error: config.json not found in current directory${NC}"
    exit 1
fi

# Backup original config
cp config.json config.json.bak

# Update config with new credentials
sed -i "s/\"id\": \"[^\"]*\"/\"id\": \"$NEW_UUID\"/g" config.json
sed -i "s/\"privateKey\": \"[^\"]*\"/\"privateKey\": \"$NEW_PRIVATE_KEY\"/g" config.json
sed -i "s/\"shortIds\": \[[^]]*\]/\"shortIds\": [\"$NEW_SHORT_ID\"]/g" config.json

echo -e "${GREEN}✓ Configuration updated${NC}"

# Stop existing container if running
if [ "$(docker ps -aq -f name=xray-reality)" ]; then
    echo -e "${YELLOW}Stopping existing container...${NC}"
    docker stop xray-reality > /dev/null 2>&1
    docker rm xray-reality > /dev/null 2>&1
fi

# Deploy container
echo -e "${YELLOW}[6/6] Deploying VLESS Reality...${NC}"

# Build and run
docker-compose up -d --build > /dev/null 2>&1

# Wait for container to start
sleep 3

echo -e "${GREEN}✓ VLESS Reality deployed successfully!${NC}"

# Save credentials to file
cat > vless-credentials.txt << EOL
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
  Public Key:       $NEW_PUBLIC_KEY
  Private Key:      $NEW_PRIVATE_KEY (Keep this SECRET!)
  Short ID:         $NEW_SHORT_ID

Reality Settings:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Destination:      1.1.1.1:443
  Server Name:      Choose from list below
  Fingerprint:      chrome

Available SNI Options (choose one):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  • speedtest.net
  • one.one.one.one
  • cloudflare.com
  • netflix.com
  • playstation.net
  • office365.emis.gov.eg
  • te.eg
  • tedata.net.eg

Client Configuration String:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
vless://${NEW_UUID}@${SERVER_IP}:443?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality

Generated: $(date)
╚════════════════════════════════════════════════════════════════╝

⚠️  IMPORTANT: Keep this file secure and never share the Private Key!
💡 TIP: You can use any SNI from the list above by changing the 'sni=' parameter
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
echo -e "${CYAN}Reality Settings:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}Destination:${NC}      ${MAGENTA}1.1.1.1:443${NC}"
echo -e "  ${GREEN}Server Name:${NC}      ${MAGENTA}Choose from list below${NC}"
echo -e "  ${GREEN}Fingerprint:${NC}      ${MAGENTA}chrome${NC}"
echo ""
echo -e "${CYAN}Available SNI Options (choose one):${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${MAGENTA}• speedtest.net       • one.one.one.one    • cloudflare.com${NC}"
echo -e "  ${MAGENTA}• netflix.com         • playstation.net${NC}"
echo -e "  ${MAGENTA}• office365.emis.gov.eg    • te.eg         • tedata.net.eg${NC}"
echo ""
echo -e "${CYAN}Client Configuration String:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}vless://${NEW_UUID}@${SERVER_IP}:443?type=tcp&security=reality&pbk=${NEW_PUBLIC_KEY}&fp=chrome&sni=speedtest.net&sid=${NEW_SHORT_ID}&flow=xtls-rprx-vision#VLESS-Reality${NC}"
echo ""
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Credentials saved to:${NC} ${YELLOW}vless-credentials.txt${NC}"
echo ""
echo -e "${CYAN}Container Status:${NC}"
docker ps --filter name=xray-reality --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  View logs:        ${GREEN}docker logs -f xray-reality${NC}"
echo -e "  View credentials: ${GREEN}cat vless-credentials.txt${NC}"
echo -e "  Restart:          ${GREEN}docker restart xray-reality${NC}"
echo -e "  Stop:             ${GREEN}docker stop xray-reality${NC}"
echo ""
echo -e "${RED}⚠️  SECURITY WARNING:${NC}"
echo -e "${YELLOW}Keep 'vless-credentials.txt' secure and never share the Private Key!${NC}"
echo ""
