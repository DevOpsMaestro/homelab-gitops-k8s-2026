# Makefile — homelab-gitops-k8s-2026
# Wraps common cluster operations and provides an image pre-pull workflow to
# speed up repeated cluster rebuilds on macOS with Docker Desktop + KinD.
#
# Recommended first-time workflow:
#   make pull-images   # warm local Docker cache (run once per version bump)
#   make bootstrap     # full cluster build — image loads are instant when cached
#
# Subsequent rebuilds once images are cached:
#   make destroy
#   make bootstrap

.DEFAULT_GOAL := help

# Shared version pins live in versions.env (sourced by setup script too).
# Makefile-only pins (not used by scripts) remain here.
include versions.env
TETRAGON_VERSION         := v1.7.0
EVENT_GENERATOR_VERSION  := 0.13.0
KUBESCAPE_OPERATOR_VERSION := 1.40.2

# ── Host platform ─────────────────────────────────────────────────────────────
LOCAL_ARCH      := $(shell uname -m)
DOCKER_PLATFORM := $(if $(filter arm64,$(LOCAL_ARCH)),linux/arm64,linux/amd64)

# ── Bootstrap image list ──────────────────────────────────────────────────────
# These images are pre-loaded into every KinD node's containerd store during
# bootstrap via `docker save | ctr import`. Pre-pulling them to local Docker
# first (make pull-images) turns that load step from a multi-minute registry
# fetch into a ~30-second local copy.
#
# cilium-envoy is intentionally absent — its tag is embedded inside the Helm
# chart and changes every patch release. It is resolved dynamically from
# `helm template` output in the pull-images target below.
BOOTSTRAP_IMAGES := \
	quay.io/cilium/cilium:v$(CILIUM_VERSION) \
	quay.io/cilium/operator-generic:v$(CILIUM_VERSION) \
	quay.io/cilium/hubble-relay:v$(CILIUM_VERSION) \
	docker.io/istio/proxyv2:$(ISTIO_VERSION)

.PHONY: help \
        bootstrap destroy branch \
        pull-images load-images cache-running \
        check-tools status watch validate check-crd-count \
        sops-setup sops-load-key \
        test-policies test-istio test-kyverno test-falco test-cluster test-kubescape test-contour \
        test-iperf3

# ── Help ──────────────────────────────────────────────────────────────────────
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

bootstrap: ## Full cluster bootstrap — preflight → images → kind → cilium → flux
	./scripts/setup-fluxcd-gitops-kind-multinode.sh

destroy: ## Tear down all KinD clusters and optionally prune local Docker images
	./scripts/destroy.sh

branch: ## Update Flux GitRepository branch patch to match the current git branch
	./scripts/set-flux-branch.sh

# ── Image pre-pull workflow ───────────────────────────────────────────────────

pull-images: ## Pre-pull all bootstrap images to local Docker cache
	@# KinD node image — pulled by `kind create cluster` but pre-pulling avoids
	@# a ~700 MB download during bootstrap where failure is more disruptive.
	@printf '\n==> KinD node image\n'
	docker pull --platform $(DOCKER_PLATFORM) kindest/node:$(K8S_VER)

	@# Core bootstrap images — pulled in parallel (different registries, no benefit
	@# to serialising). Each image prints on completion so failures are visible.
	@printf '\n==> Cilium + Hubble + Istio images (parallel pull)\n'
	@for img in $(BOOTSTRAP_IMAGES); do \
	  (docker pull --platform $(DOCKER_PLATFORM) "$$img" --quiet > /dev/null 2>&1 \
	    && printf '    ✓ %s\n' "$$img" \
	    || printf '    ✗ FAILED: %s\n' "$$img") & \
	done; wait

	@# cilium-envoy — the tag is not a simple version string; it is constructed
	@# from a hash embedded in the chart and resolved at render time. We extract
	@# it here from `helm template` so the pin is always correct for the chart.
	@printf '\n==> cilium-envoy (resolved from Helm chart v$(CILIUM_VERSION))\n'
	@helm repo add cilium https://helm.cilium.io --force-update > /dev/null 2>&1 || true
	@ENVOY_IMG=$$(helm template cilium cilium/cilium \
	    --version "$(CILIUM_VERSION)" \
	    --namespace kube-system \
	    --set kubeProxyReplacement=true 2>/dev/null \
	  | grep 'image: quay.io/cilium/cilium-envoy' \
	  | head -1 | awk '{print $$2}' | tr -d '"'); \
	if [ -n "$$ENVOY_IMG" ]; then \
	  printf '    %-70s' "$$ENVOY_IMG"; \
	  docker pull --platform $(DOCKER_PLATFORM) "$$ENVOY_IMG" --quiet > /dev/null 2>&1 \
	    && printf ' done\n' || printf ' FAILED\n'; \
	else \
	  printf '    ⚠  image not resolved — it will pull from the registry at runtime\n'; \
	fi

	@printf '\n✓ Docker cache warmed. Run: make bootstrap\n\n'

load-images: ## Load cached images from local Docker into an existing KinD cluster
	@# Use this after destroying and recreating a cluster when images are already
	@# in local Docker cache — skips all registry traffic for the bootstrap step.
	@printf '\nLoading bootstrap images into KinD cluster "$(CLUSTER_NAME)" nodes...\n'
	@# Load each image to all nodes in parallel (one docker save pipe per node),
	@# then wait before moving to the next image to cap concurrent IO.
	@for img in $(BOOTSTRAP_IMAGES); do \
	  printf '  %s\n' "$$img"; \
	  for NODE in $$(kind get nodes --name "$(CLUSTER_NAME)"); do \
	    (docker save "$$img" | docker exec -i "$$NODE" \
	      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -) & \
	  done; \
	  wait; \
	done
	@printf '✓ Done. Images are loaded into all cluster nodes.\n\n'

cache-running: ## Pull every image currently running in the cluster to local Docker
	@# Runs after a successful cluster deployment to snapshot all Flux-managed
	@# images (Tetragon, Loki, Prometheus, Grafana, etc.) into local Docker.
	@# On the next rebuild, KinD nodes can be seeded from cache rather than
	@# pulling from upstream registries.
	./scripts/kind-pre-loader-for-images.sh

# ── Observation ───────────────────────────────────────────────────────────────

check-tools: ## Verify required CLI tools are installed
	@printf '\nChecking required tools:\n'
	@for tool in docker kind kubectl helm flux kustomize gh kyverno kubescape age sops; do \
	  if command -v "$$tool" > /dev/null 2>&1; then \
	    printf '  ✓ %s\n' "$$tool"; \
	  else \
	    printf '  ✗ %s  (not found — install via brew)\n' "$$tool"; \
	  fi; \
	done
	@printf '\n'

# ── Secrets (SOPS + Age) ─────────────────────────────────────────────────────

sops-setup: ## Generate Age key pair for SOPS (skips if key already exists)
	@KEY_FILE="$$HOME/.config/sops/age/keys.txt"; \
	if [ -f "$$KEY_FILE" ]; then \
	  printf '\n  Age key already exists at %s\n' "$$KEY_FILE"; \
	  printf '  Public key: %s\n\n' "$$(grep 'public key' "$$KEY_FILE" | awk '{print $$NF}')"; \
	else \
	  mkdir -p "$$(dirname $$KEY_FILE)"; \
	  age-keygen -o "$$KEY_FILE"; \
	  printf '\n  ✓ Key written to %s\n' "$$KEY_FILE"; \
	  printf '  Public key: %s\n' "$$(grep 'public key' "$$KEY_FILE" | awk '{print $$NF}')"; \
	  printf '\n  Next: paste the public key into .sops.yaml, then run: make sops-load-key\n\n'; \
	fi

sops-load-key: ## Load Age private key into cluster as sops-age secret (run after make bootstrap)
	@KEY_FILE="$$HOME/.config/sops/age/keys.txt"; \
	if [ ! -f "$$KEY_FILE" ]; then \
	  printf '\n  ✗ Age key not found — run: make sops-setup\n\n'; exit 1; \
	fi; \
	kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }; \
	cat "$$KEY_FILE" | kubectl create secret generic sops-age \
	  --namespace=flux-system \
	  --from-file=age.agekey=/dev/stdin \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	printf '  ✓ sops-age secret loaded into flux-system\n\n'

# ── Observation ───────────────────────────────────────────────────────────────

status: ## Show Flux reconciliation state across all namespaces
	flux get all -A

check-crd-count: ## Warn if installed CRD count approaches the etcd slow-list threshold (>150)
	@count=$$(kubectl get crds --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	printf "Installed CRDs: %s\n" "$$count"; \
	if [ "$$count" -gt 150 ]; then \
	  printf "WARNING: CRD count %s exceeds 150.\n" "$$count"; \
	  printf "High CRD counts slow etcd LIST responses and cause watch-mark-send-over-slow-network\n"; \
	  printf "warnings. Review Helm chart CRD installations; consider disabling unused capabilities.\n"; \
	  exit 1; \
	fi

watch: ## Watch Flux reconcile every 6 s (Ctrl-C to stop)
	watch -n 6 "flux get all -A"

validate: ## Validate all kustomize manifests locally (mirrors CI validate step; requires: brew install kustomize)
	@command -v kustomize >/dev/null 2>&1 \
	  || { printf '\n  ✗ kustomize not found — install: brew install kustomize\n\n'; exit 1; }
	@for dir in \
	    infrastructure/controllers \
	    apps/base/prometheus apps/base/grafana apps/base/loki apps/base/promtail \
	    apps/base/tempo apps/base/opentelemetry apps/base/kyverno apps/base/demo \
	    apps/base/notifications apps/base/istio apps/base/envoy-gateway \
	    apps/overlays/kind clusters/kind; do \
	  printf '  kustomize build %s\n' "$$dir"; \
	  kustomize build "$$dir" > /dev/null || exit 1; \
	done
	@printf '✓ All manifests valid\n'

test-policies: ## Run Kyverno CLI policy unit tests (requires: brew install kyverno)
	kyverno test apps/base/kyverno/tests/

# ── Istio service mesh tests ──────────────────────────────────────────────────

test-istio: ## Verify Istio service mesh — istiod, injection, proxy sync, mTLS, and config analysis (requires: running cluster + istioctl)
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@command -v istioctl >/dev/null 2>&1 \
	  || { printf '\n  ✗ istioctl not found — install: brew install istioctl\n\n'; exit 1; }
	@printf '\n==> Istio service mesh verification\n'
	@PASS=0; FAIL=0; \
	 \
	 printf '[1/5] istiod running... '; \
	 if kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[2/5] Injection enabled: demo and observability namespaces... '; \
	 INJECTING=$$(kubectl get namespace demo observability \
	      -o jsonpath='{range .items[*]}{.metadata.labels.istio-injection}{"\n"}{end}' 2>/dev/null \
	      | grep -c '^enabled$$'); \
	 if [ "$$INJECTING" -eq 2 ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s/2 namespaces labelled)\n' "$$INJECTING"; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[3/5] All proxies subscribed to istiod xDS... '; \
	 PROXY_COUNT=$$(istioctl proxy-status 2>/dev/null | tail -n +2 | grep -c .); \
	 SYNCED_COUNT=$$(istioctl proxy-status 2>/dev/null | tail -n +2 \
	      | grep -c '4 (CDS,LDS,EDS,RDS)' || true); \
	 if [ "$$PROXY_COUNT" -gt 0 ] && [ "$$PROXY_COUNT" -eq "$$SYNCED_COUNT" ]; then \
	   printf 'ok (%s proxy/proxies)\n' "$$PROXY_COUNT"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s/%s synced)\n' "$$SYNCED_COUNT" "$$PROXY_COUNT"; \
	   istioctl proxy-status 2>/dev/null; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[4/5] mTLS in use: X-Forwarded-Client-Cert header present... '; \
	 XFCC=$$(kubectl exec -n demo deploy/load-generator -c curl -- \
	      curl -s --max-time 5 http://httpbin.demo.svc.cluster.local/get 2>/dev/null \
	      | grep -c 'X-Forwarded-Client-Cert' || true); \
	 if [ "$$XFCC" -gt 0 ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL — header absent; Istio sidecar may not be intercepting traffic\n'; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[5/5] No errors or warnings from istioctl analyze... '; \
	 ISSUES=$$(istioctl analyze --all-namespaces 2>/dev/null \
	      | grep -cE '^(Warning|Error)' || true); \
	 if [ "$$ISSUES" -eq 0 ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s issue(s))\n' "$$ISSUES"; \
	   istioctl analyze --all-namespaces 2>/dev/null | grep -E '^(Warning|Error)'; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '\n  result: %d/5 checks passed\n' "$$PASS"; \
	 [ "$$FAIL" = "0" ] \
	   && printf '✓ Istio service mesh test passed\n\n' \
	   || { printf '✗ Some checks failed — run: istioctl analyze --all-namespaces\n\n'; exit 1; }

# ── Kyverno live-cluster tests ────────────────────────────────────────────────

test-kyverno: ## Verify Kyverno admission control — controllers, policies, and live enforcement (requires: running cluster)
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@printf '\n==> Kyverno admission control verification\n'
	@PASS=0; FAIL=0; \
	 \
	 printf '[1/4] All Kyverno controllers running... '; \
	 RUNNING=$$(kubectl get pods -n kyverno -l app.kubernetes.io/part-of=kyverno-kyverno \
	      --no-headers 2>/dev/null | grep -c Running); \
	 if [ "$$RUNNING" -ge 4 ]; then \
	   printf 'ok (%s pod(s))\n' "$$RUNNING"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s/4 running)\n' "$$RUNNING"; \
	   kubectl get pods -n kyverno --no-headers 2>/dev/null; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[2/4] All ClusterPolicies Ready... '; \
	 NOT_READY=$$(kubectl get clusterpolicies --no-headers 2>/dev/null | grep -vc 'Ready'); \
	 TOTAL_POL=$$(kubectl get clusterpolicies --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	 if [ "$$TOTAL_POL" -gt 0 ] && [ "$$NOT_READY" = "0" ]; then \
	   printf 'ok (%s policies)\n' "$$TOTAL_POL"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s not Ready)\n' "$$NOT_READY"; \
	   kubectl get clusterpolicies --no-headers 2>/dev/null | grep -v 'Ready'; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[3/4] Enforce: pod without resource limits is blocked (dry-run)... '; \
	 if printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: kyverno-test\n  namespace: default\nspec:\n  containers:\n  - name: t\n    image: busybox:1.36.1\n    securityContext:\n      allowPrivilegeEscalation: false\n' \
	      | kubectl apply --dry-run=server -f - 2>&1 | grep -q 'denied the request'; then \
	   printf 'ok — admission blocked\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL — require-resource-limits policy did not block\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[4/4] Enforce: allowPrivilegeEscalation: true is blocked (dry-run)... '; \
	 if printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: kyverno-test\n  namespace: default\nspec:\n  containers:\n  - name: t\n    image: busybox:1.36.1\n    securityContext:\n      allowPrivilegeEscalation: true\n    resources:\n      requests:\n        cpu: 100m\n        memory: 64Mi\n      limits:\n        cpu: 100m\n        memory: 64Mi\n' \
	      | kubectl apply --dry-run=server -f - 2>&1 | grep -q 'denied the request'; then \
	   printf 'ok — admission blocked\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL — disallow-privilege-escalation policy did not block\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '\n  result: %d/4 checks passed\n' "$$PASS"; \
	 [ "$$FAIL" = "0" ] \
	   && printf '✓ Kyverno admission control test passed\n\n' \
	   || { printf '✗ Some checks failed — run: kubectl get clusterpolicies\n\n'; exit 1; }

# ── Falco live-cluster tests ──────────────────────────────────────────────────

test-falco: ## Validate Falco detects runtime threats via event-generator (requires: running cluster)
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@kubectl get pods -n falco -l app.kubernetes.io/name=falco --no-headers 2>/dev/null \
	  | grep -q Running \
	  || { printf '\n  ✗ Falco is not running — check: kubectl get pods -n falco\n\n'; exit 1; }
	@printf '\n==> Deploying Falco event-generator (v$(EVENT_GENERATOR_VERSION))...\n'
	@START_TS=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	 kubectl apply -f tests/falco/ >/dev/null; \
	 printf '==> Waiting for events to be fired (up to 90 s)...\n'; \
	 kubectl wait --for=condition=complete --timeout=90s \
	     job/falco-event-generator -n falco-test 2>/dev/null \
	   || { printf '\n  ✗ Job did not complete in time\n'; \
	        printf '     kubectl logs -n falco-test job/falco-event-generator\n\n'; \
	        kubectl delete namespace falco-test --ignore-not-found >/dev/null 2>&1; \
	        exit 1; }; \
	 printf '\n==> Checking Falco detections on the event node...\n'; \
	 NODE=$$(kubectl get pod -n falco-test -l job-name=falco-event-generator \
	         -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null); \
	 FALCO_POD=$$(kubectl get pod -n falco -l app.kubernetes.io/name=falco \
	              --field-selector="spec.nodeName=$$NODE" -o name 2>/dev/null | head -1); \
	 LOGS=$$(kubectl logs "$$FALCO_POD" -n falco --since-time="$$START_TS" 2>/dev/null); \
	 PASS=0; FAIL=0; \
	 for RULE in \
	     "Read sensitive file untrusted" \
	     "Run shell untrusted" \
	     "Find AWS Credentials" \
	     "Search Private Keys or Passwords"; do \
	   if printf '%s' "$$LOGS" | grep -q "$$RULE"; then \
	     printf '  ✓ %s\n' "$$RULE"; PASS=$$((PASS+1)); \
	   else \
	     printf '  ✗ %s  (not detected)\n' "$$RULE"; FAIL=$$((FAIL+1)); \
	   fi; \
	 done; \
	 printf '\n  result: %d/%d rules detected\n' "$$PASS" "$$((PASS+FAIL))"; \
	 kubectl delete namespace falco-test --ignore-not-found >/dev/null 2>&1; \
	 [ "$$FAIL" = "0" ] \
	   && printf '✓ Falco detection test passed\n\n' \
	   || { printf '✗ Missing detections — Falco logs: kubectl logs -n falco %s\n\n' "$$FALCO_POD"; exit 1; }

# ── Kubescape security scan ───────────────────────────────────────────────────

test-kubescape: ## Run Kubescape NSA+MITRE posture scan against the live cluster
	@command -v kubescape >/dev/null 2>&1 \
	  || { printf '\n  ✗ kubescape not found — install: brew install kubescape\n\n'; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@printf '\n==> Kubescape security posture scan (NSA + MITRE)\n'
	@kubescape scan framework nsa,mitre \
	  --cluster-context "kind-$(CLUSTER_NAME)" \
	  --format pretty-printer \
	  --verbose

# ── Cluster smoke test ────────────────────────────────────────────────────────

test-cluster: ## Smoke-test a running cluster — Flux, Grafana, Prometheus, Loki, Kyverno
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@kubectl get pods -n flux-system -l app=source-controller --no-headers 2>/dev/null \
	  | grep -q Running \
	  || { printf '\n  ✗ Flux is not running — check: kubectl get pods -n flux-system\n\n'; exit 1; }
	@printf '\n==> Cluster smoke test\n'
	@PASS=0; FAIL=0; \
	 \
	 printf '[1/5] Flux HelmReleases all reconciled... '; \
	 NOTREADY=$$(flux get helmreleases -A --no-header 2>/dev/null | grep -v 'True' | wc -l | tr -d ' '); \
	 if [ "$$NOTREADY" = "0" ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s release(s) not ready)\n' "$$NOTREADY"; \
	   flux get helmreleases -A --no-header 2>/dev/null | grep -v 'True'; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[2/5] Grafana API health... '; \
	 kubectl port-forward -n observability svc/observability-grafana 19080:80 >/dev/null 2>&1 & PF_PID=$$!; \
	 TRIES=0; until nc -z localhost 19080 2>/dev/null || [ $$TRIES -ge 10 ]; do sleep 1; TRIES=$$((TRIES+1)); done; \
	 if curl -sf --max-time 5 http://localhost:19080/api/health 2>/dev/null | grep -q '"database":"ok"'; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 kill $$PF_PID 2>/dev/null; wait $$PF_PID 2>/dev/null; \
	 \
	 printf '[3/5] Prometheus active targets... '; \
	 kubectl port-forward -n observability svc/observability-kube-prometh-prometheus 19090:9090 >/dev/null 2>&1 & PF_PID=$$!; \
	 TRIES=0; until nc -z localhost 19090 2>/dev/null || [ $$TRIES -ge 10 ]; do sleep 1; TRIES=$$((TRIES+1)); done; \
	 TARGET_COUNT=$$(curl -sf --max-time 5 'http://localhost:19090/api/v1/targets?state=active' 2>/dev/null \
	   | grep -o '"health"' | wc -l | tr -d ' '); \
	 kill $$PF_PID 2>/dev/null; wait $$PF_PID 2>/dev/null; \
	 if [ "$$TARGET_COUNT" -gt 0 ]; then \
	   printf 'ok (%s active targets)\n' "$$TARGET_COUNT"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (no active targets)\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[4/5] Loki ready endpoint... '; \
	 kubectl port-forward -n observability svc/observability-loki 19100:3100 >/dev/null 2>&1 & PF_PID=$$!; \
	 TRIES=0; until nc -z localhost 19100 2>/dev/null || [ $$TRIES -ge 10 ]; do sleep 1; TRIES=$$((TRIES+1)); done; \
	 if curl -sf --max-time 5 http://localhost:19100/ready 2>/dev/null | grep -q 'ready'; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 kill $$PF_PID 2>/dev/null; wait $$PF_PID 2>/dev/null; \
	 \
	 printf '[5/5] Kyverno admission controller running... '; \
	 if kubectl get pods -n kyverno -l app.kubernetes.io/component=admission-controller \
	      --no-headers 2>/dev/null | grep -q Running; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '\n  result: %d/5 checks passed\n' "$$PASS"; \
	 [ "$$FAIL" = "0" ] \
	   && printf '✓ Cluster smoke test passed\n\n' \
	   || { printf '✗ Some checks failed — run: kubectl get pods -A\n\n'; exit 1; }

# ── Contour ingress tests ─────────────────────────────────────────────────────

test-contour: ## Verify Contour ingress — pods, HTTPProxy CRs, and all three HTTP routes
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@printf '\n==> Contour ingress verification\n'
	@PASS=0; FAIL=0; \
	 \
	 printf '[1/6] Contour controller running... '; \
	 if kubectl get pods -n contour -l app.kubernetes.io/component=contour \
	      --no-headers 2>/dev/null | grep -q Running; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[2/6] Contour Envoy DaemonSet running... '; \
	 ENVOY_READY=$$(kubectl get pods -n contour -l app.kubernetes.io/component=envoy \
	      --no-headers 2>/dev/null | grep -c Running); \
	 if [ "$$ENVOY_READY" -gt 0 ]; then \
	   printf 'ok (%s pod(s))\n' "$$ENVOY_READY"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL\n'; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[3/6] All HTTPProxy CRs valid... '; \
	 INVALID=$$(kubectl get httpproxy -A --no-headers 2>/dev/null | grep -vc ' valid '); \
	 TOTAL=$$(kubectl get httpproxy -A --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	 if [ "$$TOTAL" -gt 0 ] && [ "$$INVALID" = "0" ]; then \
	   printf 'ok (%s proxy/proxies)\n' "$$TOTAL"; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (%s invalid or missing)\n' "$$INVALID"; \
	   kubectl get httpproxy -A --no-headers 2>/dev/null | grep -v ' valid '; \
	   FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[4/6] Route httpbin-contour.local → HTTP 200... '; \
	 CODE=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
	           -H 'Host: httpbin-contour.local' http://localhost:8080/get); \
	 if [ "$$CODE" = "200" ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (got %s)\n' "$$CODE"; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[5/6] Route grafana.local → HTTP 302... '; \
	 CODE=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
	           -H 'Host: grafana.local' http://localhost:8080/); \
	 if [ "$$CODE" = "302" ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (got %s)\n' "$$CODE"; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '[6/6] Route prometheus.local → HTTP 302... '; \
	 CODE=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
	           -H 'Host: prometheus.local' http://localhost:8080/); \
	 if [ "$$CODE" = "302" ]; then \
	   printf 'ok\n'; PASS=$$((PASS+1)); \
	 else \
	   printf 'FAIL (got %s)\n' "$$CODE"; FAIL=$$((FAIL+1)); \
	 fi; \
	 \
	 printf '\n  result: %d/6 checks passed\n' "$$PASS"; \
	 [ "$$FAIL" = "0" ] \
	   && printf '✓ Contour ingress test passed\n\n' \
	   || { printf '✗ Some checks failed — run: kubectl get httpproxy -A\n\n'; exit 1; }

# ── iperf3 load tests ─────────────────────────────────────────────────────────

test-iperf3: ## Baseline bandwidth test — single stream, 30 s, through nginx stream proxy
	@kubectl cluster-info >/dev/null 2>&1 \
	  || { printf '\n  ✗ No cluster — run: make bootstrap\n\n'; exit 1; }
	@kubectl get pods -n iperf3 -l app=iperf3-server --no-headers 2>/dev/null \
	  | grep -q Running \
	  || { printf '\n  ✗ iperf3 server not running — check: kubectl get pods -n iperf3\n\n'; exit 1; }
	@command -v iperf3 >/dev/null 2>&1 \
	  || { printf '\n  ✗ iperf3 not found — install: brew install iperf3\n\n'; exit 1; }
	@printf '\n==> iperf3 baseline bandwidth test (single stream, 30 s)\n'
	@printf '    Path: localhost:32111 → nginx stream{} → iperf3 Service :32111 → iperf3 pod\n\n'
	@iperf3 -4 -c localhost -p 32111 -t 30
	@printf '\n✓ Baseline test complete\n\n'

# ── iperf3 feature flag ───────────────────────────────────────────────────────

iperf3-enable: ## Enable iperf3 — uncomments its entry in apps/overlays/kind/kustomization.yaml
	@sed -i '' 's|^  # - ../../base/iperf3.*|  - ../../base/iperf3|' \
	  apps/overlays/kind/kustomization.yaml
	@grep -q '^  - ../../base/iperf3$$' apps/overlays/kind/kustomization.yaml \
	  && printf '\n✓ iperf3 enabled in apps/overlays/kind/kustomization.yaml\n  Commit and push to deploy via Flux.\n\n' \
	  || { printf '\n✗ Pattern not matched — inspect apps/overlays/kind/kustomization.yaml\n\n'; exit 1; }

iperf3-disable: ## Disable iperf3 — comments out its entry in apps/overlays/kind/kustomization.yaml
	@sed -i '' 's|^  - ../../base/iperf3$$|  # - ../../base/iperf3        # iperf3 feature flag — run: make iperf3-enable to restore|' \
	  apps/overlays/kind/kustomization.yaml
	@grep -q '^  # - ../../base/iperf3' apps/overlays/kind/kustomization.yaml \
	  && printf '\n✓ iperf3 disabled in apps/overlays/kind/kustomization.yaml\n  Commit and push to remove via Flux (prune: true will delete the namespace).\n\n' \
	  || { printf '\n✗ Pattern not matched — inspect apps/overlays/kind/kustomization.yaml\n\n'; exit 1; }
