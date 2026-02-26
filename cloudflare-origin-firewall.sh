#!/usr/bin/env bash
# cloudflare-origin-firewall.sh — Restrict HTTP/HTTPS traffic to Cloudflare IPs only
#
# Implements: https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/#configure-origin-server
#
# This script configures iptables to:
#   1. Allow SSH (port 22) from anywhere (so you don't lock yourself out)
#   2. Allow HTTP/HTTPS (ports 80, 443) ONLY from Cloudflare IP ranges
#   3. Allow localhost and established connections
#   4. Allow k3s internal traffic (pod/service CIDRs)
#   5. Drop all other inbound HTTP/HTTPS traffic
#
# IMPORTANT: API subdomains that use Cloudflare DNS-only (grey cloud) will NOT
# work through this firewall since traffic comes directly from clients (e.g. Meta).
# Those subdomains must be proxied (orange cloud) through Cloudflare for this to work.
# If you have DNS-only subdomains, do NOT run this script — use Traefik middleware
# (IPAllowList) on a per-ingress basis instead.
#
# Usage: sudo bash cloudflare-origin-firewall.sh [--apply|--dry-run|--remove]

set -euo pipefail

# Cloudflare IPv4 ranges — https://www.cloudflare.com/ips-v4/
CF_IPV4=(
    173.245.48.0/20
    103.21.244.0/22
    103.22.200.0/22
    103.31.4.0/22
    141.101.64.0/18
    108.162.192.0/18
    190.93.240.0/20
    188.114.96.0/20
    197.234.240.0/22
    198.41.128.0/17
    162.158.0.0/15
    104.16.0.0/13
    104.24.0.0/14
    172.64.0.0/13
    131.0.72.0/22
)

# Cloudflare IPv6 ranges — https://www.cloudflare.com/ips-v6/
CF_IPV6=(
    2400:cb00::/32
    2606:4700::/32
    2803:f800::/32
    2405:b500::/32
    2405:8100::/32
    2a06:98c0::/29
    2c0f:f248::/32
)

# k3s internal CIDRs
K3S_POD_CIDR="10.42.0.0/16"
K3S_SVC_CIDR="10.43.0.0/16"

CHAIN_NAME="CLOUDFLARE-ONLY"

usage() {
    echo "Usage: $0 [--apply|--dry-run|--remove]"
    echo ""
    echo "  --dry-run   Show rules that would be applied (default)"
    echo "  --apply     Apply the firewall rules"
    echo "  --remove    Remove the Cloudflare firewall rules"
    exit 1
}

remove_rules() {
    echo "=== Removing Cloudflare origin firewall rules ==="

    # Remove jump rules from INPUT
    iptables -D INPUT -p tcp --dport 80 -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 -j "$CHAIN_NAME" 2>/dev/null || true

    # Flush and delete chain
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true

    # Same for IPv6
    ip6tables -D INPUT -p tcp --dport 80 -j "$CHAIN_NAME" 2>/dev/null || true
    ip6tables -D INPUT -p tcp --dport 443 -j "$CHAIN_NAME" 2>/dev/null || true
    ip6tables -F "$CHAIN_NAME" 2>/dev/null || true
    ip6tables -X "$CHAIN_NAME" 2>/dev/null || true

    echo "Done. Cloudflare firewall rules removed."
}

apply_rules() {
    echo "=== Applying Cloudflare origin firewall rules ==="

    # Clean up any existing rules first
    remove_rules 2>/dev/null || true

    # Create custom chain
    iptables -N "$CHAIN_NAME"

    # Allow k3s internal traffic
    iptables -A "$CHAIN_NAME" -s "$K3S_POD_CIDR" -j RETURN
    iptables -A "$CHAIN_NAME" -s "$K3S_SVC_CIDR" -j RETURN

    # Allow localhost
    iptables -A "$CHAIN_NAME" -s 127.0.0.0/8 -j RETURN

    # Allow Cloudflare IPv4 ranges
    for cidr in "${CF_IPV4[@]}"; do
        iptables -A "$CHAIN_NAME" -s "$cidr" -j RETURN
    done

    # Drop everything else
    iptables -A "$CHAIN_NAME" -j DROP

    # Jump to our chain for HTTP/HTTPS
    iptables -I INPUT -p tcp --dport 80 -j "$CHAIN_NAME"
    iptables -I INPUT -p tcp --dport 443 -j "$CHAIN_NAME"

    # IPv6
    ip6tables -N "$CHAIN_NAME"
    ip6tables -A "$CHAIN_NAME" -s ::1/128 -j RETURN
    for cidr in "${CF_IPV6[@]}"; do
        ip6tables -A "$CHAIN_NAME" -s "$cidr" -j RETURN
    done
    ip6tables -A "$CHAIN_NAME" -j DROP
    ip6tables -I INPUT -p tcp --dport 80 -j "$CHAIN_NAME"
    ip6tables -I INPUT -p tcp --dport 443 -j "$CHAIN_NAME"

    echo "Done. Only Cloudflare IPs can reach ports 80/443."
    echo ""
    echo "To persist across reboots, install iptables-persistent:"
    echo "  sudo apt-get install -y iptables-persistent"
    echo "  sudo netfilter-persistent save"
}

dry_run() {
    echo "=== Cloudflare Origin Firewall — Dry Run ==="
    echo ""
    echo "The following iptables rules would be applied:"
    echo ""
    echo "Custom chain: $CHAIN_NAME"
    echo "  RETURN  k3s pods    $K3S_POD_CIDR"
    echo "  RETURN  k3s svcs    $K3S_SVC_CIDR"
    echo "  RETURN  localhost   127.0.0.0/8"
    for cidr in "${CF_IPV4[@]}"; do
        echo "  RETURN  cloudflare  $cidr"
    done
    echo "  DROP    (all other sources)"
    echo ""
    echo "INPUT chain jumps:"
    echo "  tcp dport 80  → $CHAIN_NAME"
    echo "  tcp dport 443 → $CHAIN_NAME"
    echo ""
    echo "IPv6 Cloudflare ranges also configured."
    echo ""
    echo "WARNING: Do NOT apply if you have DNS-only (grey cloud) subdomains"
    echo "that need direct access from non-Cloudflare IPs (e.g. Meta webhooks)."
    echo ""
    echo "Run with --apply to activate."
}

# Parse arguments
ACTION="${1:---dry-run}"
case "$ACTION" in
    --apply)  apply_rules ;;
    --dry-run) dry_run ;;
    --remove) remove_rules ;;
    *) usage ;;
esac
