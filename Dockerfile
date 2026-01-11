FROM alpine:latest

# Install Xray
RUN apk add --no-cache curl unzip && \
    mkdir -p /usr/local/share/xray /var/log/xray && \
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /tmp/xray.zip && \
    unzip /tmp/xray.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/xray && \
    rm /tmp/xray.zip && \
    apk del unzip

# Download geoip and geosite data
RUN curl -L https://github.com/v2fly/geoip/releases/latest/download/geoip.dat -o /usr/local/share/xray/geoip.dat && \
    curl -L https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat -o /usr/local/share/xray/geosite.dat

# Copy configuration
COPY config.json /etc/xray/config.json

# Expose port
EXPOSE 443

# Run Xray
CMD ["/usr/local/bin/xray", "run", "-config", "/etc/xray/config.json"]
