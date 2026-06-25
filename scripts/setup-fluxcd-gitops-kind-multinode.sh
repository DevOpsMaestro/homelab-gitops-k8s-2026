#!/bin/bash
set -euo pipefail

# Shared version pins and CLUSTER_NAME live in versions.env at the repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"

GITHUB_USER="DevOpsMaestro"
REPO_NAME="homelab-gitops-k8s-2026"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
CLUSTER_PATH="clusters/kind"

LOCAL_ARCH=$(uname -m)
if [[ "$LOCAL_ARCH" == "arm64" ]]; then
  DOCKER_PLATFORM="linux/arm64"
else
  DOCKER_PLATFORM="linux/amd64"
fi

# ── Step 0: Pre-flight — verify all Helm chart sources are reachable ──────────
# Runs before any destructive work so a bad URL or network outage fails fast
# instead of being discovered after the cluster is already up and Flux is running.
printf "\n[0/10] Pre-flight: verifying Helm chart sources\n"

_check_http_repo() {
  local name=$1 url=$2
  if curl -fs --max-time 10 "${url}/index.yaml" > /dev/null; then
    printf "  ✓ %-25s %s\n" "$name" "$url"
  else
    printf "  ✗ %-25s %s — UNREACHABLE\n" "$name" "$url"
    PREFLIGHT_FAILED=1
  fi
}

_check_oci_chart() {
  local name=$1 ref=$2 version=$3
  if helm show chart "${ref}" --version "${version}" &> /dev/null; then
    printf "  ✓ %-25s %s@%s\n" "$name" "$ref" "$version"
  else
    printf "  ✗ %-25s %s@%s — UNREACHABLE\n" "$name" "$ref" "$version"
    PREFLIGHT_FAILED=1
  fi
}

PREFLIGHT_FAILED=0

_check_http_repo  "cilium"               "https://helm.cilium.io"
_check_http_repo  "cert-manager"         "https://charts.jetstack.io"
_check_http_repo  "openebs"              "https://openebs.github.io/openebs"
_check_http_repo  "istio"                "https://istio-release.storage.googleapis.com/charts"
_check_http_repo  "prometheus-community" "https://prometheus-community.github.io/helm-charts"
_check_http_repo  "grafana"              "https://grafana.github.io/helm-charts"
_check_http_repo  "kubescape"            "https://kubescape.github.io/helm-charts"

if [[ $PREFLIGHT_FAILED -eq 1 ]]; then
  printf "\n  ✗ Pre-flight failed — fix the unreachable sources above before continuing.\n"
  exit 1
fi

printf "  ✓ All chart sources reachable\n"

# Cilium images to pre-load into every KinD node.
# Pulled with --platform "$DOCKER_PLATFORM" to ensure the correct manifest layers are
# present locally — `kind load` imports into containerd which requires the
# exact digest for the node's platform; a multi-arch pull without --platform
# may omit layers and cause "content digest not found" on import.
# The cilium-envoy image is pinned by a long tag inside the chart and differs
# every patch release — we extract it from `helm template` at runtime rather
# than hard-coding it, so it is always correct for CILIUM_VERSION.
# grep exits 1 when there is no match; || true prevents set -e from aborting
# since an empty result is expected and handled by the [[ -z ... ]] check below.
CILIUM_ENVOY_IMAGE=$(helm template cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  2>/dev/null \
  | grep "image: quay.io/cilium/cilium-envoy" \
  | head -1 \
  | awk '{print $2}' \
  | tr -d '"') || true

if [[ -z "$CILIUM_ENVOY_IMAGE" ]]; then
  printf "  ⚠ Could not resolve cilium-envoy image from chart — skipping pre-pull\n"
  printf "    It will pull from the registry during pod startup instead.\n"
fi

CILIUM_IMAGES=(
  "quay.io/cilium/cilium:v${CILIUM_VERSION}"
  "quay.io/cilium/operator-generic:v${CILIUM_VERSION}"
  "quay.io/cilium/hubble-relay:v${CILIUM_VERSION}"
  # hubble-ui and hubble-ui-backend are omitted — Hubble UI is disabled by
  # default in infrastructure/controllers/cilium.yaml (hubble.ui.enabled: false).
  # Enable it there first, then run `make pull-images && make load-images`.
)

# Append envoy only if successfully resolved
if [[ -n "$CILIUM_ENVOY_IMAGE" ]]; then
  CILIUM_IMAGES+=("${CILIUM_ENVOY_IMAGE}")
fi

# ── Step 1: KinD cluster ──────────────────────────────────────────────────────
printf "\n[1/10] Creating KinD cluster: $CLUSTER_NAME\n"
# disableDefaultCNI: true — prevents kindnet from racing with Cilium.
# kubeProxyMode: none    — Cilium's eBPF dataplane replaces kube-proxy entirely.
# Both flags are REQUIRED when using Cilium's kubeProxyReplacement: true.
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: ipv4
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  apiServerAddress: 127.0.0.1
  apiServerPort: 6443
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
  - role: control-plane
    image: kindest/node:${K8S_VER}
    # Tune the single-instance etcd embedded in the KinD control-plane.
    # Default quota-backend-bytes is 2 GiB; this stack installs 120+ CRDs whose
    # validation schemas are large — raising the quota to 8 GiB prevents the
    # "mvcc: database space exceeded" alarm that forces a defrag before any write.
    # auto-compaction keeps the MVCC history bounded. Without compaction, the
    # revision count grows indefinitely after every Flux reconcile, causing
    # watch-mark-send-over-slow-network warnings and slow LIST responses. A
    # 1-hour periodic compaction keeps the live revisions in a small window that
    # etcd can serve quickly.
    kubeadmConfigPatches:
      - |
        apiVersion: kubeadm.k8s.io/v1beta3
        kind: ClusterConfiguration
        etcd:
          local:
            extraArgs:
              quota-backend-bytes: "8589934592"
              auto-compaction-retention: "1"
              auto-compaction-mode: periodic
    # extraPortMappings forward localhost ports into the KinD node container.
    #
    # Port 8888 (not a NodePort) is used instead of 30080 because Cilium's kube-proxy
    # replacement installs BPF socket programs that block userspace bind() on the entire
    # NodePort range (30000-32767). The nginx nodeport-proxy DaemonSet in
    # apps/overlays/kind/istio/nodeport-proxy.yaml listens on 8888 and forwards to the
    # Envoy Gateway proxy ClusterIP, bypassing the Cilium NodePort limitation.
    #
    #   localhost:8080  →  containerPort:8888  →  nginx (hostNetwork)
    #   nginx  →  contour-contour-envoy.contour.svc:80  →  HTTPProxy
    extraPortMappings:
      - containerPort: 8888
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443
        hostPort: 8443
        protocol: TCP
      # iperf3 TCP load-testing path:
      #   localhost:32111  →  containerPort:9111  →  nginx stream{}
      #   nginx  →  iperf3.iperf3.svc:32111  (direct; no ingress controller)
      # Port 9111 is below the NodePort range (30000-32767) so nginx can
      # bind() on it despite Cilium's BPF socket programs blocking that range.
      - containerPort: 9111
        hostPort: 32111
        protocol: TCP
  # - role: control-plane
  #   image: kindest/node:${K8S_VER}
  # - role: control-plane
  #   image: kindest/node:${K8S_VER}
  - role: worker
    image: kindest/node:${K8S_VER}
  - role: worker
    image: kindest/node:${K8S_VER}
  # - role: worker
  #   image: kindest/node:${K8S_VER}
EOF

# ── Step 2: Pre-pull and load Cilium images into KinD nodes ──────────────────
# KinD nodes are Docker containers with their own image cache, isolated from
# the host Docker daemon. `kind load docker-image` copies an image from the
# host daemon into every node's containerd store so kubelet never hits the
# network when the pod is scheduled.
#
# --platform "$DOCKER_PLATFORM" is required: without it Docker may pull a multi-arch
# manifest index but only cache the host-native layers. When `kind load` then
# tries to import into the node's containerd (which is always "$DOCKER_PLATFORM"),
# containerd looks for the amd64-specific digest and gets "content digest not
# found" if those layers weren't pulled.
printf "\n[2/10] Pre-pulling Cilium and Istio images and loading into KinD nodes\n"

# Istio gateway image — pre-loaded so the ingressgateway pod never hits Docker Hub
# from inside the cluster (which has no registry credentials).
ISTIO_IMAGES=(
  "docker.io/istio/proxyv2:${ISTIO_VERSION}"
)

ALL_IMAGES=("${CILIUM_IMAGES[@]}" "${ISTIO_IMAGES[@]}")

for IMAGE in "${ALL_IMAGES[@]}"; do
  printf "  pulling %s\n" "$IMAGE"
  docker pull --platform "$DOCKER_PLATFORM" "$IMAGE"
  # Load to all nodes in parallel — one docker save pipe per node.
  # Using docker save (single-platform) avoids the --all-platforms issue with
  # `kind load docker-image` where multi-arch manifests lack the node's platform
  # layers and containerd reports "content digest not found".
  printf "  loading into cluster nodes (parallel)...\n"
  for NODE in $(kind get nodes --name "$CLUSTER_NAME"); do
    (docker save "$IMAGE" | \
      docker exec -i "$NODE" ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -) &
  done
  wait  # cap concurrent IO: finish all nodes before pulling the next image
done

printf "  ✓ All Cilium and Istio images loaded into cluster nodes\n"

# ── Step 3: Pre-install Cilium via Helm BEFORE Flux bootstraps ────────────────
# The chicken-and-egg problem:
#   Flux pods go Pending  →  no CNI  →  Flux can't run  →  Cilium never installs
#
# Solution: install Cilium directly with Helm now, so the CNI is live before
# Flux is bootstrapped. When Flux later reconciles infrastructure/controllers/
# cilium.yaml it will adopt the existing Helm release (same chart + values) and
# manage it going forward — no duplicate install, no conflict.
#
# serviceMonitor flags are false here: the ServiceMonitor CRD (from
# kube-prometheus-stack) does not exist yet. cilium.yaml keeps them false
# permanently and uses additionalScrapeConfigs in kube-prometheus-stack instead,
# avoiding a circular dependency (ServiceMonitor CRD lives in apps layer which
# depends on this infrastructure layer).
printf "\n[3/10] Pre-installing Cilium v${CILIUM_VERSION} via Helm\n"

if ! command -v helm &> /dev/null; then
  printf "  helm not found — installing via brew\n"
  brew install helm
fi

helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

# Flags mirror cilium.yaml exactly except all serviceMonitor.enabled=false
# (CRDs not present yet) and trustCRDsExist is omitted (no ServiceMonitors
# are being created, so the validate.yaml check won't fire).
helm install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set "hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp,httpV2}" \
  --set bpf.masquerade=false \
  --set hubble.enabled=true \
  --set hubble.metrics.serviceMonitor.enabled=false \
  --set hubble.relay.enabled=true \
  --set hubble.relay.replicas=1 \
  --set hubble.ui.enabled=false \
  --set ipam.mode=kubernetes \
  --set k8sServiceHost="flux-kind-control-plane" \
  --set k8sServicePort="6443" \
  --set kubeProxyReplacement=true \
  --set operator.prometheus.enabled=true \
  --set operator.prometheus.serviceMonitor.enabled=false \
  --set operator.replicas=1 \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=false \
  --set routingMode=tunnel \
  --set socketLB.hostNamespaceOnly=true \
  --set tunnelProtocol=vxlan

printf "  Waiting for Cilium to be ready...\n"
if ! kubectl rollout status daemonset/cilium -n kube-system --timeout=300s; then
  printf "\n  ⚠ Cilium daemonset not fully ready — pod status:\n"
  kubectl get pods -n kube-system -o wide
  printf "\n  Events:\n"
  kubectl get events -n kube-system --sort-by=.lastTimestamp | tail -20
  printf "\n  Continuing anyway — pods may still be pulling images...\n"
fi
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=120s
printf "  ✓ Cilium operator ready\n"

printf "  Waiting for CoreDNS to be ready...\n"
kubectl rollout status deployment/coredns -n kube-system --timeout=120s
printf "  ✓ CoreDNS is ready — DNS resolution available\n"

# ── Step 4: Flux CLI ──────────────────────────────────────────────────────────
if ! command -v flux &> /dev/null; then
  printf "\n[4/10] Installing Flux CLI...\n"
  brew install fluxcd/tap/flux
else
  printf "\n[4/10] Flux CLI already installed\n"
fi

# ── Step 5: GitHub CLI ────────────────────────────────────────────────────────
if ! command -v gh &> /dev/null; then
  printf "[5/10] Installing GitHub CLI...\n"
  brew install gh
fi

# ── Step 6: GitHub auth ───────────────────────────────────────────────────────
printf "[6/10] Authenticating GitHub CLI...\n"
gh auth status 2>/dev/null || gh auth login

# ── Step 7: Flux bootstrap ────────────────────────────────────────────────────
# Cilium is already running so the Flux pods schedule immediately.
# When Flux reconciles infrastructure/controllers/cilium.yaml it detects
# the existing Helm release and adopts it.

# Sync the branch patch before bootstrap so Flux tracks the branch we are on.
# clusters/kind/flux-system/kustomization.yaml contains a GitRepository patch
# that overrides the branch flux bootstrap writes into gotk-sync.yaml. Without
# this sync the patch would stay at whatever branch was last committed there,
# causing Flux to watch the wrong branch. When run from main, $BRANCH is main;
# when run from a feature branch it is that branch — always correct.
PATCH_FILE="clusters/kind/flux-system/kustomization.yaml"
current_patch_branch=$(grep "branch:" "$PATCH_FILE" | awk '{print $2}')
if [[ "$current_patch_branch" != "$BRANCH" ]]; then
  printf "  Updating Flux branch patch: %s → %s\n" "$current_patch_branch" "$BRANCH"
  sed -i '' "s/branch: .*/branch: ${BRANCH}/" "$PATCH_FILE"
  git add "$PATCH_FILE"
  git commit -m "chore: point Flux GitRepository at branch ${BRANCH}"
  git push -u origin "${BRANCH}"
else
  printf "  Flux branch patch already set to '%s'\n" "$BRANCH"
fi

# Export token for --token-auth. This uses HTTPS (port 443) instead of the
# default SSH (port 22), which is blocked in many corporate and home networks.
export GITHUB_TOKEN="$(gh auth token)"

printf "[7/10] Bootstrapping Flux to GitHub repo: $GITHUB_USER/$REPO_NAME\n"
flux bootstrap github \
  --owner="$GITHUB_USER" \
  --repository="$REPO_NAME" \
  --branch="$BRANCH" \
  --path="$CLUSTER_PATH" \
  --personal \
  --token-auth

# ── Step 8: SOPS age key (optional — only runs if key file exists) ────────────
# If the user has run `make sops-setup`, the age private key lives at the
# standard path. Loading it here ensures kustomize-controller can decrypt
# SOPS-encrypted secrets on the first reconciliation, before any manual
# post-bootstrap steps are needed.
# The secret is recreated on every bootstrap (idempotent via --dry-run=client).
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
if [ -f "${AGE_KEY_FILE}" ]; then
  printf "\n[8/10] Loading SOPS age key into cluster\n"
  cat "${AGE_KEY_FILE}" | kubectl create secret generic sops-age \
    --namespace flux-system \
    --from-file=age.agekey=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
  printf "  ✓ sops-age secret created in flux-system\n"
else
  printf "\n[8/10] SOPS age key not found at %s — skipping\n" "${AGE_KEY_FILE}"
  printf "       Run 'make sops-setup' then 'make sops-load-key' to enable SOPS decryption\n"
fi

# ── Step 9: GitHub notification token ────────────────────────────────────────
# The Flux notification controller posts commit status checks back to GitHub
# for every Kustomization and HelmRelease reconciliation. It needs a token with
# repo:status scope (public repo) or repo scope (private repo).
#
# GITHUB_TOKEN was already exported above for flux bootstrap and has full repo
# scope — reuse it here so no separate PAT is needed.
#
# The secret is not committed to git (it would be visible in the public repo).
# This step recreates it on every bootstrap so a fresh cluster always has it.
printf "\n[9/10] Creating github-token secret for Flux notification provider\n"
kubectl create secret generic github-token \
  --namespace flux-system \
  --from-literal=token="${GITHUB_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
printf "  ✓ github-token secret created in flux-system\n"

# ── Step 10: Grafana secret_key ───────────────────────────────────────────────
# Without a stable secret_key, Grafana invalidates all sessions and
# re-encrypts datasource passwords on every pod restart. The key must exist
# in the observability namespace before the Grafana HelmRelease installs,
# otherwise the pod fails to start (the envValueFrom reference is unresolvable).
# Pre-creating the namespace here lets Flux adopt it on first reconciliation.
printf "\n[10/10] Creating Grafana secret_key in observability namespace\n"
kubectl create namespace observability \
  --dry-run=client -o yaml | kubectl apply -f -
GRAFANA_KEY=$(openssl rand -base64 32)
kubectl create secret generic grafana-secret-key \
  --namespace observability \
  --from-literal=secret-key="${GRAFANA_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
printf "  ✓ grafana-secret-key created in observability\n"

printf "\n✅ Setup complete.\n"
printf "   Cilium is live and Flux is now managing it via infrastructure/controllers/cilium.yaml\n"
printf "   Run 'cilium status' to verify CNI health.\n"
printf "   Run 'flux get helmreleases -A' to watch Flux adopt and reconcile all releases.\n"
