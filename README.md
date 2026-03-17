# vless-gateway

Docker container that acts as a transparent VLESS proxy gateway. Route traffic from other containers through a VLESS server using Docker's network namespace sharing.

## Features

- Transparent proxy via iptables redirect
- Full VLESS URL parsing (REALITY, TLS, WebSocket, gRPC)
- Share network namespace with other containers
- Multi-arch support (amd64, arm64)
- Config via URL or individual environment variables

## Quick Start

```bash
docker run -d \
  --name vless-gateway \
  --cap-add NET_ADMIN \
  -e VLESS_URL="vless://uuid@host:443?security=reality&pbk=...&sni=example.com" \
  spinogrizz/vless-gateway:latest
```

Then run any container through the gateway:

```bash
docker run --rm \
  --network container:vless-gateway \
  curlimages/curl ifconfig.me
```

## Docker Compose

```yaml
services:
  gateway:
    image: spinogrizz/vless-gateway:latest
    container_name: vless-gateway
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      VLESS_URL: "vless://uuid@host:443?type=tcp&security=reality&pbk=...&sni=example.com&sid=abc&fp=chrome&flow=xtls-rprx-vision"

  # Any container can use the gateway
  myapp:
    image: myapp:latest
    network_mode: "service:gateway"
    depends_on:
      - gateway
```

## Environment Variables

### VLESS Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VLESS_URL` | - | Full VLESS URL (alternative to individual vars) |
| `VLESS_HOST` | - | Server address |
| `VLESS_PORT` | `443` | Server port |
| `VLESS_UUID` | - | Client UUID |
| `VLESS_SECURITY` | `none` | `reality`, `tls`, or `none` |
| `VLESS_SNI` | - | Server name for TLS/REALITY |
| `VLESS_PBK` | - | REALITY public key |
| `VLESS_SID` | - | REALITY short ID |
| `VLESS_FP` | `chrome` | Browser fingerprint |
| `VLESS_FLOW` | - | Flow control (e.g., `xtls-rprx-vision`) |
| `VLESS_TRANSPORT` | `tcp` | Transport: `tcp`, `ws`, `grpc` |
| `VLESS_PATH` | - | WebSocket path |
| `VLESS_SERVICENAME` | - | gRPC service name |

### Other Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `DNS_SERVERS` | `1.1.1.1,8.8.8.8` | DNS servers (comma-separated) |
| `XRAY_LOGLEVEL` | `warning` | Log level: `debug`, `info`, `warning`, `error` |

## How It Works

1. Container starts Xray with `dokodemo-door` inbound (transparent proxy)
2. iptables redirects all outgoing TCP/UDP traffic to Xray
3. Xray forwards traffic through VLESS to remote server
4. Other containers sharing the network namespace automatically route through the proxy

## Requirements

- `--cap-add NET_ADMIN` is required for iptables
- Use `network_mode: "service:gateway"` or `--network container:vless-gateway`

## License

MIT
