#!/usr/bin/env bash
set -euo pipefail

# ============ Logging ============

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$@"; exit 1; }

# ============ Utils ============

urldecode() {
  printf '%b' "${1//%/\\x}"
}

resolve_host() {
  local host="$1"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$host"
  else
    getent hosts "$host" | awk '{print $1; exit}' || echo ""
  fi
}

# ============ Defaults ============

init_defaults() {
  XRAY_CONFIG="${XRAY_CONFIG:-/tmp/xray-config.json}"
  PROXY_PORT="${PROXY_PORT:-12345}"
  DNS_SERVERS="${DNS_SERVERS:-1.1.1.1,8.8.8.8}"
  XRAY_LOGLEVEL="${XRAY_LOGLEVEL:-warning}"
  PRESERVE_DOCKER_DNS="${PRESERVE_DOCKER_DNS:-true}"
  BYPASS_CIDRS="${BYPASS_CIDRS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16}"

  # VLESS defaults
  VLESS_HOST="${VLESS_HOST:-}"
  VLESS_PORT="${VLESS_PORT:-443}"
  VLESS_UUID="${VLESS_UUID:-}"
  VLESS_SECURITY="${VLESS_SECURITY:-none}"
  VLESS_SNI="${VLESS_SNI:-}"
  VLESS_FLOW="${VLESS_FLOW:-}"
  VLESS_FP="${VLESS_FP:-chrome}"
  VLESS_PBK="${VLESS_PBK:-}"
  VLESS_SID="${VLESS_SID:-}"
  VLESS_SPIDERX="${VLESS_SPIDERX:-/}"
  VLESS_TRANSPORT="${VLESS_TRANSPORT:-tcp}"
  VLESS_PATH="${VLESS_PATH:-}"
  VLESS_SERVICENAME="${VLESS_SERVICENAME:-}"
}

# ============ VLESS URL Parsing ============

parse_vless_url() {
  local url="$1"

  url="${url#vless://}"
  local base="${url%%\?*}"
  local query=""
  if [[ "$url" == *\?* ]]; then
    query="${url#*\?}"
    query="${query%%#*}"
  fi

  local userinfo="${base%@*}"
  local hostport="${base#*@}"

  VLESS_UUID="$userinfo"
  VLESS_HOST="${hostport%:*}"
  VLESS_PORT="${hostport##*:}"

  IFS='&' read -ra pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    local key="${pair%%=*}"
    local val="$(urldecode "${pair#*=}")"
    case "$key" in
      security)   VLESS_SECURITY="$val" ;;
      sni)        VLESS_SNI="$val" ;;
      flow)       VLESS_FLOW="$val" ;;
      fp)         VLESS_FP="$val" ;;
      pbk)        VLESS_PBK="$val" ;;
      sid)        VLESS_SID="$val" ;;
      spiderX|spx) VLESS_SPIDERX="$val" ;;
      type)       VLESS_TRANSPORT="$val" ;;
      path)       VLESS_PATH="$val" ;;
      serviceName) VLESS_SERVICENAME="$val" ;;
      encryption) ;; # always none for VLESS
    esac
  done

  log_info "Parsed VLESS: ${VLESS_HOST}:${VLESS_PORT} (${VLESS_SECURITY}/${VLESS_TRANSPORT})"
}

validate_vless_config() {
  [[ -n "$VLESS_HOST" ]] || die "VLESS_HOST or VLESS_URL is required"
  [[ -n "$VLESS_PORT" ]] || die "VLESS_PORT or VLESS_URL is required"
  [[ -n "$VLESS_UUID" ]] || die "VLESS_UUID or VLESS_URL is required"

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    [[ -n "$VLESS_SNI" ]] || die "VLESS_SNI required for REALITY"
    [[ -n "$VLESS_PBK" ]] || die "VLESS_PBK required for REALITY"
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    [[ -n "$VLESS_SNI" ]] || VLESS_SNI="$VLESS_HOST"
  fi
}

# ============ Config Generation ============

build_stream_settings() {
  local stream_settings

  # Base network settings
  local network_settings="{}"
  case "$VLESS_TRANSPORT" in
    ws)
      network_settings=$(jq -nc --arg path "${VLESS_PATH:-/}" '{wsSettings: {path: $path}}')
      ;;
    grpc)
      network_settings=$(jq -nc --arg sn "${VLESS_SERVICENAME:-}" '{grpcSettings: {serviceName: $sn}}')
      ;;
  esac

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    stream_settings=$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      --arg publicKey "$VLESS_PBK" \
      --arg shortId "$VLESS_SID" \
      --arg spiderX "$VLESS_SPIDERX" \
      --argjson netSettings "$network_settings" \
      '{
        network: $network,
        security: "reality",
        realitySettings: {
          serverName: $serverName,
          fingerprint: $fingerprint,
          publicKey: $publicKey,
          shortId: $shortId,
          spiderX: $spiderX
        }
      } + $netSettings')
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    stream_settings=$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      --argjson netSettings "$network_settings" \
      '{
        network: $network,
        security: "tls",
        tlsSettings: {
          serverName: $serverName,
          fingerprint: $fingerprint
        }
      } + $netSettings')
  else
    stream_settings=$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --argjson netSettings "$network_settings" \
      '{network: $network} + $netSettings')
  fi

  echo "$stream_settings"
}

generate_xray_config() {
  log_info "Generating Xray configuration..."

  local stream_settings=$(build_stream_settings)

  # Build DNS array
  IFS=',' read -ra DNS_ARR <<< "$DNS_SERVERS"
  local dns_json=$(printf '%s\n' "${DNS_ARR[@]}" | jq -R . | jq -s .)

  # Build user object with optional flow
  local user_obj
  if [[ -n "$VLESS_FLOW" ]]; then
    user_obj=$(jq -nc --arg id "$VLESS_UUID" --arg flow "$VLESS_FLOW" \
      '{id: $id, encryption: "none", flow: $flow}')
  else
    user_obj=$(jq -nc --arg id "$VLESS_UUID" \
      '{id: $id, encryption: "none"}')
  fi

  jq -nc \
    --arg loglevel "$XRAY_LOGLEVEL" \
    --arg port "$PROXY_PORT" \
    --arg host "$VLESS_HOST" \
    --arg vport "$VLESS_PORT" \
    --argjson user "$user_obj" \
    --argjson stream "$stream_settings" \
    --argjson dns "$dns_json" \
    '{
      log: {loglevel: $loglevel},
      dns: {
        servers: $dns,
        queryStrategy: "UseIP"
      },
      inbounds: [
        {
          tag: "transparent",
          port: ($port | tonumber),
          protocol: "dokodemo-door",
          settings: {
            network: "tcp",
            followRedirect: true
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls"]
          }
        },
        {
          tag: "socks",
          port: 1080,
          listen: "0.0.0.0",
          protocol: "socks",
          settings: {
            udp: true
          }
        },
        {
          tag: "http",
          port: 8080,
          listen: "0.0.0.0",
          protocol: "http"
        },
        {
          tag: "dns-in",
          port: 53,
          protocol: "dokodemo-door",
          settings: {
            address: "1.1.1.1",
            port: 53,
            network: "udp"
          }
        }
      ],
      outbounds: [
        {
          tag: "proxy",
          protocol: "vless",
          settings: {
            vnext: [{
              address: $host,
              port: ($vport | tonumber),
              users: [$user]
            }]
          },
          streamSettings: $stream
        },
        {
          tag: "direct",
          protocol: "freedom"
        },
        {
          tag: "dns-out",
          protocol: "dns"
        }
      ],
      routing: {
        rules: [
          {
            type: "field",
            inboundTag: ["dns-in"],
            outboundTag: "dns-out"
          }
        ]
      }
    }' > "$XRAY_CONFIG"

  log_info "Config written to $XRAY_CONFIG"
}

# ============ iptables ============

setup_dns() {
  log_info "Configuring DNS..."

  if [[ "$PRESERVE_DOCKER_DNS" == "true" ]] && grep -q '127\.0\.0\.11' /etc/resolv.conf 2>/dev/null; then
    log_info "Keeping Docker embedded DNS (127.0.0.11) for container name resolution"
    return
  fi

  cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF

  log_info "DNS configured (Xray on port 53)"
}

setup_iptables() {
  log_info "Setting up iptables redirect..."

  # Use iptables-legacy to avoid nftables conflicts
  local ipt="iptables-legacy"
  if ! command -v "$ipt" &>/dev/null; then
    ipt="iptables"
  fi

  local server_ip=$(resolve_host "$VLESS_HOST")
  if [[ -z "$server_ip" ]]; then
    log_warn "Could not resolve $VLESS_HOST, using hostname directly"
    server_ip="$VLESS_HOST"
  fi

  local chain="VLESS_GATEWAY"

  # Keep Docker-managed OUTPUT rules intact, especially embedded DNS on 127.0.0.11.
  $ipt -t nat -N "$chain" 2>/dev/null || true
  $ipt -t nat -F "$chain"
  $ipt -t nat -D OUTPUT -j "$chain" 2>/dev/null || true
  $ipt -t nat -I OUTPUT 1 -j "$chain"

  # Exclude traffic from xray user (prevents redirect loops)
  $ipt -t nat -A "$chain" -m owner --uid-owner xray -j RETURN

  # Exclude localhost and VLESS server
  $ipt -t nat -A "$chain" -d 127.0.0.0/8 -j RETURN
  $ipt -t nat -A "$chain" -d "$server_ip" -j RETURN

  # Keep container-to-container and LAN traffic local instead of sending it through VLESS.
  IFS=',' read -ra BYPASS_ARR <<< "$BYPASS_CIDRS"
  for cidr in "${BYPASS_ARR[@]}"; do
    cidr="${cidr// /}"
    [[ -n "$cidr" ]] || continue
    $ipt -t nat -A "$chain" -d "$cidr" -j RETURN
  done

  # Redirect all TCP to transparent proxy
  $ipt -t nat -A "$chain" -p tcp -j REDIRECT --to-ports "$PROXY_PORT"

  log_info "iptables configured via $ipt using chain $chain (excluding $server_ip and local subnets)"
}

# ============ Main ============

main() {
  log_info "Starting vless-gateway..."

  init_defaults

  # Parse VLESS config
  if [[ -n "${VLESS_URL:-}" ]]; then
    parse_vless_url "$VLESS_URL"
  fi
  validate_vless_config

  # Generate and validate config
  generate_xray_config

  if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    log_error "Invalid config generated:"
    cat "$XRAY_CONFIG" >&2
    exit 1
  fi

  # Setup networking
  setup_dns
  setup_iptables

  # Run Xray as dedicated user (traffic from this user is excluded from iptables redirect)
  log_info "Starting Xray as user 'xray'..."
  exec su-exec xray xray run -config "$XRAY_CONFIG"
}

main "$@"
