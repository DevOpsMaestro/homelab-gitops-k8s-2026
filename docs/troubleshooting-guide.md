# Troubleshooting Guide

Cluster: `flux-kind` · KinD 1.36.1 · 1 control-plane + 2 workers
Stack: Flux CD · Cilium 1.19 · Hubble · cert-manager 1.20 · OpenEBS 4.x · Istio 1.30 (mesh only) · Contour 1.33 · Metrics Server 3.x · Tetragon 1.7 · Kyverno 3 · Kubescape 1.40 · Falco 9 · Trivy Operator 0.x · kube-prometheus-stack 87 · Grafana 10 (app 12) · Grafana Tempo 1 · OpenTelemetry Collector 0 · BOINC · SOPS + Age · iperf3

---

## Table of Contents

0. [Flux Reconciliation Quick Reference](#0-flux-reconciliation-quick-reference)
1. [Quick Cluster Health Check](#1-quick-cluster-health-check)
2. [Accessing Service UIs](#2-accessing-service-uis)
3. [Flux CD](#3-flux-cd)
4. [Cilium](#4-cilium)
5. [Hubble](#5-hubble)
6. [cert-manager](#6-cert-manager)
7. [OpenEBS](#7-openebs)
8. [Istio](#8-istio)
9. [HTTP Ingress — Contour](#9-http-ingress--contour)
10. [Loki and Promtail](#10-loki-and-promtail)
11. [Tetragon](#11-tetragon)
12. [Kyverno](#12-kyverno)
13. [Falco](#13-falco)
14. [Prometheus](#14-prometheus)
15. [Grafana](#15-grafana)
16. [Flux GitHub Notifications](#16-flux-github-notifications)
17. [Grafana Tempo](#17-grafana-tempo)
18. [OpenTelemetry Collector](#18-opentelemetry-collector)
19. [Kubescape](#19-kubescape)
20. [SOPS + Age](#20-sops--age)
21. [Common Issues](#21-common-issues)
22. [BOINC](#22-boinc)
23. [Renovate](#23-renovate)
24. [Metrics Server](#24-metrics-server)
25. [Trivy Operator](#25-trivy-operator)
26. [iperf3](#26-iperf3)
27. [Contour](#27-contour)

---

## 0. Flux Reconciliation Quick Reference

```bash
# Re-fetch latest git source immediately (run this first after a push)
flux reconcile source git flux-system -n flux-system

# Re-fetch source + re-apply all kustomizations in one shot
flux reconcile source git flux-system -n flux-system && \
  flux reconcile kustomization flux-system --with-source -n flux-system

# Force reconcile a single HelmRelease
flux reconcile helmrelease <name> -n flux-system

# Force reconcile all HelmReleases in flux-system
flux get helmreleases -n flux-system --no-header | \
  awk '{print $1}' | \
  xargs -I {} flux reconcile helmrelease {} -n flux-system
```

---

## 1. Quick Cluster Health Check

Start with these commands. Proceed to per-technology sections only if a specific component requires investigation.

```bash
# All pods across all namespaces — look for anything not Running/Completed
kubectl get pods -A

# All Flux resources — every source, helmrelease, kustomization
flux get all -A

# Node status and kernel version
kubectl get nodes -o wide
```

Expected: all pods `Running` or `Completed`, all Flux resources `READY: True`, all nodes `Ready`.

---

## 2. Accessing Service UIs

Grafana, Prometheus, and httpbin-contour are exposed via Contour `HTTPProxy` resources through the Contour Envoy DaemonSet. All other services use `kubectl port-forward`.

Traffic path: `localhost:8080 → KinD extraPortMapping (containerPort 8888) → nginx nodeport-proxy (hostNetwork, port 8888) → contour-contour-envoy.contour.svc:80 → Contour Envoy DaemonSet → HTTPProxy → backend service`

### Prerequisite — /etc/hosts (One-Time)

```bash
echo "127.0.0.1 grafana.local prometheus.local httpbin-contour.local" | sudo tee -a /etc/hosts
```

### Quick Reference

| UI | Access Method | Local URL | Credentials |
|---|---|---|---|
| Grafana | Contour HTTPProxy | `http://grafana.local:8080` | admin / changeme |
| Prometheus | Contour HTTPProxy | `http://prometheus.local:8080` | none |
| Alertmanager | kubectl port-forward | `http://localhost:9093` | none |
| Hubble UI | kubectl port-forward | `http://localhost:12000` | none |

### Grafana

No port-forward required:

```text
http://grafana.local:8080
Username: admin
Password: changeme  (set in apps/base/grafana/helmrelease.yaml)
```

Pre-provisioned dashboards are available under **Dashboards** after login:

| Dashboard | Source |
|---|---|
| Node Exporter Full (home dashboard) | gnetId 1860 |
| Cilium Agent | gnetId 16611 |
| Cilium Operator | gnetId 16612 |
| Hubble | gnetId 16613 |
| Istio Control Plane | gnetId 7639 |
| Istio Mesh | gnetId 7636 |
| Istio Service | gnetId 7630 |
| Istio Workload | gnetId 7645 |
| cert-manager | gnetId 20842 |
| Kyverno | ConfigMap (gnetId 15804, patched) |
| Flux Cluster Stats | ConfigMap (flux2-monitoring-example) |
| Flux Control Plane | ConfigMap (flux2-monitoring-example) |
| Tetragon kubectl exec audit | ConfigMap (gnetId 20189, patched) — Loki datasource |
| Falco — Runtime Security | ConfigMap (Prometheus + Loki datasources) |
| Kubescape Security Posture | ConfigMap (Prometheus datasource) |
| OpenTelemetry Collector | ConfigMap (gnetId 15983, patched) |

### Prometheus

No port-forward required:

```text
http://prometheus.local:8080
Useful pages: Status > Targets (scrape health), Graph (ad-hoc queries)
```

### Alertmanager

```bash
kubectl port-forward -n observability svc/observability-kube-prometheus-alertmanager 9093:9093
# Open: http://localhost:9093
```

### Hubble UI

```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open: http://localhost:12000
# Shows live service map and per-namespace flow visualisation
```

The Cilium CLI also handles the port-forward automatically:

```bash
cilium hubble ui
```

### Contour and HTTPProxy Health

```bash
# Contour controller and Envoy DaemonSet pods
kubectl get pods -n contour

# All HTTPProxy CRs — STATUS should be valid
kubectl get httpproxy -A

# Detailed HTTPProxy status
kubectl describe httpproxy grafana -n observability
kubectl describe httpproxy prometheus -n observability
kubectl describe httpproxy httpbin -n demo

# Contour Envoy Service — should have ClusterIP in the contour namespace
kubectl get svc contour-contour-envoy -n contour
```

---

## 3. Flux CD

### Flux Status

```bash
# Overall reconciliation state
flux get all -A

# Sources only (GitRepository, HelmRepository, HelmChart)
flux get sources all -A

# Kustomizations
flux get kustomizations -A

# HelmReleases
flux get helmreleases -A
```

### Flux Logs

```bash
# All controllers at once
flux logs

# Filter to a specific controller kind
flux logs --kind=HelmRelease
flux logs --kind=Kustomization
flux logs --kind=GitRepository
```

### Force Reconciliation

```bash
# Force Flux to re-pull git and reconcile everything
flux reconcile source git flux-system -n flux-system

# Force a specific kustomization
flux reconcile kustomization infrastructure-controllers -n flux-system
flux reconcile kustomization apps -n flux-system

# Force a specific HelmRelease (add --with-source to also re-pull the chart)
flux reconcile helmrelease cilium -n flux-system --with-source

# Suspend all helmrelease
kubectl get helmrelease -A --no-headers | awk '{print $1, $2}' | xargs -n2 sh -c 'flux suspend helmrelease "$2" -n "$1"' _

# Resume all helmrelease
kubectl get helmrelease -A --no-headers | awk '{print $1, $2}' | xargs -n2 sh -c 'flux resume helmrelease "$2" -n "$1"' _
```

### Inspect a Failing HelmRelease

```bash
kubectl describe helmrelease <name> -n flux-system | grep -A 30 "Status:"
```

---

## 4. Cilium

### Cilium Status

```bash
# High-level CNI health
cilium status --wait

# Per-node agent detail
kubectl exec -n kube-system ds/cilium -- cilium-dbg status

# All Cilium pods — every node should have a Running cilium agent and cilium-envoy
kubectl get pods -n kube-system -l app.kubernetes.io/part-of=cilium -o wide
```

### Connectivity Test

```bash
# Full mesh connectivity test — deploys test pods, runs ~132 checks, cleans up
cilium connectivity test

# Demote Hubble flow-validation mismatches to warnings (recommended for KinD)
# Real connectivity failures (drops, policy violations) still surface as failures.
cilium connectivity test --flow-validation warning
```

### Connectivity Test — Namespace Already Exists

**Symptom:** The test exits after four lines with no failures listed. The log contains:

```
unable to create service account echo-same-node: serviceaccounts "echo-same-node" already exists
```

**Cause:** A previous run left the `cilium-test-1` namespace behind (either it was interrupted or the cluster was not fully cleaned between runs).

**Fix:**

```bash
kubectl delete namespace cilium-test-1 --ignore-not-found=true
# Then re-run the test.
```

### Connectivity Test — Known Failures in KinD (Structural)

The following tests consistently fail in this cluster configuration regardless of Cilium settings. They are not connectivity failures — the actual traffic succeeds. The failures are in Hubble's flow-observation layer only.

**`no-policies/pod-to-service`, `allow-all-except-world/pod-to-service`, `pod-to-itself-via-service`**

Failure pattern: `Flow validation failed ... (first: -1, last: -1, matched: 0)`.

Root cause: Cilium's eBPF kube-proxy replacement performs Service→Pod DNAT inside the `to-network` TC BPF hook. All Hubble observation points are downstream of that hook. Hubble records flows with the backend pod IP as destination; the connectivity test queries for the pre-DNAT Service ClusterIP. No configuration setting changes where in the kernel datapath the DNAT occurs.

**Workaround** — demote to warnings rather than failures:

```bash
cilium connectivity test --flow-validation warning
```

**`check-log-errors`**

**Cause:** After any Helm upgrade that changes `hubble.metrics.enabled` in the HelmRelease, the `cilium-config` ConfigMap is updated immediately, but the running cilium-agent pods loaded the previous value at their last startup. Cilium's config-drift-checker detects the mismatch and logs a warning, which `check-log-errors` flags.

**Fix:** Restart the DaemonSet so all agents load the current ConfigMap:

```bash
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout status daemonset/cilium -n kube-system
```

Verify the running agents now carry the correct value:

```bash
kubectl get configmap cilium-config -n kube-system \
  -o jsonpath='{.data.hubble-metrics}' && echo
# Expected output contains: httpV2:exemplars=true;labelsContext=...
```

### Connectivity Test — Monitor Aggregation and the Ring Buffer

**Do not set `bpf.monitorAggregation: none`** in the Cilium HelmRelease for connectivity testing. The reasoning is counterintuitive:

- At the default `medium` aggregation level, each TCP connection generates two events (SYN and FIN). With the 4 096-entry Hubble ring buffer, events from earlier test actions remain in the buffer long enough for the test framework to query them.
- At `none`, every TCP packet generates an event. The ring buffer fills between action execution and the test framework's Hubble query, evicting earlier events before they can be observed. This causes tests that previously passed to fail with `(first: -1, last: -1, matched: 0)` — the same pattern as the pod-to-service failures, but now for simple pod-to-pod flows as well.

In a test run where `monitorAggregation: none` was set, the failure count rose from 5 (structural KinD limits) to 25. Leaving the aggregation at the chart default (`medium`) is the correct choice for this cluster.

### kube-proxy Replacement

```bash
# Confirm Cilium is handling kube-proxy duties
kubectl exec -n kube-system ds/cilium -- cilium-dbg status | grep -i "kube-proxy"
# Expected: KubeProxyReplacement: True
```

### Network Policy

```bash
# List all CiliumNetworkPolicies in the cluster
kubectl get ciliumnetworkpolicies -A
kubectl get ciliumclusterwidenetworkpolicies
```

### Cilium Logs

```bash
# Agent logs for a specific node
kubectl logs -n kube-system -l k8s-app=cilium --prefix | tail -50

# Operator logs
kubectl logs -n kube-system deploy/cilium-operator | tail -50
```

---

## 5. Hubble

### Hubble Status

```bash
# Relay and UI pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-relay
kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-ui

# Hubble relay health via CLI
hubble status
# If the above fails, port-forward first:
kubectl port-forward -n kube-system svc/hubble-relay 4245:80 &
hubble status --server localhost:4245
```

### Observe Live Traffic

```bash
# Port-forward if hubble CLI is not already connected
kubectl port-forward -n kube-system svc/hubble-relay 4245:80 &

# Watch all flows cluster-wide
hubble observe --server localhost:4245

# Filter to a namespace
hubble observe --server localhost:4245 --namespace istio-test

# Show only dropped packets
hubble observe --server localhost:4245 --verdict DROPPED
```

### Hubble UI Port-Forward

```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open: http://localhost:12000
```

---

## 6. cert-manager

### cert-manager Status

```bash
# All cert-manager pods (controller, cainjector, webhook)
kubectl get pods -n cert-manager

# API readiness check
cmctl check api
# Install cmctl if needed: brew install cmctl
```

### End-to-End Certificate Issuance Test

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-test
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cm-test-cert
  namespace: default
spec:
  secretName: cm-test-cert-tls
  issuerRef:
    name: selfsigned-test
    kind: ClusterIssuer
  dnsNames:
    - example.local
EOF

# Wait for issuance — Ready=True confirms the full controller/webhook/cainjector path worked
kubectl wait --for=condition=Ready certificate/cm-test-cert -n default --timeout=60s
kubectl get certificate cm-test-cert -n default
kubectl get secret cm-test-cert-tls -n default   # must contain tls.crt and tls.key

# Clean up
kubectl delete certificate cm-test-cert -n default
kubectl delete secret cm-test-cert-tls -n default
kubectl delete clusterissuer selfsigned-test
```

### Inspect a Failing Certificate

```bash
kubectl describe certificate <name> -n <namespace>
kubectl describe certificaterequest -n <namespace>
kubectl describe order -n <namespace>           # ACME only
kubectl describe challenge -n <namespace>       # ACME only
```

### cert-manager Logs

```bash
kubectl logs -n cert-manager deploy/cert-manager-cert-manager | tail -50
kubectl logs -n cert-manager deploy/cert-manager-cert-manager-cainjector | tail -50
kubectl logs -n cert-manager deploy/cert-manager-cert-manager-webhook | tail -50
```

---

## 7. OpenEBS

### OpenEBS Status

```bash
# Provisioner pod
kubectl get pods -n openebs

# StorageClass — openebs-hostpath should be the default (marked with "(default)")
kubectl get storageclass
```

### End-to-End Storage Test

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openebs-test-pvc
  namespace: default
spec:
  storageClassName: openebs-hostpath
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: openebs-test-pod
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox
      command: [sh, -c, "echo 'OpenEBS works!' > /data/test.txt && cat /data/test.txt"]
      volumeMounts:
        - mountPath: /data
          name: storage
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: openebs-test-pvc
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/openebs-test-pvc -n default --timeout=60s
kubectl wait --for=condition=Ready pod/openebs-test-pod -n default --timeout=60s
kubectl logs openebs-test-pod -n default   # expected: "OpenEBS works!"

# Clean up
kubectl delete pod openebs-test-pod -n default
kubectl delete pvc openebs-test-pvc -n default
```

### OpenEBS Logs

```bash
kubectl logs -n openebs deploy/openebs-openebs-localpv-provisioner | tail -50
```

---

## 8. Istio

### Istio Status

```bash
# Mesh-wide config analysis — reports misconfigurations, missing labels, port naming issues
istioctl analyze --all-namespaces
# What it catches:
# Mismatched mTLS policies, broken VirtualService destinations,
# missing sidecar injection webhooks, or gateways referencing non-existent secrets.

# Confirm istiod is synced with all Envoy proxies (sidecars + auto-provisioned gateway)
istioctl proxy-status

# Check Sidecar and Mesh Readiness (experimental precheck)
istioctl experimental precheck
```

### Ingress Connectivity Test (Contour)

```bash
# Quick end-to-end check without /etc/hosts (use Host header)
curl -s -o /dev/null -w "%{http_code}" -H "Host: grafana.local" http://localhost:8080/
# Expected: 302 (Grafana login redirect)

curl -s -o /dev/null -w "%{http_code}" -H "Host: prometheus.local" http://localhost:8080/
# Expected: 200 (Prometheus UI)

curl -s -o /dev/null -w "%{http_code}" -H "Host: httpbin-contour.local" http://localhost:8080/get
# Expected: 200
```

### mTLS Functional Test

```bash
# Create a namespace with sidecar injection enabled
kubectl create namespace istio-test
kubectl label namespace istio-test istio-injection=enabled

# Deploy client (sleep) and server (httpbin)
kubectl apply -n istio-test -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/sleep/sleep.yaml
kubectl apply -n istio-test -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/httpbin/httpbin.yaml

# Wait for 2/2 — the /2 confirms the Envoy sidecar was injected
kubectl wait --for=condition=ready pod -l app=sleep -n istio-test --timeout=90s
kubectl wait --for=condition=ready pod -l app=httpbin -n istio-test --timeout=90s
kubectl get pods -n istio-test

# Send a request through the mesh
kubectl exec -n istio-test deploy/sleep -- curl -s http://httpbin.istio-test:8000/get | head -20

# Confirm mTLS: the x-forwarded-client-cert header is added by Envoy only on mutual TLS connections
kubectl exec -n istio-test deploy/sleep -- \
  curl -s http://httpbin.istio-test:8000/headers | grep -i "x-forwarded-client-cert"

# Inspect the TLS mode Envoy is using for the httpbin upstream
istioctl proxy-config cluster -n istio-test deploy/sleep | grep httpbin

# Clean up
kubectl delete namespace istio-test
```

### Sidecar Proxy Debugging

```bash
# Inspect all listeners on a pod's Envoy proxy
istioctl proxy-config listener <pod-name> -n <namespace>

# Inspect routes
istioctl proxy-config route <pod-name> -n <namespace>

# Inspect TLS config for an upstream cluster
istioctl proxy-config cluster <pod-name> -n <namespace> --fqdn <service>.<namespace>.svc.cluster.local

# Full Envoy config dump
istioctl proxy-config all <pod-name> -n <namespace>
```

### Grafana Dashboards Blank After Mac Wakes from Sleep — mTLS Certificate Expiry

**Symptom:** All Grafana dashboards show:
```
upstream connect error or disconnect/reset before headers. retried and the latest reset reason:
remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:
OPENSSL_internal:CERTIFICATE_VERIFY_FAILED
```

**Cause:** Docker Desktop pauses the Linux VM when the Mac sleeps. Istio issues 24-hour workload certificates to each Envoy sidecar and rotates them at the 80% mark (~19 h). If the VM is frozen through that rotation window, the rotation goroutine does not execute. Once the certificate expires, Istio does not auto-renew it — the sidecar continues presenting an expired certificate until the pod is restarted.

**Verify:**

```bash
# VALID CERT: false confirms the cert has expired
istioctl proxy-config secret -n observability deploy/observability-grafana | grep default
```

**Fix — restart all sidecar-injected pods (takes ~60 s):**

```bash
kubectl rollout restart deployment statefulset -n observability
kubectl rollout restart deployment -n demo
```

**Confirm certificates are fresh:**

```bash
istioctl proxy-config secret -n observability deploy/observability-grafana | grep default
# VALID CERT should now be: true
```

### Istio Logs

```bash
kubectl logs -n istio-system deploy/istiod | tail -50
```

Or filtered:

```bash
kubectl logs -n istio-system deploy/istiod | \
  egrep -i '(error|debug|trace)' | \
  grep -v "retry count: [1-4]" | \
  grep -v "webhook is not ready"
```

---

## 9. HTTP Ingress — Contour

Contour is the sole HTTP ingress controller. It watches `HTTPProxy` CRs, compiles them into Envoy xDS configuration, and streams that configuration to its Envoy DaemonSet over gRPC on port 8001. The nginx `nodeport-proxy` in `envoy-ingress` receives all external HTTP traffic on port 8888 and forwards it to the Contour Envoy DaemonSet (`contour-contour-envoy.contour.svc.cluster.local:80`). Contour then routes by the `Host` header.

### Status

```bash
# Flux HelmRelease
flux get helmrelease contour -n flux-system
# Expected: READY True, chart 0.x (app version v1.33.x)

# Controller and Envoy DaemonSet pods
kubectl get pods -n contour
# Expected: contour-contour-* Running (controller), contour-contour-envoy-* Running (data plane, one per node)

# All HTTPProxy CRs — STATUS should be valid
kubectl get httpproxy -A
```

### End-to-End Connectivity Test

```bash
# All three routes through Contour
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: grafana.local" http://localhost:8080/
# Expected: 302

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: prometheus.local" http://localhost:8080/
# Expected: 200

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: httpbin-contour.local" http://localhost:8080/get
# Expected: 200
```

### HTTPProxy Conditions

```bash
kubectl describe httpproxy grafana -n observability
kubectl describe httpproxy prometheus -n observability
kubectl describe httpproxy httpbin -n demo
```

A healthy HTTPProxy shows `Status: valid`. An `orphaned` or `invalid` status means the virtual host FQDN conflicts with another HTTPProxy or a required field is missing.

### Contour Logs

```bash
# Controller logs — xDS pushes, HTTPProxy reconciliation
kubectl logs -n contour -l app.kubernetes.io/name=contour,app.kubernetes.io/component=contour | tail -50

# Envoy data-plane logs — access logs and errors
kubectl logs -n contour -l app.kubernetes.io/component=envoy | tail -50
```

### Adding a New Service via HTTPProxy

Create an `HTTPProxy` CR in the service's namespace:

```yaml
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: my-app
  namespace: my-namespace
spec:
  virtualhost:
    fqdn: my-app.local
  routes:
    - conditions:
        - prefix: /
      services:
        - name: my-service
          port: 8080
```

Then add `127.0.0.1 my-app.local` to `/etc/hosts`. The nginx catch-all `default_server` block already forwards all hostnames to Contour — no nginx ConfigMap change is required for new routes.

---

## 10. Loki and Promtail

### Status

```bash
# Loki StatefulSet — should be 1/1 Running
kubectl get pods -n observability -l app.kubernetes.io/name=loki

# Promtail DaemonSet — one pod per node (including control-plane)
kubectl get pods -n observability -l app.kubernetes.io/name=promtail -o wide

# Loki PVC — should be Bound
kubectl get pvc -n observability -l app.kubernetes.io/name=loki
```

### Verify Loki Is Ingesting Logs

```bash
# Port-forward Loki directly
kubectl port-forward -n observability svc/observability-loki 3100:3100 &

# Query the last 5 minutes of Tetragon security events
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="tetragon", container="export-stdout"}' \
  --data-urlencode 'start=-5m' | jq '.data.result[].values | length'

# List all log streams Loki knows about
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq .
```

### Promtail Log Shipping

```bash
# Check Promtail targets — each entry should show "ready"
kubectl port-forward -n observability \
  $(kubectl get pod -n observability -l app.kubernetes.io/name=promtail -o jsonpath='{.items[0].metadata.name}') \
  3101:3101 &
curl -s http://localhost:3101/targets | python3 -m json.tool | grep -c '"health":"up"'
```

### Query Tetragon Events in Grafana

Open `http://grafana.local:8080`, go to **Explore**, select the **Loki** datasource, then run:

```logql
{namespace="tetragon", container="export-stdout"}
```

Filter to `kubectl exec` events only:

```logql
{namespace="tetragon", container="export-stdout"} |= "PROCESS_EXEC" |= "kubectl"
```

The pre-provisioned **Tetragon kubectl exec audit** dashboard (ID 20189) shows this automatically.

### Logs

```bash
kubectl logs -n observability -l app.kubernetes.io/name=loki | tail -50
kubectl logs -n observability -l app.kubernetes.io/name=promtail | tail -50
```

---

## 11. Tetragon

### Tetragon Status

```bash
# DaemonSet — one pod per node, all should be Running
kubectl get pods -n tetragon -o wide

# Operator pod
kubectl get pods -n tetragon -l app.kubernetes.io/name=tetragon-operator

# Confirm custom TracingPolicies are loaded (shell-exec-detection, sensitive-file-access)
kubectl get tracingpolicies
# Expected: shell-exec-detection and sensitive-file-access both ENABLED=true

# Verify shell-exec-detection fires (exec a shell in any pod and check logs)
kubectl exec -n demo deploy/httpbin -- /bin/sh -c "echo test" 2>/dev/null || true
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout --tail=20 \
  | grep -i "process_kprobe\|shell\|execve" | head -5

# Verify sensitive-file-access fires (read /etc/shadow)
kubectl exec -n demo deploy/httpbin -- cat /etc/shadow 2>/dev/null || true
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout --tail=20 \
  | grep -i "shadow\|openat" | head -5
```

### View Security Events

Tetragon exports events as JSON to stdout on the `export-stdout` container:

```bash
# Stream live events from all nodes
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout -f

# Show recent events (last 50 lines)
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout --tail=50

# Filter to process_exec events only (process launches)
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c export-stdout \
  | grep '"type":"PROCESS_EXEC"' | head -20
```

### Verify Prometheus Metrics Are Being Scraped

```bash
# Port-forward Prometheus (see §14), then query:
curl -s 'http://localhost:9090/api/v1/query?query=tetragon_events_total' | jq '.data.result'

# Confirm scrape targets are healthy
curl -s http://localhost:9090/api/v1/targets \
  | jq '[.data.activeTargets[] | select(.labels.job | test("tetragon")) | {job: .labels.job, health: .health}]'
```

### Tetragon Logs

```bash
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -c tetragon | tail -50
kubectl logs -n tetragon deploy/tetragon-operator | tail -50
```

---

## 12. Kyverno

### Kyverno Status

```bash
# All four controllers — admission, background, cleanup, reports
kubectl get pods -n kyverno

# ClusterPolicies — READY: True, BACKGROUND: True for all six
# Validation policies: pod-security-baseline, disallow-latest-image-tag,
#   require-resource-limits (Enforce), disallow-privilege-escalation (Enforce)
# Mutation policy:    mutate-jobs-disable-istio-injection (apps/base/kyverno/mutations.yaml)
# Supply chain policy: verify-image-signatures (apps/base/kyverno/verify-images.yaml)
kubectl get clusterpolicies
```

### View Policy Violations

Violations in Audit mode are recorded but do not block requests:

```bash
# All cluster-wide policy reports
kubectl get clusteradmissionreports -A

# Detailed violations for a specific report
kubectl describe clusteradmissionreport <name> -n <namespace>

# Count violations by policy across the cluster
kubectl get clusteradmissionreports -A -o json \
  | jq '[.items[].spec.summary.fail] | add'
```

### View Image Signature Verification Violations

The `verify-image-signatures` policy runs in Audit mode. Kyverno records violations in `PolicyReport` resources (namespace-scoped) and `ClusterPolicyReport` resources (cluster-scoped):

```bash
# Namespace-scoped reports — one per namespace where pods were admitted
kubectl get policyreport -A

# Filter for verify-image-signatures violations only
kubectl get policyreport -A -o json \
  | jq '[.items[].results[] | select(.policy == "verify-image-signatures" and .result == "fail")]'

# Cluster-scoped report summary
kubectl get clusterpolicyreport -o json \
  | jq '.items[].results[] | select(.policy == "verify-image-signatures")'
```

A violation means Kyverno could not confirm the image was signed by the expected GitHub Actions workflow at the Rekor transparency log. Common causes:
- Image pulled without a tag (digest-only reference resolves, but the `imageReferences` glob `*` matches tags, not bare digests — see Kyverno `imageReferences` docs)
- Cosign signature not present in the Rekor log (pre-release or unofficial build)
- Rekor or `quay.io` temporarily unreachable (the `webhookTimeoutSeconds: 30` budget expired)

To promote the policy from Audit to Enforce once violations are confirmed false-positive free:

```bash
kubectl patch clusterpolicy verify-image-signatures \
  --type=merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

### Run Policy Unit Tests

Offline — no cluster required. Tests all four validation ClusterPolicies against 9 representative pods (45 tests) and the mutation policy against 3 Job/Deployment fixtures (3 tests):

```bash
# Via Make (runs kyverno test under the hood):
make test-policies
# Requires: brew install kyverno

# Or run directly to see the full per-test table:
kyverno test apps/base/kyverno/tests/
```

Expected output: `48 tests passed and 0 tests failed`.

The direct `kyverno test` invocation is useful when revising policy — it prints a table showing every resource, which rule evaluated it, and whether the result matched the assertion (pass / fail / skip / excluded). The `make` wrapper is suitable for CI and rapid validation runs.

Test layout:
- `apps/base/kyverno/tests/kyverno-test.yaml` — 45 tests across the four validation ClusterPolicies
- `apps/base/kyverno/tests/mutations/kyverno-test.yaml` — 3 tests for `mutate-jobs-disable-istio-injection`

The `verify-image-signatures` policy has no offline unit tests. Cosign keyless verification requires a live connection to the image registry and the Rekor transparency log; it cannot be exercised with static fixture manifests.

### Kyverno Logs

```bash
# Admission controller — most relevant for debugging policy decisions
kubectl logs -n kyverno deploy/kyverno-admission-controller | tail -50

# Background controller — handles existing resources
kubectl logs -n kyverno deploy/kyverno-background-controller | tail -50
```

---

## 13. Falco

### Falco Status

```bash
# DaemonSet — one pod per node
kubectl get pods -n falco -o wide

# Falcosidekick (alert routing to Loki)
kubectl get pods -n falco -l app.kubernetes.io/name=falcosidekick

# Confirm modern_ebpf driver loaded (no kernel module, no init container)
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=5
# Expected: "Driver loaded: modern_ebpf" in the startup lines
```

### View Recent Alerts

```bash
# Stream live Falco alerts from all nodes
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Recent alerts (last 50 lines)
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=50

# Filter to critical/error priority only
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=200 \
  | grep -i 'Critical\|Error'
```

### Query Falco Alerts in Grafana

Open `http://grafana.local:8080`, navigate to **Dashboards → Falco — Runtime Security**.

Or query Loki directly in **Explore**:

```logql
{namespace="falco", container="falco"}
```

Filter to a specific priority:

```logql
{namespace="falco", container="falco"} |= "Critical"
```

### Verify Falco Metrics in Prometheus

```bash
# Port-forward Prometheus (see §14), then query:
curl -s 'http://localhost:9090/api/v1/query?query=falco_rules_matches_total' | jq '.data.result'

# Confirm scrape target is healthy
curl -s http://localhost:9090/api/v1/targets \
  | jq '[.data.activeTargets[] | select(.labels.job | test("falco")) | {job: .labels.job, health: .health}]'
```

### Live Detection Test

Requires a running cluster with Falco healthy.

```bash
make test-falco
```

This deploys `falcosecurity/event-generator:0.13.0` as a Job that triggers the syscall action suite, then checks the Falco pod log on the same node for 4 expected rule matches. The target removes the `falco-test` namespace on completion.

### Falco Logs

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | tail -50
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick | tail -50
```

---

## 14. Prometheus

### Prometheus Status

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=prometheus
kubectl get pods -n observability -l app.kubernetes.io/name=kube-prometheus-stack-operator
```

### Prometheus UI

No port-forward required via Contour HTTPProxy:

```text
http://prometheus.local:8080
```

Or via port-forward for direct API access:

```bash
kubectl port-forward -n observability svc/observability-kube-prometh-prometheus 9090:9090
# Open: http://localhost:9090
```

### Verify Cilium Metrics Are Being Scraped

```bash
# Port-forward first (see above), then query:
curl -s 'http://localhost:9090/api/v1/query?query=cilium_version' | jq '.data.result'
curl -s 'http://localhost:9090/api/v1/query?query=hubble_flows_processed_total' | jq '.data.result'

# Check scrape targets — Cilium should appear under Status > Targets in the UI
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | test("cilium")) | {job: .labels.job, health: .health}'
```

### Check Scrape Job Health

```bash
# All configured scrape jobs and their status
curl -s http://localhost:9090/api/v1/targets | jq '[.data.activeTargets[] | {job: .labels.job, health: .health, lastError: .lastError}] | group_by(.health)'
```

### Verify OTel Collector Self-Metrics Are Being Scraped

```bash
# Port-forward first (see above), then:
curl -s 'http://localhost:9090/api/v1/targets' \
  | python3 -c "import json,sys; [print(t['scrapeUrl'], t['health']) \
    for t in json.load(sys.stdin)['data']['activeTargets'] \
    if 'opentelemetry' in str(t['labels'])]"

# Or query a known OTel self-metric
curl -s 'http://localhost:9090/api/v1/query?query=otelcol_receiver_accepted_spans_total' \
  | jq '.data.result'
```

### Prometheus Logs

```bash
kubectl logs -n observability -l app.kubernetes.io/name=prometheus --container=prometheus | tail -50
```

---

## 15. Grafana

### Grafana UI

No port-forward required via Contour HTTPProxy:

```text
http://grafana.local:8080
Username: admin
Password: changeme  (set via adminPassword in apps/base/grafana/helmrelease.yaml)
```

Or via port-forward for API access:

```bash
kubectl port-forward -n observability svc/observability-grafana 3000:80
# Open: http://localhost:3000
```

### Grafana Status

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=grafana
```

### Verify the grafana-secret-key Secret Exists

The Grafana pod will not start if this Secret is missing from the `observability` namespace:

```bash
kubectl get secret grafana-secret-key -n observability
# If missing, recreate it:
kubectl create secret generic grafana-secret-key \
  --namespace observability \
  --from-literal=secret-key="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
# Then force a clean install:
flux suspend helmrelease grafana -n flux-system && flux resume helmrelease grafana -n flux-system
```

### Verify Dashboards Loaded

After opening the UI, navigate to **Dashboards** and confirm these 16 are present. Nine are downloaded from grafana.com at pod startup (requires internet access); seven are loaded from a ConfigMap and are always available offline.

| Dashboard | Source |
|---|---|
| Node Exporter Full (home dashboard) | gnetId 1860 — grafana.com |
| Cilium Agent | gnetId 16611 — grafana.com |
| Cilium Operator | gnetId 16612 — grafana.com |
| Hubble | gnetId 16613 — grafana.com |
| Istio Control Plane | gnetId 7639 — grafana.com |
| Istio Mesh | gnetId 7636 — grafana.com |
| Istio Service | gnetId 7630 — grafana.com |
| Istio Workload | gnetId 7645 — grafana.com |
| cert-manager | gnetId 20842 — grafana.com |
| Kyverno | ConfigMap — apps/base/grafana/dashboards/ (gnetId 15804, patched) |
| Flux Cluster Stats | ConfigMap — apps/base/grafana/dashboards/ |
| Flux Control Plane | ConfigMap — apps/base/grafana/dashboards/ |
| Tetragon kubectl exec audit | ConfigMap — apps/base/grafana/dashboards/ (Loki datasource) |
| Falco — Runtime Security | ConfigMap — apps/base/grafana/dashboards/ (Prometheus + Loki datasources) |
| Kubescape Security Posture | ConfigMap — apps/base/grafana/dashboards/ (Prometheus datasource) |
| OpenTelemetry Collector | ConfigMap — apps/base/grafana/dashboards/ (gnetId 15983, patched) |

### Verify Prometheus Datasource

```bash
# Test the datasource via Grafana's API
kubectl port-forward -n observability svc/observability-grafana 3000:80 &
curl -s -u admin:changeme http://localhost:3000/api/datasources | jq '.[].name'
curl -s -u admin:changeme 'http://localhost:3000/api/datasources/proxy/1/api/v1/query?query=up' | jq '.status'
```

### Grafana Logs

```bash
kubectl logs -n observability deploy/observability-grafana -c grafana | tail -50
```

---

## 16. Flux GitHub Notifications

Flux posts commit status checks to GitHub via the notification controller. The Provider and Alerts live in `apps/base/notifications/`; the `github-token` secret is created by the bootstrap script (step 9 of 10).

### Check Notification Controller Health

```bash
# Notification controller pod
kubectl get pods -n flux-system -l app=notification-controller

# Provider status — should show READY: True
kubectl get provider -n flux-system github

# Alert status — both should show READY: True
kubectl get alert -n flux-system
```

### Verify the github-token Secret Exists

```bash
kubectl get secret github-token -n flux-system
# If missing, re-run:
GITHUB_TOKEN="$(gh auth token)" kubectl create secret generic github-token \
  --namespace flux-system \
  --from-literal=token="${GITHUB_TOKEN}"
```

### Notification Controller Logs

```bash
kubectl logs -n flux-system deploy/notification-controller | tail -30

# Look for successful dispatches — event references the source commit SHA
kubectl logs -n flux-system deploy/notification-controller | grep -i "dispatching"

# Look for errors (missing secret, invalid token, etc.)
kubectl logs -n flux-system deploy/notification-controller | grep -i "error"
```

### Confirm Commit Statuses Appear on GitHub

```bash
# After a reconcile, check the commit SHA for pending/success/failure statuses
gh api repos/DevOpsMaestro/homelab-gitops-k8s-2026/commits/$(git rev-parse HEAD)/statuses \
  | jq '.[0:3] | .[] | {state: .state, context: .context, updated_at: .updated_at}'
```

The token must have `repo:status` scope. `gh auth token` provides this scope automatically when authenticated via `gh auth login --scopes repo`.

---

## 17. Grafana Tempo

### Tempo Status

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=tempo
kubectl get helmrelease tempo -n flux-system
```

### Tempo Health Check

```bash
kubectl port-forward -n observability svc/observability-tempo 3200:3200 &
curl -s http://localhost:3200/ready   # expects: ready
```

### Query Traces via Tempo API

```bash
# List recent traces by service name
curl -s 'http://localhost:3200/api/search?tags=service.name%3Dhttpbin.demo' | python3 -m json.tool | head -40

# Total trace count (should be > 0 after load-generator runs)
curl -s 'http://localhost:3200/api/search?limit=5' | jq '.traces | length'
```

### Verify Grafana Tempo Datasource

```bash
kubectl port-forward -n observability svc/observability-grafana 3000:80 &
curl -s -u admin:changeme http://localhost:3000/api/datasources \
  | jq '.[] | select(.type=="tempo") | {name, url}'
# url should be: http://observability-tempo.observability.svc.cluster.local:3200
```

### Tempo Logs

```bash
kubectl logs -n observability -l app.kubernetes.io/name=tempo --tail=50
```

---

## 18. OpenTelemetry Collector

### OTel Collector Status

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=opentelemetry-collector
kubectl get helmrelease opentelemetry-collector -n flux-system
```

### Verify Spans Are Flowing In

```bash
# Port-forward Prometheus first (see §14), then:
curl -s 'http://localhost:9090/api/v1/query?query=otelcol_receiver_accepted_spans_total' \
  | jq '.data.result'
# Non-zero value confirms Envoy sidecars are delivering spans
```

### Verify Spans Are Exported to Tempo

```bash
curl -s 'http://localhost:9090/api/v1/query?query=otelcol_exporter_sent_spans_total' \
  | jq '.data.result'
```

### OTel Collector Logs

```bash
kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --tail=50
```

### Rendered Pipeline Config

```bash
kubectl get configmap -n observability \
  -l app.kubernetes.io/name=opentelemetry-collector -o yaml | grep -A 80 "config.yaml:"
```

### Envoy Cluster Stats — Confirm Sidecars Are Connecting

```bash
# Exec into a demo pod and check the OTel exporter cluster
kubectl exec -n demo deploy/httpbin -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep opentelemetry
# Look for cx_active > 0 and rq_success > 0
```

---

## 19. Kubescape

### Kubescape Status

```bash
kubectl get pods -n kubescape
kubectl get helmrelease kubescape -n flux-system
```

### Run a Manual Scan

```bash
# Live cluster scan via Make (NSA + MITRE frameworks)
make test-kubescape

# Or run directly against the current context
kubescape scan framework nsa,mitre \
  --cluster-context "kind-flux-kind" \
  --format pretty-printer \
  --verbose
```

### View Scan Results in Grafana

Open `http://grafana.local:8080`, navigate to **Dashboards → Kubescape Security Posture**. The dashboard shows compliance scores for NSA and MITRE controls, resource-level findings, and historical trends sourced from the in-cluster Prometheus metrics exposed by the kubescape `prometheus-exporter` pod.

### Review Accepted Risk Decisions

Controls that have been reviewed and deliberately accepted are recorded in `docs/kubescape-security.md` with the control ID, affected resource, and rationale. Consult that document before investigating a finding — it may already be a known accepted risk.

### Kubescape Logs

```bash
# Main scanner
kubectl logs -n kubescape deploy/kubescape | tail -50

# Operator (manages scheduling and config)
kubectl logs -n kubescape deploy/operator | tail -50

# Prometheus exporter (exposes metrics to Prometheus)
kubectl logs -n kubescape deploy/prometheus-exporter | tail -50
```

---

## 20. SOPS + Age

See [docs/sops-age-secrets.md](sops-age-secrets.md) for the complete setup guide, day-to-day workflow, and cluster rebuild procedure.

### Verify the sops-age Secret Is Present

```bash
kubectl get secret sops-age -n flux-system
# If missing: make sops-load-key
```

### Verify Flux Decrypted a Secret Successfully

```bash
# grafana-admin-secret is the reference encrypted secret in this project
kubectl get secret grafana-admin-secret -n flux-system
kubectl get secret grafana-admin-secret -n flux-system \
  -o jsonpath='{.data.admin-user}' | base64 -d
kubectl get secret grafana-admin-secret -n flux-system \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Diagnose a Decryption Failure

If a Kustomization is stuck with a decryption error:

```bash
# Check the apps Kustomization status
flux get kustomization apps -n flux-system
kubectl describe kustomization apps -n flux-system | grep -A 10 "Status:"

# Confirm the sops-age secret contains a valid age key
kubectl get secret sops-age -n flux-system \
  -o jsonpath='{.data.age\.agekey}' | base64 -d | head -3
# Expected first line: "# created: ..."
# Expected second line: "# public key: age1..."
```

### Edit an Existing Encrypted Secret

```bash
# Opens decrypted YAML in $EDITOR — re-encrypts automatically on save
sops apps/base/grafana/admin-secret.yaml
```

### Common Issue: sops Encrypt Fails with GPG Keyring Error

A leftover `SOPS_PGP_FP` environment variable overrides `.sops.yaml` and forces SOPS to use a GPG key that no longer exists in the keyring.

```bash
# Confirm this is the cause
echo $SOPS_PGP_FP   # non-empty output means this is the issue

# Fix for the current session
unset SOPS_PGP_FP

# Fix permanently
sed -i '' '/SOPS_PGP_FP/d' ~/.zshrc
```

---

## 21. Common Issues

### All Grafana Dashboards Blank After Mac Wakes from Sleep

**Symptom:** Every dashboard panel shows a TLS error mentioning `CERTIFICATE_VERIFY_FAILED`.
**Cause:** Docker Desktop's Linux VM pauses during Mac sleep, which halts Istio's cert-rotation goroutine. Workload certificates are valid for 24 h; if the rotation window passes while the VM is paused, the sidecar presents an expired certificate until the pod restarts.
**Fix:**

```bash
kubectl rollout restart deployment statefulset -n observability
kubectl rollout restart deployment -n demo
```

See [§8 Istio — Grafana Dashboards Blank After Mac Wakes from Sleep](#8-istio) for full diagnosis steps and verification commands.

---

### Cilium Agent Fails to Start on Worker Nodes

**Symptom:** `config` init container loops with `connection refused` to `127.0.0.1:6443`.
**Cause:** `k8sServiceHost: 127.0.0.1` only resolves to the API server on the control-plane node. Workers have no API server on localhost.
**Fix:** `k8sServiceHost` must be `flux-kind-control-plane` (the Docker bridge hostname), not `127.0.0.1`.

```bash
# Confirm the current value Cilium is using
kubectl get configmap cilium-config -n kube-system -o jsonpath='{.data.k8s-api-server}'
```

### HelmRelease Stuck in "install failed" After Timeout

```bash
# Force an immediate retry without waiting for the interval
flux reconcile helmrelease <name> -n flux-system

# Check why it failed
kubectl describe helmrelease <name> -n flux-system | grep -A 20 "Status:"
```

### Flux Not Picking Up New Commits

```bash
# Force git pull + full reconcile
flux reconcile source git flux-system
```

### Cilium-Managed HelmRelease Conflicts with Pre-Installed Release

**Symptom:** Flux installs a second release (`kube-system-cilium`) instead of adopting the pre-installed `cilium` release.
**Fix:** `spec.releaseName: cilium` must be set in the Cilium HelmRelease so Flux targets the correct Helm release name.

```bash
# Verify which Helm releases exist in kube-system
helm list -n kube-system
```

### istioctl analyze Reports Unlabelled Namespaces (IST0102)

**Fix:** All non-mesh namespaces should carry `istio-injection: disabled` on their Namespace resource. This is set in the relevant `infrastructure/controllers/*.yaml` and `apps/base/prometheus/namespace.yaml` files, and via a kustomize patch on `flux-system`.

### Istio Port Naming Warning (IST0118)

**Symptom:** `Port name metrics does not follow Istio naming convention`.
**Fix:** cert-manager webhook services are patched via `postRenderers.kustomize.patches` in `infrastructure/controllers/cert-manager.yaml`. Grafana is fixed via `service.portName: http` in `apps/base/grafana/helmrelease.yaml`.

### localhost:8080 Connects but Immediately Resets (Gateway Unreachable)

**Symptom:** `curl localhost:8080` connects then receives `Connection reset by peer` after ~15 s.
**Cause:** On macOS Docker Desktop + Cilium kube-proxy replacement, `localhost:8080` traffic arrives at the KinD container's loopback (`127.0.0.1`), not `eth0`. Cilium's NodePort BPF rules only handle traffic incoming on `eth0` (from the Docker bridge). The TCP handshake completes (Docker's proxy accepts it) but the traffic is never forwarded to the NodePort backend.
**Active setup:** The nginx `nodeport-proxy` DaemonSet in `apps/overlays/kind/istio/nodeport-proxy.yaml` is the primary path — it runs with `hostNetwork: true` on the control-plane, listens on port 8888 (outside the NodePort range), and forwards all HTTP traffic to `contour-contour-envoy.contour.svc.cluster.local:80`. KinD maps `localhost:8080 → containerPort: 8888`.

If traffic fails after confirming Flux is reconciled:

```bash
# Check the nginx nodeport-proxy pod
kubectl get pods -n envoy-ingress -l app=nodeport-proxy
kubectl logs -n envoy-ingress -l app=nodeport-proxy | tail -20

# Check the Contour Envoy DaemonSet pods
kubectl get pods -n contour -l app.kubernetes.io/component=envoy

# Test from inside the cluster (bypasses macOS Docker Desktop routing)
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}" -H "Host: grafana.local" \
  http://contour-contour-envoy.contour.svc.cluster.local/
```

### ServiceMonitor CRD Not Found During Cilium Install

**Symptom:** `no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`.
**Cause:** Circular dependency — ServiceMonitor CRD lives in the apps layer (kube-prometheus-stack), which depends on the infrastructure layer (Cilium).
**Fix:** Cilium's `serviceMonitor.enabled` is `false` for all three monitors. Prometheus scrapes Cilium via `additionalScrapeConfigs` in `apps/base/prometheus/helmrelease.yaml` instead.

### Falco Not Detecting Expected Rules

**Symptom:** `make test-falco` reports one or more rules not detected.

```bash
# 1. Check that the modern_ebpf driver loaded successfully
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20 | grep -i "driver"

# 2. Check if Falco itself is reporting any startup errors
kubectl describe pod -n falco -l app.kubernetes.io/name=falco | grep -A 10 "Events:"

# 3. Confirm the event-generator Job ran on a node that has a Falco pod
kubectl get pod -n falco-test -l job-name=falco-event-generator \
  -o jsonpath='{.items[0].spec.nodeName}'
kubectl get pods -n falco -o wide
# The node names must match

# 4. Widen the log window (the make target looks back to Job start time)
kubectl logs -n falco -l app.kubernetes.io/name=falco --since=10m \
  | grep -i "untrusted\|credential\|shell"
```

**Root cause if BTF is unavailable:** `modern_ebpf` requires kernel BTF support. KinD nodes on Linux expose the host kernel BTF at `/sys/kernel/btf/vmlinux`. If the host kernel predates 5.8 or was built without `CONFIG_DEBUG_INFO_BTF`, Falco will fail to load. Upgrade the host kernel or switch to a KinD node image with a newer kernel.

### nginx nodeport-proxy Crashes on Startup with "host not found in upstream"

**Symptom:** The `nodeport-proxy` DaemonSet enters `CrashLoopBackOff`. Pod logs show:

```
nginx: [emerg] host not found in upstream "some-service.namespace.svc.cluster.local"
```

**Cause:** nginx resolves all `proxy_pass` hostnames at startup, before any requests arrive. If any upstream Service does not exist yet — or if its DNS name is wrong — nginx exits immediately, taking down every configured route.

**Fix:** Two changes are required together:
1. Add a `resolver` directive pointing to kube-dns so nginx can look up Service hostnames.
2. Use a `$variable` for each `proxy_pass` target instead of a literal hostname. This defers DNS resolution to request time rather than process startup. An unresolvable upstream then returns `502` per-request instead of crashing the proxy.

```nginx
http {
    resolver 10.96.0.10 valid=10s ipv6=off;

    server {
        listen 8888;
        server_name example.local;
        location / {
            set $upstream http://my-service.my-namespace.svc.cluster.local;
            proxy_pass $upstream;
        }
    }
}
```

**Diagnosis steps:**

```bash
# Check crash reason
kubectl logs -n envoy-ingress -l app=nodeport-proxy --previous | head -10

# Verify the upstream Service actually exists
kubectl get svc -n <namespace> <service-name>

# Check the full nginx config currently in use
kubectl get configmap -n envoy-ingress nodeport-proxy-conf -o yaml
```

---

### nginx Routes All Requests to the Wrong Backend (Missing `default_server`)

**Symptom:** After adding a hostname-specific `server {}` block to the nginx ConfigMap, requests to *other* hostnames (e.g., `grafana.local`) are handled by the new block instead of the intended catch-all block.

**Cause:** `server_name _;` is not a true wildcard. The underscore is simply an invalid DNS name that matches nothing by normal server-name lookup. When nginx receives a request whose `Host` header does not match any `server_name`, it routes to the **first** defined `server {}` block — not the `server_name _` block. If the hostname-specific block was defined first, it becomes the de-facto default.

**Fix:** Add `default_server` to the `listen` directive of the intended catch-all block:

```nginx
server {
    listen 8888 default_server;
    server_name _;
    # ...
}
```

This explicitly designates one block as the fallback for all unmatched host headers, regardless of block ordering.

**Diagnosis:**

```bash
# Check nginx error log for which server block is handling a request
kubectl logs -n envoy-ingress -l app=nodeport-proxy | grep "server:"

# A fast way to confirm: send a request with a host nginx should NOT recognize
# and see which upstream receives it
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: unknown.local" http://localhost:8080/
```

---

## 22. BOINC

See [docs/boinc.md](boinc.md) for full operational detail. Quick reference below.

### BOINC Status

```bash
# Pods — one per node, all should be Running
kubectl get pods -n boinc -o wide

# Recent logs — look for project attach messages on first start
kubectl logs -n boinc -l app=boinc --tail=50
```

### Check Project Attachment

```bash
POD=$(kubectl get pod -n boinc -l app=boinc -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n boinc $POD -- boinccmd --get_project_status
```

Expected: two projects listed — `https://boinc.bakerlab.org/rosetta/` and `https://einstein.phys.uwm.edu/`.

### Update Credentials

```bash
# Edit and re-encrypt in one step
sops apps/base/boinc/boinc-projects-secret.yaml

# After committing and pushing, restart to pick up new credentials
kubectl rollout restart daemonset/boinc -n boinc
```

### BOINC Logs

```bash
kubectl logs -n boinc -l app=boinc --tail=50

# Filter to errors only
kubectl logs -n boinc -l app=boinc | grep -iE "error|failed|invalid"
```

### initContainer Logs (Credential Copy Step)

```bash
kubectl logs -n boinc <pod-name> -c boinc-account-init
```

If the initContainer failed, verify the Secret was decrypted by Flux:

```bash
kubectl get secret boinc-projects-secret -n boinc
# If missing, check: flux get kustomization apps -n flux-system
```

---

## 23. Renovate

See [docs/renovate.md](renovate.md) for full configuration details and design decisions.

### Check Pending Renovate PRs

```bash
gh pr list --label "renovate"
```

Renovate also creates a **Dependency Dashboard** issue in the repository listing all detected updates, their status, and which PRs are open or scheduled.

### Renovate Opened a PR — What Happens Next

1. CI (`validate` workflow) runs automatically on the PR.
2. If CI passes and the update type is automerge-eligible (patch images, GitHub Actions): Renovate merges it automatically via GitHub branch protection.
3. If CI fails: the PR remains open and Renovate does not merge — investigate the failure.

### A PR Automerged and the Cluster Is Broken — Roll Back

```bash
# Find the merge commit
git log --oneline -10

# Revert it (creates a new commit, does not rewrite history)
git revert <merge-commit-sha>
git push origin main

# Force Flux to reconcile immediately
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization apps --with-source
```

### Renovate Is Not Opening PRs

Check that the scheduled workflow has run: **Actions → Renovate** on GitHub. If no recent runs appear, trigger one manually with **Run workflow**.

If the workflow ran but no PRs appeared, open the **Dependency Dashboard** issue in the repository — Renovate posts error messages there when a registry lookup fails or a custom manager regex did not match.

### Snooze or Disable a Specific Update

Add a `packageRules` entry to `renovate.json`:

```json
{
  "matchPackageNames": ["some-chart"],
  "enabled": false
}
```

Alternatively, use the Dependency Dashboard issue — Renovate provides checkboxes to suppress specific updates directly from the issue.

### Renovate Proposed a KinD Node Version That Does Not Exist

**Symptom:** Renovate opens a PR bumping `K8S_VER` in `versions.env` to a new Kubernetes version (e.g., `v1.36.2`), but the cluster rebuild fails because KinD cannot pull the node image:

```
ERROR: failed to pull image "kindest/node:v1.36.2": ...
docker: Error response from daemon: manifest unknown
```

**Cause:** The Kubernetes project publishes a GitHub release and tags the `kubernetes/kubernetes` repository as soon as a version is cut. KinD then builds and publishes the corresponding `kindest/node` Docker image — but there is a delay of hours to days between the GitHub tag and the Docker image being available. If the Renovate `customManager` for `K8S_VER` uses `datasourceTemplate: github-releases` with `kubernetes/kubernetes`, Renovate proposes the version the moment GitHub is tagged, before the Docker image exists.

**Fix:** Change the datasource in `renovate.json` to `docker` with `depNameTemplate: kindest/node`. Renovate then queries Docker Hub directly and only proposes versions for which a `kindest/node` image actually exists:

```json
{
  "matchStrings": ["K8S_VER=v?(?<currentValue>[^\\n]+)"],
  "depNameTemplate": "kindest/node",
  "datasourceTemplate": "docker"
}
```

**Recovery:** If the broken PR was already merged, revert the commit:

```bash
git log --oneline -5
git revert <merge-commit-sha>
git push origin main
flux reconcile source git flux-system -n flux-system
```

---

## 24. Metrics Server

Metrics Server implements `metrics.k8s.io/v1beta1` — the API behind `kubectl top` and HPA.

### Health Check

```bash
# API service must be Available=True
kubectl get apiservice v1beta1.metrics.k8s.io

# Pod should be Running in the metrics-server namespace
kubectl get pods -n metrics-server

# Logs
kubectl logs -n metrics-server deploy/metrics-server | tail -30
```

### Verify Metrics Are Flowing

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage across all namespaces
kubectl top pods -A
```

### Common Failure — `kubectl top` Returns ServiceUnavailable

This typically indicates the metrics-server pod is not ready or the API service is degraded.

```bash
# Check pod status and recent events
kubectl describe pod -n metrics-server -l app.kubernetes.io/name=metrics-server

# Confirm the --kubelet-insecure-tls arg is present (required for KinD)
kubectl get deploy -n metrics-server metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

If the pod keeps restarting, verify that Kyverno policies are satisfied — the `metrics-server` namespace is subject to `require-resource-limits` and `disallow-privilege-escalation` enforcement. The HelmRelease values set these correctly; if the `resources` or `containerSecurityContext` blocks have been customised, restore them to the values defined in the HelmRelease.

---

## 25. Trivy Operator

Trivy Operator continuously scans every running container image for known CVEs and produces `VulnerabilityReport` CRDs (one per workload). Only fixable CVEs are reported (`ignoreUnfixed: true`). Metrics are exposed on port 8080 and scraped by Prometheus via `additionalScrapeConfigs`.

### Health Check

```bash
# Operator pod should be Running in trivy-system
kubectl get pods -n trivy-system

# List generated vulnerability reports
kubectl get vulnerabilityreports -A

# Summary by severity across all namespaces
kubectl get vulnerabilityreports -A -o json \
  | jq '[.items[].report.summary] | {
      critical: (map(.criticalCount) | add),
      high:     (map(.highCount)     | add),
      medium:   (map(.mediumCount)   | add)
    }'
```

### View CVEs for a Specific Workload

```bash
# List reports in a namespace
kubectl get vulnerabilityreports -n observability

# Describe a specific report (shows CVE IDs, severity, fixed version)
kubectl describe vulnerabilityreport -n observability <report-name>
```

### Common Failure — node-collector Pod Stays Pending

The `infraAssessmentScannerEnabled` option is disabled in `infrastructure/controllers/trivy.yaml` because the node-collector Deployment uses cloud-node affinity rules that never match KinD worker nodes. If a `node-collector` pod appears Pending, confirm the setting is present:

```bash
kubectl get helmrelease trivy-operator -n flux-system -o jsonpath='{.spec.values.operator}'
```

Expected output includes `"infraAssessmentScannerEnabled":false`.

### Prometheus Metrics

```bash
# Confirm Trivy metrics are being scraped
curl -s http://prometheus.local:8080/api/v1/label/__name__/values \
  | jq '.data[] | select(startswith("trivy_"))'
```

Key metrics: `trivy_image_vulnerabilities` (by severity), `trivy_resource_configaudits` (policy violations).

---

## 26. iperf3

iperf3 runs as a single-replica server in the `iperf3` namespace. External tests are initiated from the host Mac and travel through Docker port mappings and the nginx nodeport-proxy `stream {}` block directly to the iperf3 pod. Contour cannot route plain TCP without TLS, so no HTTP ingress controller is involved. See [docs/iperf3.md](iperf3.md) for the full architecture and test procedures.

### Quick Health Check

```bash
# Pod should be 1/1 Running
kubectl get pods -n iperf3

# Confirm the server is listening inside the pod
kubectl logs -n iperf3 deploy/iperf3-server --tail=20

# Confirm port 9111 is active on the control-plane node
kubectl exec -n envoy-ingress \
  $(kubectl get pod -n envoy-ingress -l app=nodeport-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- ss -tlnp | grep 9111
```

### Issue — "Connection refused" immediately

**Symptom:** `iperf3 -c localhost -p 32111` returns `Connection refused` within milliseconds.

**Cause:** On macOS, `localhost` resolves to `::1` (IPv6) before `127.0.0.1`. Docker binds only to `0.0.0.0:32111` (IPv4), so the IPv6 attempt is refused immediately. iperf3 does not fall back to IPv4.

**Fix:**

```bash
iperf3 -4 -c localhost -p 32111 -t 30
# or
iperf3 -c 127.0.0.1 -p 32111 -t 30
```

Verify the Docker port mapping is present:

```bash
docker port flux-kind-control-plane 9111
# Expected: 0.0.0.0:32111
```

### Issue — Connection times out (no response)

**Symptom:** `iperf3 -4 -c localhost -p 32111` hangs for several seconds before failing.

**Cause:** A NetworkPolicy is dropping packets in the path. The `iperf3` namespace uses a `default-deny` policy. The `allow-nginx-ingress` policy uses an open-port pattern (no `from:` clause) to permit traffic on port 32111 — because nginx uses `hostNetwork: true`, its source IP is the node's host IP, which does not match any pod CIDR selector.

**Diagnose:**

```bash
# Confirm allow-nginx-ingress policy is present and uses open-port pattern
kubectl get networkpolicy -n iperf3 allow-nginx-ingress \
  -o jsonpath='{.spec.ingress}' | python3 -m json.tool
# Expected: ingress rule with ports only, no "from" clause

# Test TCP reachability from the nginx proxy pod
kubectl exec -n envoy-ingress \
  $(kubectl get pod -n envoy-ingress -l app=nodeport-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- nc -zv iperf3.iperf3.svc.cluster.local 32111
# A timeout (not "refused") confirms NetworkPolicy DROP

# Confirm port 9111 is active inside the control-plane node
kubectl exec -n envoy-ingress \
  $(kubectl get pod -n envoy-ingress -l app=nodeport-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- ss -tlnp | grep 9111
```

**Fix:** Ensure `apps/base/iperf3/networkpolicies.yaml` includes `allow-nginx-ingress` with an open-port pattern:

```yaml
  ingress:
    - ports:
        - port: 32111
          protocol: TCP
```

After merging the fix, force Flux to reconcile:

```bash
flux reconcile kustomization apps -n flux-system
```

### Issue — Pod in ImagePullBackOff

**Symptom:** `kubectl get pods -n iperf3` shows `ImagePullBackOff`.

**Cause:** The image tag does not exist on Docker Hub. `networkstatic/iperf3` only publishes `latest` and `multiarch` — versioned tags (e.g. `3.17`) are not available.

**Fix:** The deployment in `apps/base/iperf3/deployment.yaml` must use `networkstatic/iperf3:multiarch`. The `multiarch` tag provides a multi-architecture image that covers both amd64 and arm64 (required for the M5 MacBook Air KinD cluster).

```bash
kubectl describe pod -n iperf3 <pod-name> | grep -A 5 "Events:"
# Look for: failed to resolve reference "docker.io/networkstatic/iperf3:<tag>": not found
```


### Issue — nginx stream block not forwarding TCP

**Symptom:** Port 9111 is not listed in `ss -tlnp` output inside the nginx pod, or nginx logs show a stream configuration error.

**Cause:** The nginx image in use may not have the `ngx_stream_module` compiled in. Confirm the module is loaded:

```bash
kubectl exec -n envoy-ingress <nodeport-proxy-pod> -- nginx -V 2>&1 | grep stream
# Expected output includes: --with-stream
```

If the module is absent, the `stream {}` block in the ConfigMap will be silently ignored or cause a startup error. Verify the ConfigMap was applied correctly:

```bash
kubectl get configmap -n envoy-ingress nodeport-proxy-conf -o yaml | grep -A 10 "stream"
```

Restart the DaemonSet to apply a ConfigMap change:

```bash
kubectl rollout restart daemonset -n envoy-ingress nodeport-proxy
```

### Issue — KinD cluster missing the port mapping

**Symptom:** `docker port flux-kind-control-plane 9111` returns nothing, and `localhost:32111` is not reachable at all.

**Cause:** `extraPortMappings` in KinD are set at cluster creation time and cannot be changed on a running cluster. If the cluster was created before the iperf3 port mapping was added to `scripts/setup-fluxcd-gitops-kind-multinode.sh`, the mapping does not exist.

**Fix:** Recreate the cluster. All state is in Git; the cluster is rebuilt from scratch using the setup script.

```bash
kind delete cluster --name flux-kind
./scripts/setup-fluxcd-gitops-kind-multinode.sh
```

After the cluster is up, verify the mapping exists:

```bash
docker port flux-kind-control-plane 9111
# Expected: 0.0.0.0:32111
```

---

## 27. Contour

Contour is the sole HTTP ingress controller. It acts as a Kubernetes-native control plane: it watches `HTTPProxy` CRs, translates them into Envoy xDS configuration, and streams that configuration via gRPC to its Envoy DaemonSet. The Contour Envoy DaemonSet is the data plane; it receives xDS from Contour and routes live traffic to backend services.

Traffic from `localhost:8080` reaches Contour through the nginx `nodeport-proxy` in `envoy-ingress`. The nginx `default_server` catch-all block forwards all HTTP traffic to `contour-contour-envoy.contour.svc.cluster.local:80`. Contour then routes by the `Host` header using the configured `HTTPProxy` resources. See [§9 HTTP Ingress — Contour](#9-http-ingress--contour) for status and connectivity commands.

### Status

```bash
# Flux HelmRelease
flux get helmrelease contour -n flux-system
# Expected: READY True, chart 0.x (app version v1.33.x)

# Controller and Envoy DaemonSet pods
kubectl get pods -n contour
# Expected: contour-contour-* Running (controller), contour-contour-envoy-* Running (data plane, one per node)

# HTTPProxy CR in the demo namespace
kubectl get httpproxy -n demo
# Expected: FQDN httpbin-contour.local, STATUS valid

# Detailed HTTPProxy conditions
kubectl describe httpproxy httpbin -n demo
```

### End-to-End Connectivity Test

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: httpbin-contour.local" http://localhost:8080/get
# Expected: 200

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: grafana.local" http://localhost:8080/
# Expected: 302

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: prometheus.local" http://localhost:8080/
# Expected: 200
```

Add `127.0.0.1 httpbin-contour.local grafana.local prometheus.local` to `/etc/hosts` to use hostnames directly without a `-H` flag.

### Contour Logs

```bash
# Controller logs — xDS pushes, HTTPProxy reconciliation
kubectl logs -n contour -l app.kubernetes.io/name=contour,app.kubernetes.io/component=contour | tail -50

# Envoy data-plane logs — access logs and errors
kubectl logs -n contour -l app.kubernetes.io/component=envoy | tail -50
```

### Adding a New Service via HTTPProxy

Create an `HTTPProxy` CR in the service's namespace:

```yaml
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: my-app
  namespace: my-namespace
spec:
  virtualhost:
    fqdn: my-app-contour.local
  routes:
    - conditions:
        - prefix: /
      services:
        - name: my-service
          port: 80
```

Then add `127.0.0.1 my-app-contour.local` to `/etc/hosts`.

Because the nginx catch-all `default_server` block forwards all HTTP traffic to Contour, no nginx ConfigMap change is required when adding new `HTTPProxy` routes. Simply create the `HTTPProxy` CR and add the hostname to `/etc/hosts`.

### Issue — HelmRelease Fails with "no artifact available for HelmRepository source 'projectcontour'"

**Cause:** The `HelmRepository` URL is wrong. The correct URL for the projectcontour Helm chart repository is:

```
https://projectcontour.github.io/helm-charts/
```

Common incorrect values that produce this error:
- `https://charts.projectcontour.io` — this domain does not exist
- `https://projectcontour.io/helm-charts` — this is not a valid Helm repository endpoint

**Fix:** Verify the `HelmRepository` resource in `infrastructure/controllers/repositories.yaml`:

```bash
kubectl get helmrepository projectcontour -n flux-system -o yaml | grep url
# Expected: https://projectcontour.github.io/helm-charts/

# Check the repository status
flux get source helm projectcontour -n flux-system
```

### Issue — Contour Chart Version Scheme

The Contour Helm chart in `projectcontour/helm-charts` uses an independent version number that does not match the Contour application version. The mapping is:

| Chart version | Contour app version |
|---|---|
| 0.6.x | v1.33.x |

Use `version: "0.x"` in the HelmRelease to track the current chart minor series. Do not use the application version string (e.g., `"1.33.x"`) as the chart version — no such chart version exists and the HelmRelease will fail.

### Issue — NetworkPolicy Blocks All Traffic to/from Contour Envoy Pods

**Symptom:** `httpbin-contour.local` returns `502` or `504`. Requests reach nginx but are dropped before reaching the Contour Envoy pod.

**Cause:** The Bitnami-maintained Contour chart labels its Envoy DaemonSet pods with:

```
app.kubernetes.io/name: contour       (the Helm chart name)
app.kubernetes.io/component: envoy    (the role within the chart)
```

A NetworkPolicy that selects on `app.kubernetes.io/name: envoy` matches **zero pods** because no pod carries that label. The correct selector is `app.kubernetes.io/component: envoy`.

**Diagnosis:**

```bash
# Confirm which labels the Contour Envoy pods actually carry
kubectl get pods -n contour -l app.kubernetes.io/component=envoy --show-labels

# Check current NetworkPolicy selectors
kubectl get networkpolicy -n contour allow-envoy-http-ingress -o yaml | grep -A 5 podSelector
kubectl get networkpolicy -n contour allow-envoy-egress-to-backends -o yaml | grep -A 5 podSelector
```

**Fix:** Both `allow-envoy-http-ingress` and `allow-envoy-egress-to-backends` in `infrastructure/controllers/contour.yaml` must use:

```yaml
podSelector:
  matchLabels:
    app.kubernetes.io/component: envoy
```

### Issue — All Routes Return 504

**Symptom:** Requests to `grafana.local`, `prometheus.local`, and `httpbin-contour.local` all return `504`.

**Cause:** The nginx `default_server` catch-all block is not forwarding to the Contour Envoy Service, or the Contour Envoy DaemonSet pods are not ready.

**Diagnose:**

```bash
# Confirm the Contour Envoy Service name
kubectl get svc -n contour
# Expected: contour-contour-envoy

# Check nginx ConfigMap proxy_pass target
kubectl get configmap -n envoy-ingress nodeport-proxy-conf -o yaml | grep contour_upstream

# Contour Envoy pod health
kubectl get pods -n contour -l app.kubernetes.io/component=envoy
```

**Fix:** Ensure the nginx catch-all block uses `listen 8888 default_server;` and proxies to `contour-contour-envoy.contour.svc.cluster.local:80`:

```nginx
server {
    listen 8888 default_server;
    server_name _;
    location / {
        set $contour_upstream http://contour-contour-envoy.contour.svc.cluster.local:80;
        proxy_pass $contour_upstream;
        # ...
    }
}
```

After updating the ConfigMap, restart the DaemonSet:

```bash
kubectl rollout restart daemonset -n envoy-ingress nodeport-proxy
kubectl rollout status daemonset -n envoy-ingress nodeport-proxy
```

### Issue — Contour Envoy Service Name

The Contour chart creates Kubernetes Services using the Helm release name as a prefix. With the release named `contour` installed in the `contour` namespace, the resulting Envoy Service name is:

```
contour-contour-envoy.contour.svc.cluster.local
```

The pattern is `<release-name>-<chart-name>-envoy`. If the nginx ConfigMap uses the wrong service name (e.g., `envoy.contour.svc.cluster.local`), nginx will crash on startup with a "host not found in upstream" error.

```bash
# Confirm the actual Service name
kubectl get svc -n contour
```
