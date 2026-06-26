# Istio — Advanced Administration Reference

Cluster: `flux-kind` · Istio 1.30.2 · Cilium CNI with `socketLB.hostNamespaceOnly: true`

---

## Table of Contents

1. [mTLS Policy Enforcement](#1-mtls-policy-enforcement)
2. [Authorization Policy](#2-authorization-policy)
3. [Certificate Management](#3-certificate-management)
4. [Traffic Management](#4-traffic-management)
5. [Observability](#5-observability)
6. [Envoy Proxy Deep Inspection](#6-envoy-proxy-deep-inspection)
7. [Performance and Resource Tuning](#7-performance-and-resource-tuning)
8. [Mesh-Wide Configuration](#8-mesh-wide-configuration)
9. [Security Auditing](#9-security-auditing)
10. [Disaster Recovery and Rollback](#10-disaster-recovery-and-rollback)

---

## 1. mTLS Policy Enforcement

### Enforce STRICT mTLS Across the Entire Mesh

```bash
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # cluster-wide scope
spec:
  mtls:
    mode: STRICT
EOF
```

> **Warning:** Apply STRICT mode mesh-wide only after confirming every workload carries a sidecar (`istioctl proxy-status`). Any pod without a proxy will lose all inbound traffic.

### Enforce STRICT mTLS for a Single Namespace

```bash
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: <namespace>
spec:
  mtls:
    mode: STRICT
EOF
```

### Exempt a Specific Port from mTLS

> **Important — two constraints for `portLevelMtls`:**
>
> 1. **Workload selector required.** `portLevelMtls` is silently ignored on namespace-default PeerAuthentications (no `selector`). Apply per-workload exceptions using a separate named PeerAuthentication with a `spec.selector.matchLabels` field targeting the specific workload.
> 2. **Port keys must be quoted strings.** Write `"8080":` not `8080:`. Some YAML parsers (and kustomize's JSON marshaller) treat a bare integer key as `map[interface{}]interface{}` rather than `map[string]interface{}`, which causes a type error when the manifest is patched or diffed. The Kubernetes API server accepts both forms, but quoting avoids parser ambiguity in tooling.

```bash
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: <workload>-port-8080
  namespace: <namespace>
spec:
  selector:
    matchLabels:
      app: <workload>
  mtls:
    mode: STRICT
  portLevelMtls:
    "8080":
      mode: PERMISSIVE
EOF
```

### Audit mTLS Mode for Every Workload

```bash
# Shows effective mTLS mode per service — look for DISABLE or PERMISSIVE as risks
istioctl x authz check <pod-name> -n <namespace>

# Check what mode a proxy is actually negotiating
istioctl proxy-config cluster <pod-name> -n <namespace> -o json \
  | jq '.[] | select(.transportSocket) | {name: .name, tls: .transportSocket}'
```

---

## 2. Authorization Policy

### Deny All Traffic by Default, Then Allow Explicitly (Zero-Trust Baseline)

```bash
# Step 1 — deny everything in the namespace
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: <namespace>
spec: {}
EOF

# Step 2 — allow only specific paths from specific principals
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-get-only
  namespace: <namespace>
spec:
  selector:
    matchLabels:
      app: <app-label>
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/<source-namespace>/sa/<source-serviceaccount>
      to:
        - operation:
            methods: ["GET"]
            paths: ["/api/*"]
EOF
```

### Audit Active AuthorizationPolicies

```bash
# List all policies cluster-wide
kubectl get authorizationpolicy -A

# Check which policy is evaluated for a specific request
istioctl x authz check <pod-name> -n <namespace>
```

### Test a Policy Without Enforcing It (AUDIT Action)

```bash
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: audit-policy
  namespace: <namespace>
spec:
  action: AUDIT
  rules:
    - to:
        - operation:
            methods: ["DELETE"]
EOF
# Denied requests are logged in the proxy but traffic still passes.
# Check: kubectl logs <pod> -c istio-proxy | grep "AuthzAudit"
```

---

## 3. Certificate Management

### Inspect Certificates Loaded on a Proxy

```bash
# View cert chain, expiry, and SAN for all certs on a pod
istioctl proxy-config secret <pod-name> -n <namespace>

# Detailed view of a specific cert
istioctl proxy-config secret <pod-name> -n <namespace> -o json \
  | jq '.dynamicActiveSecrets[] | {name: .name, expiry: .secret.tlsCertificate.certificateChain}'
```

### Check the Root CA Used by istiod

```bash
kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.ca-cert\.pem}' \
  | base64 -d | openssl x509 -text -noout | grep -E "Issuer|Subject|Not After"
```

### Force Certificate Rotation for a Workload

```bash
# Delete the proxy secret — istiod will issue a fresh cert on the next xDS push
kubectl delete secret istio.default -n <namespace>
# Restart the workload to load the new cert immediately
kubectl rollout restart deployment/<name> -n <namespace>
```

### Verify cert-manager Is Issuing Istio Workload Certificates

```bash
kubectl get certificaterequests -A | grep istio
kubectl get certificates -n istio-system
```

---

## 4. Traffic Management

### DestinationRule — Connection Pool and Outlier Detection

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: <service>-dr
  namespace: <namespace>
spec:
  host: <service>.<namespace>.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        h2UpgradePolicy: UPGRADE
        http1MaxPendingRequests: 50
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
EOF
```

### VirtualService — Weighted Traffic Split (Canary / Blue-Green)

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: <service>-vs
  namespace: <namespace>
spec:
  hosts:
    - <service>.<namespace>.svc.cluster.local
  http:
    - route:
        - destination:
            host: <service>.<namespace>.svc.cluster.local
            subset: stable
          weight: 90
        - destination:
            host: <service>.<namespace>.svc.cluster.local
            subset: canary
          weight: 10
EOF
```

### Fault Injection — Test Resilience Without Modifying Application Code

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: <service>-fault
  namespace: <namespace>
spec:
  hosts:
    - <service>.<namespace>.svc.cluster.local
  http:
    - fault:
        delay:
          percentage:
            value: 20
          fixedDelay: 3s
        abort:
          percentage:
            value: 5
          httpStatus: 503
      route:
        - destination:
            host: <service>.<namespace>.svc.cluster.local
EOF
```

### Retry Policy

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: <service>-retry
  namespace: <namespace>
spec:
  hosts:
    - <service>.<namespace>.svc.cluster.local
  http:
    - retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: "5xx,reset,connect-failure"
      route:
        - destination:
            host: <service>.<namespace>.svc.cluster.local
EOF
```

---

## 5. Observability

### Access Control Plane Metrics

```bash
# Port-forward istiod metrics endpoint (port 15014 — not 8080, which is the debug HTTP server)
kubectl port-forward -n istio-system deploy/istiod 15014:15014 &
curl -s http://localhost:15014/metrics | grep pilot_
```

### Key Prometheus Queries

```bash
kubectl port-forward -n observability svc/observability-kube-prometh-prometheus 9090:9090 &

# Request success rate per destination service
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(istio_requests_total{reporter="destination",response_code!~"5.."}[5m])) by (destination_service_name) / sum(rate(istio_requests_total{reporter="destination"}[5m])) by (destination_service_name)'

# P99 request latency per service
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination"}[5m])) by (le, destination_service_name))' \
  | jq '.data.result[] | {service: .metric.destination_service_name, p99_ms: .value[1]}'

# mTLS ratio — must be 1.0 for all services under STRICT mode
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(istio_requests_total{connection_security_policy="mutual_tls"}[5m])) by (destination_service_name) / sum(rate(istio_requests_total[5m])) by (destination_service_name)' \
  | jq '.data.result[] | {service: .metric.destination_service_name, mtls_ratio: .value[1]}'
```

### Enable Access Logging on Specific Workloads

```bash
kubectl apply -f - <<'EOF'
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: access-log
  namespace: <namespace>
spec:
  accessLogging:
    - providers:
        - name: envoy
EOF
# Logs appear in: kubectl logs <pod> -c istio-proxy
```

### Distributed Tracing

```bash
# Set trace sampling to 100% for a namespace temporarily
kubectl apply -f - <<'EOF'
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: tracing-100pct
  namespace: <namespace>
spec:
  tracing:
    - randomSamplingPercentage: 100.0
EOF
```

---

## 6. Envoy Proxy Deep Inspection

### Full xDS Configuration Dump

```bash
# Dump everything Envoy has received from istiod
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | jq .
```

### Live Cluster Health and Connection Statistics

```bash
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep -E "health|cx_active|rq_active"
```

### Inspect Active Listeners on the Proxy Admin Port

```bash
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s http://localhost:15000/listeners
```

### Reset Proxy Statistics

```bash
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s -X POST http://localhost:15000/reset_counters
```

### Check Proxy Readiness and Live Statistics

```bash
# Readiness (used by the kubelet probe)
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s http://localhost:15021/healthz/ready

# General statistics
kubectl exec <pod-name> -n <namespace> -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep -E "upstream_cx|downstream_cx|retry"
```

---

## 7. Performance and Resource Tuning

### Check the Number of Proxies istiod Is Managing

```bash
kubectl exec -n istio-system deploy/istiod -- \
  curl -s http://localhost:8080/debug/endpointz | jq 'length'
```

### Identify Proxies Out of Sync with istiod

```bash
# SYNCED = up to date; STALE = lagging behind xDS push
istioctl proxy-status | grep -v SYNCED
```

### Force an xDS Push to All Proxies

```bash
# Restart istiod — it will re-push full config to all connected proxies
kubectl rollout restart deploy/istiod -n istio-system
```

### Tune Sidecar Scope to Reduce xDS Payload

```bash
# Restrict a workload to only the services it calls
kubectl apply -f - <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: scoped-sidecar
  namespace: <namespace>
spec:
  workloadSelector:
    labels:
      app: <app-label>
  egress:
    - hosts:
        - "./<service-a>.<namespace>.svc.cluster.local"
        - "./<service-b>.<namespace>.svc.cluster.local"
        - "istio-system/*"
EOF
```

---

## 8. Mesh-Wide Configuration

### Inspect the Active MeshConfig

```bash
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | yq .
```

### Change the Default Trace Sampling Rate Mesh-Wide

```bash
kubectl get configmap istio -n istio-system -o json \
  | jq '.data.mesh |= (. | gsub("traceSampling: [0-9.]+"; "traceSampling: 1.0"))' \
  | kubectl apply -f -
# This cluster sets traceSampling via istiod Helm values (pilot.traceSampling: 10.0).
# Prefer editing infrastructure/controllers/istio.yaml and reconciling through Flux.
```

### List All Istio CRDs Installed in the Cluster

```bash
kubectl get crd | grep istio.io
```

### Check Which Istio Version Each Proxy Is Running

```bash
# Mismatched versions between istiod and proxies indicate an incomplete rollout
istioctl proxy-status | awk '{print $5}' | sort | uniq -c | sort -rn
```

---

## 9. Security Auditing

### Identify All Workloads Without a Sidecar

```bash
# Pods missing the istio-proxy container bypass all mTLS and AuthorizationPolicies
kubectl get pods -A -o json \
  | jq -r '.items[] | select(all(.spec.containers[]; .name != "istio-proxy")) | "\(.metadata.namespace)/\(.metadata.name)"' \
  | sort -u
```

### Verify No Service Accepts Plain-Text Traffic Under STRICT Mode

```bash
# Any non-zero result means plain-text traffic is reaching a STRICT-mode workload
kubectl port-forward -n observability svc/observability-kube-prometh-prometheus 9090:9090 &
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(istio_requests_total{connection_security_policy="none"}[5m])) by (destination_service_name)' \
  | jq '.data.result'
```

### Audit JWT / OIDC Authentication Policies

```bash
kubectl get requestauthentication -A
kubectl describe requestauthentication <name> -n <namespace>
```

### Check RBAC Policies Governing Istio Resource Access

```bash
# Who can create or modify AuthorizationPolicies and PeerAuthentications
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name | test("istio")) | "\(.metadata.name): \(.subjects[]?.name)"'
```

---

## 10. Disaster Recovery and Rollback

### Roll Back istiod to the Previous Version via Flux

```bash
# Pin the chart to the previous patch version in infrastructure/controllers/istio.yaml,
# then force Flux to reconcile immediately
flux reconcile helmrelease istiod -n flux-system --with-source

# Monitor the rollout
kubectl rollout status deploy/istiod -n istio-system
```

### Drain a Namespace from the Mesh (Emergency — Removes All Sidecars)

```bash
# Disable injection and restart all pods to drop the sidecars
kubectl label namespace <namespace> istio-injection=disabled --overwrite
kubectl rollout restart deployment -n <namespace>
# All traffic in the namespace will bypass Istio — mTLS and AuthorizationPolicies no longer apply
```

### Verify istiod Recovers After a Restart

```bash
kubectl rollout restart deploy/istiod -n istio-system
kubectl rollout status deploy/istiod -n istio-system

# Watch proxy sync status recover — all proxies should return to SYNCED within ~60s
watch -n 5 "istioctl proxy-status | grep -c SYNCED"
```

### Export the Full Mesh State for Offline Analysis

```bash
# Dump all Istio custom resources to a single file
kubectl get \
  virtualservices,destinationrules,gateways,serviceentries,\
  peerauthentications,authorizationpolicies,requestauthentications,\
  sidecars,telemetries \
  -A -o yaml > istio-mesh-state-$(date +%F).yaml
```
