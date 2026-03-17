FROM alpine:3.21

ARG XRAY_VERSION=25.1.1

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    iptables \
    ca-certificates

RUN ARCH="$(apk --print-arch)" && \
    case "$ARCH" in \
      x86_64) XRAY_ARCH="64" ;; \
      aarch64) XRAY_ARCH="arm64-v8a" ;; \
      armv7) XRAY_ARCH="arm32-v7a" ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" && \
    unzip -q /tmp/xray.zip -d /tmp/xray && \
    install -m 0755 /tmp/xray/xray /usr/local/bin/xray && \
    rm -rf /tmp/xray /tmp/xray.zip

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
