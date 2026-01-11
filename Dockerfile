FROM alpine:latest

# Install Xray
RUN apk add --no-cache ca-certificates curl unzip && \
    mkdir -p /usr/local/share/xray /var/log/xray && \
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /tmp/xray.zip && \
    unzip -q /tmp/xray.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/xray && \
    rm /tmp/xray.zip && \
    apk del unzip

# Download geoip and geosite data (optional but recommended)
RUN apk add --no-cache curl && \
    mkdir -p /usr/local/share/xray && \
    curl -L https://github.com/v2fly/geoip/releases/latest/download/geoip.dat -o /usr/local/share/xray/geoip.dat && \
    curl -L https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -o /usr/local/share/xray/geosite.dat && \
    apk del curl

# Create config and log directories
RUN mkdir -p /etc/xray /var/log/xray

# Expose port
EXPOSE 443

# Health check - verify Xray process is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ps aux | grep -q '[/]xray' || exit 1

# Run Xray with config file
CMD ["/usr/local/bin/xray", "run", "-config", "/etc/xray/config.json"]