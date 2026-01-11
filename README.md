# VLESS Reality Docker Deployment

Automated VLESS Reality proxy deployment using Docker and GitHub Container Registry.

## 🚀 One-Command Deploy

On any fresh Ubuntu/Debian server:
```bash
curl -sSL https://raw.githubusercontent.com/FathiZayed/vless-reality-deployment/main/quick-deploy.sh | sudo bash
```

This single command will:
- ✅ Install Docker & Docker Compose
- ✅ Configure firewall (ports 80, 443, 8443)
- ✅ Generate random UUID, keys, and short IDs
- ✅ Deploy VLESS Reality container
- ✅ Display your connection credentials

## 📋 What You Get

After deployment, you'll see:
- Server IP and port
- UUID for authentication
- Public/Private Reality keys
- Short ID
- Ready-to-use connection string
- All credentials saved to `vless-credentials.txt`

## 🔧 Manual Deployment
```bash
# Clone repository
git clone https://github.com/FathiZayed/vless-reality-deployment.git
cd vless-reality-deployment

# Deploy
sudo ./deploy.sh
```

## 📱 Client Configuration

Use any of these SNI options:
- speedtest.net
- one.one.one.one
- cloudflare.com
- netflix.com
- playstation.net
- office365.emis.gov.eg
- te.eg
- tedata.net.eg

## 🔒 Security Features

- Random credentials generated on each deployment
- XTLS-Vision flow for maximum performance
- Reality protocol for anti-censorship
- TCP optimizations (Fast Open, Keep-Alive)
- Persistent firewall rules

## 📊 Useful Commands
```bash
# View logs
docker logs -f xray-reality

# View credentials
cat /opt/vless-reality/vless-credentials.txt

# Restart service
docker restart xray-reality

# Check status
docker ps
```

## 🔄 Updating
```bash
cd /opt/vless-reality
git pull
sudo ./deploy.sh
```

## 📦 What Gets Installed

- Docker Engine
- Docker Compose
- Xray-core (latest)
- iptables-persistent
- Firewall rules for ports 80, 443, 8443

## 🌍 Optimized For

- Egyptian networks (local SNI options included)
- Low latency with TCP Fast Open
- Stable connections with Keep-Alive
- IPv4 routing

## ⚠️ Important Notes

- Keep `vless-credentials.txt` secure
- Never share your private key
- Credentials are regenerated on each deploy
- Firewall rules persist across reboots

## 📄 License

MIT
