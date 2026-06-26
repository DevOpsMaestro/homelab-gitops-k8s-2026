# Istio — Daily Administration Reference

Cluster: `flux-kind` · Istio 1.30.2 · istiod in `istio-system`

---

## Health Verification

```bash
# Validate the full installation against the cluster
istioctl verify-install

# Detect misconfigurations, missing injection labels, and port naming issues
istioctl analyze --all-namespaces

# istiod pod status
kubectl get pods -n istio-system

# Confirm all sidecar proxies are synchronised with istiod
istioctl proxy-status
```

---

## Sidecar Injection

```bash
# Enable injection for a namespace
kubectl label namespace <namespace> istio-injection=enabled

# Disable injection for a namespace (explicit — suppresses istioctl analyze warnings)
kubectl label namespace <namespace> istio-injection=disabled

# Inspect injection labels across all namespaces
kubectl get namespaces --show-labels | grep istio-injection

# Restart pods in a namespace to apply injection after enabling it
kubectl rollout restart deployment -n <namespace>
```

---

## Traffic Visibility

```bash
# Display all inbound and outbound listeners on a pod's Envoy proxy
istioctl proxy-config listener <pod-name> -n <namespace>

# Display routes
istioctl proxy-config route <pod-name> -n <namespace>

# Display upstream clusters and their TLS mode
istioctl proxy-config cluster <pod-name> -n <namespace>

# Display TLS certificates loaded on a proxy
istioctl proxy-config secret <pod-name> -n <namespace>
```

---

## Mutual TLS

```bash
# Inspect the effective PeerAuthentication policy for a namespace
kubectl get peerauthentication -n <namespace>

# Inspect cluster-wide PeerAuthentication policies
kubectl get peerauthentication -A

# Confirm mTLS is active on a live connection — x-forwarded-client-cert header indicates mTLS
kubectl exec -n <namespace> deploy/<client> -- \
  curl -s http://<service>.<namespace>.svc.cluster.local/headers | grep -i x-forwarded-client-cert
```

---

## Workload Validation

```bash
# Validate all resources in a namespace for Istio compatibility
kubectl get all -n <namespace> -o yaml | istioctl validate -f -

# Describe the effective configuration Istio applies to a specific pod
istioctl experimental describe pod <pod-name> -n <namespace>
```

---

## Logs

```bash
# istiod control plane logs
kubectl logs -n istio-system deploy/istiod | tail -50

# Enable debug logging on a specific proxy (resets on pod restart)
istioctl proxy-config log <pod-name> -n <namespace> --level debug

# View proxy logs
kubectl logs <pod-name> -n <namespace> -c istio-proxy | tail -50
```

---

## Flux Reconciliation

```bash
# Monitor all Flux resources including Istio HelmReleases
watch -n 6 "flux get all -A"

# Force immediate reconciliation of Istio
flux reconcile helmrelease istio-base -n flux-system
flux reconcile helmrelease istiod -n flux-system
```
