# WireGuard on K3s

This directory contains the reproducible, non-secret deployment definition for the WireGuard VPN running on `ci-builder`.

## Current host

- SSH alias: `ci-builder`
- Public endpoint: `109.199.96.150:51820/udp`
- Current public-IP geolocation: Lauterbourg, Grand Est, France
- VPN network: `10.13.13.0/24`
- Phone peer: `phone`

## Recovery on a replacement Ubuntu host

1. Install K3s:

   ```sh
   curl -sfL https://get.k3s.io | sh -
   ```

2. Enable forwarding and apply the firewall rules required for WireGuard:

   ```sh
   cat >/etc/sysctl.d/99-wireguard.conf <<'EOF'
   net.ipv4.ip_forward=1
   net.ipv4.conf.all.src_valid_mark=1
   EOF
   sysctl --system
   ufw allow 51820/udp comment 'WireGuard VPN'
   ufw route allow in on wg0 out on eth0 comment 'WireGuard client internet egress'
   ufw route allow in on eth0 out on wg0 comment 'WireGuard return traffic'
   ```

3. Restore the secret WireGuard directory from the encrypted off-host backup to `/var/lib/wireguard`.

4. Change `SERVERURL` in `wireguard-k3s.yaml` to the replacement host's public IP or DNS name, then apply it:

   ```sh
   kubectl apply -f wireguard-k3s.yaml
   kubectl -n wireguard rollout status deployment/wireguard
   ```

The WireGuard keys and peer configuration are intentionally not stored in this repository. Losing the encrypted backup means existing phone profiles must be regenerated.

## Optional Tor gateway

Run `setup-wireguard-tor.sh install --exit-country de` as root on the host to route WireGuard client TCP and DNS through Tor while blocking other forwarded traffic. Tor does not transparently carry general UDP, so games, calls, QUIC, and some apps may not work. The host's own management traffic remains direct.

Change the exit-country constraint later with `setup-wireguard-tor.sh set-exit nl` (or another two-letter country code), then verify the phone's public IP. This changes the Tor circuit constraint; it does not make the connection anonymous by itself.

## Location switching

WireGuard exits through the host where it runs. To offer other countries, deploy another exit node in that country and create a separate peer profile, or configure this server as a client of a multi-location VPN provider.
