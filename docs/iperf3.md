# iperf3 — Network Load Testing

Cluster: `flux-kind` · App namespace: `iperf3` · Config: `apps/base/iperf3/`

---

## What iperf3 Does

iperf3 is a network bandwidth measurement tool. It works on a client-server model: a server process listens on a port and waits for a client to initiate a test. When the client connects, both sides exchange data for a fixed duration and report the achieved throughput, along with diagnostics such as retransmit counts and congestion window size.

iperf3 is used in this cluster to measure the sustained TCP bandwidth available through the full ingress path and to verify that the nginx nodeport-proxy stream layer is functional.

---

## Network Path

When a test is initiated from the host Mac, the connection travels through three layers before reaching the iperf3 server process:

```
Mac host (iperf3 client)
  │
  │  localhost:32111  (IPv4 — always use -4 or 127.0.0.1)
  ▼
Docker extraPortMapping
  │  hostPort 32111 → containerPort 9111 (flux-kind-control-plane)
  ▼
nginx nodeport-proxy DaemonSet  (envoy-ingress namespace, hostNetwork: true)
  │  stream { listen 9111; proxy_pass iperf3.iperf3.svc.cluster.local:32111; }
  ▼
iperf3 server pod  (iperf3 namespace, port 32111)
```

iperf3 traffic bypasses all HTTP ingress controllers. The nginx `stream {}` block performs a raw Layer 4 proxy pass directly to the iperf3 ClusterIP Service, without routing through Contour or any other HTTP-aware controller. Contour cannot route plain TCP without TLS (its `TCPProxy` resource requires SNI-based TLS routing).

---

## Why Each Layer Exists

### Port 9111 instead of 32111 on the nginx DaemonSet

Cilium replaces kube-proxy using BPF programs installed in the kernel. Those programs intercept `bind()` calls on the NodePort range (30000–32767), which prevents any userspace process from binding directly to a port in that range. Because the nginx DaemonSet runs with `hostNetwork: true` and must bind a port on the node's network interface, it cannot use any port in the NodePort range.

Port 9111 sits below that range, so nginx binds there without conflict. The KinD cluster's `extraPortMapping` maps `hostPort 32111 → containerPort 9111`, preserving the user-facing port number on the Mac while keeping nginx clear of the NodePort range.

### nginx stream block

KinD has no cloud load-balancer controller, so a `Service` of type `LoadBalancer` remains `Pending` indefinitely. The nginx nodeport-proxy DaemonSet handles all external traffic. Its `http {}` block handles HTTP ingress on port 8888, forwarding to the Contour Envoy DaemonSet (`contour-contour-envoy.contour.svc.cluster.local:80`); its `stream {}` block handles raw TCP on port 9111. The stream block passes connections directly to `iperf3.iperf3.svc.cluster.local:32111` — no HTTP framing is added. iperf3 sends and receives raw TCP, and the stream block passes it through unmodified.

---

## Security Configuration

The `iperf3` namespace is isolated by a `default-deny` NetworkPolicy that blocks all ingress and egress by default. Two additional policies carve out only the paths that the iperf3 server legitimately needs:

| Policy | Allows |
|---|---|
| `allow-dns-egress` | UDP/TCP port 53 to `kube-system` (CoreDNS) |
| `allow-nginx-ingress` | TCP port 32111 from any source on that port |

`allow-nginx-ingress` uses an open-port pattern (no `from:` clause) rather than a namespace selector. nginx runs with `hostNetwork: true`, so its source IP is the node's host IP — outside the pod CIDR range. A namespace-scoped `from:` selector cannot match it. This matches the same open-port pattern used by Contour's own `allow-envoy-http-ingress` policy.

The server pod itself has no privileges:

- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`
- No service account token mounted (`automountServiceAccountToken: false`)
- Resource limits enforced (Kyverno `require-resource-limits` policy)

---

## Running Tests

Always use `-4` or `127.0.0.1` to force IPv4. `localhost` on macOS resolves to `::1` first; Docker only binds on `0.0.0.0`, so the IPv6 attempt returns "Connection refused" immediately.

### Single-stream bandwidth (baseline)

```bash
iperf3 -4 -c localhost -p 32111 -t 30
```

Expected: ~700–800 Mbits/sec sustained, 0 retransmits.

---

## Verifying Path Status

```bash
# iperf3 pod should be 1/1 Running
kubectl get pods -n iperf3

# Service should be ClusterIP with port 32111
kubectl get svc -n iperf3

# NetworkPolicies should include allow-nginx-ingress
kubectl get networkpolicy -n iperf3

# Confirm port 9111 is active on the control-plane node
kubectl exec -n envoy-ingress \
  $(kubectl get pod -n envoy-ingress -l app=nodeport-proxy -o jsonpath='{.items[0].metadata.name}') \
  -- ss -tlnp | grep 9111
```

---

## Configuration Reference

| Resource | File |
|---|---|
| Deployment + container | `apps/base/iperf3/deployment.yaml` |
| ClusterIP Service | `apps/base/iperf3/service.yaml` |
| NetworkPolicies | `apps/base/iperf3/networkpolicies.yaml` |
| nginx stream block | `apps/overlays/kind/istio/nodeport-proxy.yaml` |
| KinD extraPortMapping | `scripts/setup-fluxcd-gitops-kind-multinode.sh` |
