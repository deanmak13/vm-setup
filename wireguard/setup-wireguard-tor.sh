#!/usr/bin/env bash
set -Eeuo pipefail

# Optional WireGuard-over-Tor gateway for a single-node K3s host.
# WireGuard keys remain in /var/lib/wireguard and are never stored here.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NS=wireguard
ACTION=install
EXIT_COUNTRY=de
SERVER_URL=

usage() {
  cat <<'EOF'
Usage:
  setup-wireguard-tor.sh install [--exit-country CC] [--server-url HOST]
  setup-wireguard-tor.sh set-exit CC
  setup-wireguard-tor.sh status

Tor carries WireGuard client TCP and DNS. Other forwarded traffic is blocked
to prevent non-Tor UDP leaks. Host management traffic stays direct.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

country_ok() {
  [[ ${1:-} =~ ^[A-Za-z]{2}$ ]] || die "exit country must be a two-letter code"
}

torrc() {
  cat <<EOF
DataDirectory /var/lib/tor
RunAsDaemon 0
User debian-tor
SocksPort 0
TransPort 0.0.0.0:9040
DNSPort 0.0.0.0:5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
ClientUseIPv6 0
ExitNodes {${1,,}}
StrictNodes 1
EOF
}

while (($#)); do
  case $1 in
    install|set-exit|status) ACTION=$1; shift ;;
    --exit-country) EXIT_COUNTRY=$2; shift 2 ;;
    --server-url) SERVER_URL=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ $ACTION == set-exit && $EXIT_COUNTRY == de ]]; then
        EXIT_COUNTRY=$1; shift
      else
        die "unknown argument: $1"
      fi
      ;;
  esac
done

if [[ $ACTION == status ]]; then
  kubectl -n "$NS" get deployment,pod -l 'app in (wireguard,tor-gateway)' -o wide
  kubectl -n "$NS" get configmap tor-config -o jsonpath='{.data.torrc}' 2>/dev/null || true
  exit 0
fi

country_ok "$EXIT_COUNTRY"

if [[ $ACTION == set-exit ]]; then
  kubectl -n "$NS" get deployment tor-gateway >/dev/null || die "Tor gateway is not installed"
  kubectl -n "$NS" create configmap tor-config \
    --from-literal=torrc="$(torrc "$EXIT_COUNTRY")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" rollout restart deployment/tor-gateway
  kubectl -n "$NS" rollout status deployment/tor-gateway --timeout=600s
  echo "Tor exit country changed to ${EXIT_COUNTRY,,}"
  exit 0
fi

if [[ -z $SERVER_URL ]]; then
  SERVER_URL=$(curl -4fsS --max-time 10 https://api.ipify.org) || die "cannot determine public IPv4"
fi

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -
fi
systemctl enable --now k3s
kubectl get nodes >/dev/null

cat >/etc/sysctl.d/99-wireguard-tor.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system >/dev/null

if command -v ufw >/dev/null 2>&1; then
  ufw allow 51820/udp comment "WireGuard VPN" >/dev/null
  ufw allow in on wg0 to any port 9040 proto tcp comment "Tor TCP from WireGuard" >/dev/null
  ufw allow in on wg0 to any port 5353 proto udp comment "Tor DNS from WireGuard" >/dev/null
  ufw allow in on wg0 to any port 5353 proto tcp comment "Tor DNS TCP from WireGuard" >/dev/null
fi

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
EOF

sed "s#value: 109.199.96.150#value: $SERVER_URL#" "$ROOT_DIR/wireguard-k3s.yaml" | kubectl apply -f - >/dev/null

kubectl -n "$NS" create configmap tor-config \
  --from-literal=torrc="$(torrc "$EXIT_COUNTRY")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tor-gateway
  namespace: wireguard
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: tor-gateway
  template:
    metadata:
      labels:
        app: tor-gateway
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: tor
          image: debian:bookworm-slim
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          command: ["sh", "-ec"]
          args:
            - |
              export DEBIAN_FRONTEND=noninteractive
              apt-get update -qq
              apt-get -y -qq -o Dpkg::Options::=--force-confold --no-install-recommends install ca-certificates iptables tor tor-geoipdb
              mkdir -p /var/lib/tor
              chown -R debian-tor:debian-tor /var/lib/tor
              iptables -t nat -N WG_TOR 2>/dev/null || true
              iptables -t nat -F WG_TOR
              iptables -t nat -A WG_TOR -p udp --dport 53 -j REDIRECT --to-ports 5353
              iptables -t nat -A WG_TOR -p tcp -j REDIRECT --to-ports 9040
              iptables -t nat -C PREROUTING -i wg0 -j WG_TOR 2>/dev/null || iptables -t nat -A PREROUTING -i wg0 -j WG_TOR
              iptables -C FORWARD -i wg0 -j REJECT 2>/dev/null || iptables -I FORWARD 1 -i wg0 -j REJECT
              exec tor -f /etc/tor/torrc
          readinessProbe:
            tcpSocket:
              port: 9040
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 9040
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - name: tor-config
              mountPath: /etc/tor/torrc
              subPath: torrc
              readOnly: true
            - name: tor-data
              mountPath: /var/lib/tor
      volumes:
        - name: tor-config
          configMap:
            name: tor-config
        - name: tor-data
          hostPath:
            path: /var/lib/tor-k3s
            type: DirectoryOrCreate
EOF

kubectl -n "$NS" rollout restart deployment/tor-gateway >/dev/null
kubectl -n "$NS" rollout status deployment/wireguard --timeout=300s
kubectl -n "$NS" rollout status deployment/tor-gateway --timeout=600s
echo "WireGuard-over-Tor installed; exit country=${EXIT_COUNTRY,,}; endpoint=$SERVER_URL:51820"
