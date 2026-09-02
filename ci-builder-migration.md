# ci-builder host migration runbook

Migrates the CI host (`root@109.199.96.150`, Contabo, "ci-builder") to a new
Cloud VPS 8 (8c/24GB/300GB, fresh Ubuntu 24.04), losslessly and push-button.

Inventory taken 2026-08-15 from the live Contabo host.

## 1. What's on the old host

**Systemd, beyond stock Ubuntu:**
- `actions.runner.*` services, one per runner — the current inventory is the
  `RUNNERS` table in `ci-builder-bootstrap.sh` (the only copy; see §3). At
  migration time the old host had 13 (9 running, 4 disabled: branding, docs,
  mem0, ops).
- `runner-reaper.timer` (every 5min) + `runner-reaper.service` — installed
  2026-08-14 by `runner-reaper.sh`, reads `/root/.runner-reaper-token`.
- `ci-disk-janitor.timer` (hourly) + `ci-disk-janitor.service` — installed
  2026-08-15 by `ci-disk-janitor.sh`.
- `k3s.service` — single-node k3s. No `wg-quick@`/`/etc/wireguard` — WireGuard
  runs *inside* k3s (namespace `wireguard`: `deployment/wireguard` +
  `deployment/tor-gateway`), per `wireguard/wireguard-k3s.yaml` in this repo.
- No crontabs (root or ubuntu), no nginx/caddy/reverse-tunnel systemd units
  found on this pass (the OpenBao tunnel, see §5, is run ad hoc via `ssh -R`,
  not a persistent unit).

**k3s cluster contents (`kubectl get all -A`):**
- `kube-system`: coredns, local-path-provisioner, metrics-server, traefik —
  all stock k3s add-ons, 100% reproducible by `curl -sfL https://get.k3s.io | sh -`.
- `wireguard` namespace: `deployment/wireguard` + `deployment/tor-gateway`,
  both from `wireguard/wireguard-k3s.yaml`. Many stale `Evicted` /
  `ContainerStatusUnknown` pods from past reschedules — cosmetic, ignore.
- **`kubectl get pvc -A` → "No resources found" — zero PersistentVolumeClaims
  on this cluster.** The entire k3s cluster is reproducible from git; nothing
  in it is precious except the secret directory below.

**Precious STATE (must be copied, cannot be reproduced):**
- `/var/lib/wireguard` (72KB) — hostPath-mounted into the `wireguard` pod.
  Contains the WireGuard server private key, `peer_phone/` config, and
  coredns/templates/wg_confs subdirs. **Losing this means the `phone` peer
  profile must be regenerated from scratch** (already called out in
  `wireguard/README.md`).
- `/root/.runner-reaper-token` (41 bytes) — the GitHub PAT the reaper watchdog
  polls with.

**REPRODUCIBLE, not state (do not copy):**
- Every runner's `.runner`/`.credentials` files — **GitHub Actions runners
  cannot be migrated between hosts.** Every runner must re-register fresh
  (registration tokens are one-time-use and tied to the host). See §3.
- Docker images, buildx builder containers/volumes (11 `moby/buildkit`
  containers observed, all ephemeral `docker buildx` state) — repulled/
  rebuilt on first use.
- k3s cluster objects themselves (see above — reproducible from manifests).
- Non-stock packages: `docker-ce`/`docker-ce-cli`/`docker-ce-rootless-extras`
  (5:29.6.0), `gh` CLI (`/usr/local/bin/gh`). Node/Python toolchains are
  runner-managed (each job's setup steps install what they need), not
  host state.

**Runner inventory:** the `RUNNERS` table in `ci-builder-bootstrap.sh` — one
row per runner: `<repo> <runner-name> <labels> <enabled: y/n>`. It is the only
copy (this file used to carry a second one, which drifted: the build-lane
runners were never added to it and three drained runners stayed listed). The
labels column is the lane a workflow's `runs-on:` selects — `ci-builder` for
gate jobs, `ci-builder-build` for image builds — and must match the workflows
or jobs queue forever with no runner match. `enabled=n` installs the service
and leaves it stopped.

## 2. Order of operations

1. **On the OLD host**, as root:
   ```sh
   bash ci-builder-export-state.sh
   ```
   Produces `/root/ci-builder-state.tgz` (WireGuard secret dir + reaper
   token + a manifest). Verify its listing looks right, then copy it off:
   ```sh
   scp root@109.199.96.150:/root/ci-builder-state.tgz .
   ```

2. **Provision the new Cloud VPS 8**, fresh Ubuntu 24.04, note its public IP.

3. **Copy the state tarball and a GitHub PAT to the new host:**
   ```sh
   scp ci-builder-state.tgz root@<NEW_IP>:/root/
   scp my-gh-pat.txt root@<NEW_IP>:/root/.gh-pat   # repo-scope classic PAT
   scp -r vm-setup root@<NEW_IP>:/root/vm-setup
   ```

4. **On the NEW host**, as root:
   ```sh
   cd /root/vm-setup
   bash ci-builder-bootstrap.sh --gh-token-file /root/.gh-pat --state-tarball /root/ci-builder-state.tgz
   ```
   This installs Docker, gh, k3s, sysctl tuning, restores `/var/lib/wireguard`
   and the reaper token, installs the reaper + janitor watchdogs, and
   re-registers every runner in the `RUNNERS` table (loop mints a fresh
   registration token per row via
   `POST /repos/{owner}/{repo}/actions/runners/registration-token`, downloads
   runner v2.336.0, configures with `--labels self-hosted,<row labels>`,
   installs the systemd service, and starts it — unless the row is
   `enabled=n`, in which case the service is installed but left stopped).

5. **Apply the WireGuard k3s manifest manually** (deliberately not
   automated — a one-time, operator-confirmed step):
   - Edit `wireguard/wireguard-k3s.yaml`: set `SERVERURL` to the new host's
     public IP or DNS name.
   - Run:
     ```sh
     kubectl apply -f wireguard/wireguard-k3s.yaml
     kubectl -n wireguard rollout status deployment/wireguard
     ```
   - If using the Tor exit gateway: `setup-wireguard-tor.sh install --exit-country de`
     (see `wireguard/README.md`).

6. **Point DNS / firewall rules at the new host's IP** (out of scope here —
   depends on where `109.199.96.150` is referenced: Cloudflare, GitHub
   webhook allow-lists, etc. — grep for the old IP across repos and infra
   config before decommissioning the old host).

7. **Verify** (see §4).

8. **Decommission the old host** only after §4 passes and at least one real
   CI run has succeeded per repo on the new host.

## 3. Runner re-registration — what the loop does per runner

For each `<repo> <runner-name> <labels> <enabled>` row of `RUNNERS`,
`ci-builder-bootstrap.sh`:
1. Skips if `/home/ubuntu/actions-runner-<runner-name>/.runner` already exists
   (idempotent — safe to re-run after a partial failure, and the way a newly
   added row is registered on a live host).
2. Mints a registration token: `gh api -X POST repos/deanmak13/<repo>/actions/runners/registration-token`
   (script uses raw `curl` with the PAT; equivalent to this `gh api` call).
3. Downloads `actions-runner-linux-x64-2.336.0.tar.gz`, extracts into
   `/home/ubuntu/actions-runner-<runner-name>` — one directory per runner,
   never per repo: `runner-reaper`, `ci-disk-janitor` and the export
   manifest all key off that name, and a repo has up to four runners here.
4. `./config.sh --unattended --url https://github.com/deanmak13/<repo> --token <TOKEN> --name <runner-name> --labels self-hosted,<labels> --work _work`
5. `./svc.sh install ubuntu`, then `./svc.sh start` (unless `enabled=n`).

**Manual equivalent for a single repo** (if the loop needs to be redone for
one repo only):
```sh
TOKEN=$(gh api -X POST repos/deanmak13/pneuma-engine/actions/runners/registration-token --jq .token)
cd /home/ubuntu/actions-runner-pneuma-engine-contabo
./config.sh --unattended --url https://github.com/deanmak13/pneuma-engine \
  --token "$TOKEN" --name pneuma-engine-contabo --labels self-hosted,ci-builder --work _work
sudo ./svc.sh install ubuntu && sudo ./svc.sh start
```

**Labels matter**: every Pneuma workflow's `runs-on:` targets
`[self-hosted, ci-builder]` or `[self-hosted, ci-builder-build]`. If a runner
registers with different/missing labels, GitHub Actions jobs queue forever
with no runner match — verify with
`gh api repos/deanmak13/<repo>/actions/runners --jq '.runners[] | {name,labels}'`
per repo after registration. `tests/runner-inventory.test.sh` proves the
table, the loop and the reaper's directory → repo resolution agree.

## 4. Verification checklist

```sh
# One runner service per RUNNERS row, enabled=y rows running:
systemctl list-units 'actions.runner.*' --no-legend

# k3s healthy, wireguard + tor-gateway pods Running:
kubectl get all -A

# Watchdog timers active:
systemctl list-timers | grep -E 'reaper|janitor'

# Reaper token installed, correct perms:
ls -la /root/.runner-reaper-token   # -rw------- root root

# WireGuard: confirm the phone peer can still connect using its EXISTING
# profile (proves /var/lib/wireguard restored correctly — no regeneration
# needed).

# Trigger one real workflow run per repo (or at minimum: pneuma, pneuma-engine,
# pneuma-portal, pneuma-deployments — the actively-enabled ones) and confirm
# it picks up on the new runner and completes green.
```

## 5. Open items for Dean

- **OpenBao reverse tunnel**: `terraform-apply` on this host currently
  depends on a manually-run `ssh -R 18200:127.0.0.1:8200 <tst-node>` from the
  TST node, feeding `OPENBAO_ADDR=http://127.0.0.1:18200` locally. This
  tunnel is NOT a persistent systemd unit (none was found in this
  inventory) — it's started ad hoc and must be re-established on the new
  host, or replaced with a durable mechanism (e.g. a `systemd` unit with
  `autossh`, or a proper network path to OpenBao that doesn't need a
  tunnel). **Until this is re-created, `terraform-apply` jobs on the new
  host will fail to reach OpenBao.**
- GitHub repo secrets that set `OPENBAO_ADDR=http://127.0.0.1:18200` (or
  similar localhost reference) do NOT need to change — they'll keep working
  automatically once the tunnel pattern (or its replacement) is re-created
  on the new host, since the address is always relative to wherever the
  runner executes.
- Old-host IP `109.199.96.150` may be referenced elsewhere (Cloudflare DNS,
  GitHub webhook IP allow-lists, firewall rules) — not exhaustively swept
  here; grep infra config before decommissioning.
- The 4 runners that were disabled on the old host (branding, docs, mem0,
  ops) were never re-registered here. branding/docs/mem0 run every workflow
  on `ubuntu-latest`, so they have no row. pneuma-ops targets
  `[self-hosted, ci-builder]` in five workflows (a scheduled
  `validate-security-deploy-parity` among them) and had queued a run a day
  that GitHub cancelled unrun since the migration — it is back in the table
  as `enabled=y`.
