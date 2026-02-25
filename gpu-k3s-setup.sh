#!/usr/bin/env bash
# gpu-k3s-setup.sh — Configure NVIDIA GPU passthrough for k3s.
# Run once after k3s is installed on a node with an NVIDIA GPU.
#
# Prerequisites:
#   - NVIDIA drivers installed (nvidia-smi works)
#   - nvidia-container-toolkit installed (apt install nvidia-container-toolkit)
#   - k3s installed and running
#
# Usage:
#   sudo bash gpu-k3s-setup.sh

set -euo pipefail

log() { echo "[gpu-k3s-setup] $*"; }
err() { echo "[gpu-k3s-setup] ERROR: $*" >&2; exit 1; }

# --- Verify running as root ---
[[ $EUID -eq 0 ]] || err "Must run as root (sudo)."

# --- Verify NVIDIA driver ---
if ! nvidia-smi &>/dev/null; then
    err "nvidia-smi not found. Install NVIDIA drivers first."
fi
log "NVIDIA driver OK: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"

# --- Verify nvidia-container-toolkit ---
if ! command -v nvidia-ctk &>/dev/null; then
    err "nvidia-ctk not found. Install nvidia-container-toolkit first:
    apt install nvidia-container-toolkit"
fi
log "nvidia-ctk OK: $(nvidia-ctk --version 2>/dev/null || echo 'installed')"

# --- Verify k3s ---
if ! systemctl is-active --quiet k3s; then
    err "k3s is not running."
fi
log "k3s is active."

# --- Set nvidia as the default containerd runtime for k3s ---
# k3s v1.31+ (containerd 2.0) auto-detects nvidia-container-runtime and adds
# it as a named runtime. We just need to set it as default so the device plugin
# pod can detect the GPU. We extend the base template (not replace it).
CONTAINERD_DIR="/var/lib/rancher/k3s/agent/etc/containerd"
CONTAINERD_TMPL="$CONTAINERD_DIR/config.toml.tmpl"
mkdir -p "$CONTAINERD_DIR"

log "Writing containerd config template at $CONTAINERD_TMPL ..."
cat > "$CONTAINERD_TMPL" <<'TMPL'
{{ template "base" . }}

[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = "nvidia"
TMPL
log "containerd config template written."

# --- Restart k3s to pick up new runtime ---
log "Restarting k3s..."
k3s-killall.sh 2>/dev/null || true
systemctl start k3s
log "k3s started. Waiting for node to be ready..."
sleep 15

# --- Deploy NVIDIA device plugin DaemonSet ---
DEVICE_PLUGIN_VERSION="v0.17.0"
DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

log "Deploying NVIDIA device plugin ${DEVICE_PLUGIN_VERSION}..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f "$DEVICE_PLUGIN_URL"
log "Device plugin deployed. Waiting for pod to start..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || true

# --- Verify GPU is advertised ---
log "Checking node GPU resources..."
sleep 5
GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "$GPU_COUNT" -gt 0 ]]; then
    log "SUCCESS: Node advertising ${GPU_COUNT} GPU(s)."
else
    log "WARNING: GPU not yet visible in node allocatable resources."
    log "Check device plugin logs: kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin-ds"
fi

log "Done."
