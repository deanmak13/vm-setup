# ci-builder → OpenBao (TST) access

## Problem this replaces

The terraform-apply workflow's standalone `platform-secrets-apply` job needs
`OPENBAO_ADDR` reachable from ci-builder. ci-builder is its own local k3s
host (109.199.96.150), not a TST-cluster node — there is no
`*.svc.cluster.local` DNS or pod/service-CIDR route from ci-builder into
TST. Two prior approaches both required a human to keep a process alive
and died silently the moment that process exited:

- `kubectl port-forward` to 127.0.0.1:18200 (no kubeconfig for the TST
  cluster is even present on ci-builder — confirmed by probe, this was
  never actually viable long-term)
- `ssh -R 18200` reverse tunnel from a TST node (the `OPEN ITEM` this
  file's setup step used to leave for a human)

## Fix: cloudflared Access TCP proxy, kept alive by systemd

`cloudflared-access-openbao.service` runs `cloudflared access tcp` as a
long-lived systemd service on ci-builder. It authenticates to a
Cloudflare Access Application (service-token-gated, no public/human login
path — see `pneuma-deployments/infrastructure/terraform/modules/bootstrap/openbao_ci_access.tf`)
and exposes a **local** `127.0.0.1:18200` — the same address
`OPENBAO_ADDR` already points at, so **the GitHub secret does not need to
change**. The route out is: ci-builder → Cloudflare edge (Access-authenticated,
never public) → the TST cluster's existing cloudflared tunnel → OpenBao's
in-cluster Service. No inbound port is opened on TST; ci-builder never
needs a TST kubeconfig or network route.

## One-time operator setup (Dean)

1. Apply the `pneuma-deployments` PR that adds `openbao_ci_access.tf` —
   this provisions the Cloudflare Access Application, Policy, and Service
   Token, plus the `openbao-ci-tst.neopneuma.com` DNS record.
2. Read the token out of Terraform state / outputs:
   ```
   terraform output openbao_ci_service_token_id
   terraform output openbao_ci_service_token_secret
   ```
3. Push the new `openbao-ci-tst.neopneuma.com` ingress rule into the TST
   tunnel's remotely-managed config (see
   `platform/overlays/tst/cloudflare-tunnel/config.yaml` — the file
   documents the rule; the live push is the same manual
   `PUT /accounts/{id}/cfd_tunnel/{tunnel}/configurations` step every
   other route in that file already requires).
4. On ci-builder (root@109.199.96.150):
   ```bash
   mkdir -p /etc/cloudflared
   cat > /etc/cloudflared/openbao-access.env <<EOF
   CF_ACCESS_HOSTNAME=openbao-ci-tst.neopneuma.com
   CF_ACCESS_CLIENT_ID=<client_id from step 2>
   CF_ACCESS_CLIENT_SECRET=<client_secret from step 2>
   EOF
   chmod 600 /etc/cloudflared/openbao-access.env
   ```
   This file is NOT in git (it holds a live credential) and is not
   restored by `ci-builder-export-state.sh`/S3 state sync today — back it
   up out-of-band (e.g. alongside the existing `.gh-pat` handling) if you
   want it to survive a host replacement without repeating steps 1-4.
5. Re-run `ci-builder-bootstrap.sh` (or run its new install step
   directly) — it installs `cloudflared` if missing, installs the unit
   from `cloudflared-access-openbao.service`, and enables+starts it IF
   `/etc/cloudflared/openbao-access.env` is present. If the env file is
   absent it skips the step and logs an OPEN ITEM, same as before.
6. Verify: `systemctl status cloudflared-access-openbao` should be
   `active (running)`, and `curl -s http://127.0.0.1:18200/v1/sys/health`
   from ci-builder should get a JSON response from OpenBao (not
   connection refused).

No `OPENBAO_ADDR` / `OPENBAO_ADMIN_TOKEN` GitHub secret changes are
needed — `OPENBAO_ADDR` stays `http://127.0.0.1:18200`.
