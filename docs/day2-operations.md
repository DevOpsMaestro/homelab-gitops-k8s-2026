# Day-2 Operations Guide

Cluster: `flux-kind` · KinD 1.36.1 · 1 control-plane + 2 workers

This guide covers the routine tasks an operator performs after the cluster is running. Bootstrap and initial setup are covered in the [README](../README.md). This document addresses ongoing operations: daily health checks, dependency updates via Renovate, security posture review with Kubescape, and secret rotation.

---

## Daily Health Check

Run these commands each day the cluster is active. Proceed to per-technology sections in the [Troubleshooting Guide](troubleshooting-guide.md) only when a specific component requires investigation.

```bash
# 1. All Flux resources — every row must show READY: True
flux get all -A

# 2. Any pod not Running or Completed is a problem
kubectl get pods -A | grep -v "Running\|Completed"

# 3. Node resource usage — watch for sustained high CPU or memory pressure
kubectl top nodes

# 4. Confirm Grafana is reachable (302 = login redirect, indicates healthy stack)
curl -s -o /dev/null -w "%{http_code}" -H "Host: grafana.local" http://localhost:8080/
```

Expected output: all Flux resources `READY: True`, no pods stuck, nodes show reasonable CPU and memory, Grafana returns `302`.

### Reading the Grafana Health Dashboard

Open `http://grafana.local:8080` and navigate to **Dashboards → Node Exporter Full**. Check:

- **CPU busy** — should remain below 80% during idle periods; BOINC will push it higher during active compute, which is expected.
- **Memory available** — a downward trend that does not recover indicates a memory leak; investigate `kubectl top pods -A --sort-by=memory`.
- **Disk I/O** — Loki and Prometheus write continuously to PVCs; spikes are normal, but sustained high rates may indicate excessive log volume.

### Reading Flux Reconciliation State

```bash
flux get all -A
```

| Status | Meaning |
|--------|---------|
| `READY: True` | The cluster matches the Git state for this resource. |
| `READY: False` + `RECONCILING` | Flux is actively applying a change. Wait 30–60 seconds and re-check. |
| `READY: False` + error message | A failure occurred. Read the message and consult the [Troubleshooting Guide](troubleshooting-guide.md). |

A common cause of `READY: False` after a push is a transient network error fetching a Helm chart. Force a retry:

```bash
flux reconcile source git flux-system -n flux-system
```

---

## Handling Renovate Pull Requests

Renovate opens pull requests automatically when it detects newer versions of Helm charts, container images, GitHub Actions, and CLI tool pins.

### Triage Workflow

```bash
# List all open Renovate PRs
gh pr list --label "renovate"
```

For each open PR:

1. **Read the PR description.** Renovate includes the changelog, the time since the new version was published, and the adoption rate among other users. A version published hours ago with low adoption warrants more caution than one published months ago with wide adoption.

2. **Check CI.** The `validate` workflow must pass before merging. If CI fails on a Renovate PR, investigate the kustomize build or Kyverno test output — the new version may have introduced a breaking change.

3. **Merge or defer.** Patch image updates and GitHub Actions updates are configured to automerge after CI passes. Flux minor updates (chart constraint bumps) require human review. Infrastructure pins (`CILIUM_VERSION`, `ISTIO_VERSION`, `K8S_VER`) require a cluster rebuild to take effect — plan accordingly.

### After Merging

Flux reconciles within one minute of the merge reaching `main`. Monitor:

```bash
watch -n 6 "flux get helmreleases -A"
```

If a chart upgrade fails, the HelmRelease enters a failed state with an error message. Force a retry after investigating:

```bash
flux reconcile helmrelease <name> -n flux-system
```

### Rolling Back a Bad Merge

```bash
# Find the merge commit
git log --oneline -10

# Revert it (creates a new commit — safe for a shared branch)
git revert <merge-commit-sha>
git push origin main

# Force Flux to reconcile immediately
flux reconcile source git flux-system -n flux-system
```

---

## Reviewing Kubescape Security Scores

Kubescape continuously scans the cluster against the NSA Kubernetes Hardening Guide and MITRE ATT&CK framework. Results are exposed as Prometheus metrics and visible in Grafana.

### Grafana Dashboard

Open `http://grafana.local:8080`, navigate to **Dashboards → Kubescape Security Posture**. The dashboard shows:

- **Compliance score** — percentage of controls passing per framework. A declining score indicates a new workload or configuration that violates a control.
- **Control failures by resource** — which specific Kubernetes resources are failing which controls.
- **Historical trend** — whether the score is improving, stable, or declining over time.

### CLI Review

```bash
# On-demand scan against the live cluster (NSA + MITRE)
make test-kubescape

# Or run directly for verbose output
kubescape scan framework nsa,mitre \
  --cluster-context "kind-flux-kind" \
  --format pretty-printer \
  --verbose
```

### Interpreting Findings

Before investigating a finding, consult [docs/kubescape-security.md](kubescape-security.md). That document records findings that have been reviewed and formally accepted as intentional design decisions. If a finding is already listed there, no further action is required.

For a new finding:

1. Identify the affected resource:
   ```bash
   kubectl get workloadconfigurationscans -A | grep <control-id>
   ```
2. Determine whether the finding represents a real risk or an accepted trade-off for this environment.
3. If accepted: add an entry to [docs/kubescape-security.md](kubescape-security.md) with the control ID, the affected resource, and the rationale.
4. If remediated: fix the configuration in the appropriate manifest and open a PR.

```bash
# View scan results as CRDs
kubectl get configurationscansummaries -A
kubectl get workloadconfigurationscans -A
```

---

## Rotating Secrets

### Grafana Admin Password

The Grafana admin password is stored in `apps/base/grafana/admin-secret.yaml` (SOPS-encrypted) and sourced into the HelmRelease via `valuesFrom`. To change it:

```bash
# Open the decrypted YAML in $EDITOR — re-encrypts on save
sops apps/base/grafana/admin-secret.yaml
```

Edit the `admin-password` value, save, and quit. Commit and push. Flux will apply the updated Secret on the next reconcile. Grafana picks up the new password automatically on pod restart:

```bash
kubectl rollout restart deployment -n observability observability-grafana
```

### Grafana `secret_key`

The `grafana-secret-key` Secret stores the key Grafana uses to encrypt datasource credentials and sign user sessions. Rotating this key invalidates all active browser sessions and forces a re-entry of datasource passwords. Perform rotation only when required (e.g., suspected key exposure).

```bash
# Generate a new key and apply it to the running cluster
kubectl create secret generic grafana-secret-key \
  --namespace observability \
  --from-literal=secret-key="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Grafana to load the new key
kubectl rollout restart deployment -n observability observability-grafana
```

Note: The bootstrap script recreates this Secret automatically on every `make bootstrap`. Manual rotation is needed only on a running cluster.

### SOPS Age Key

The SOPS age private key encrypts every Secret in this repository. Rotate it only in case of suspected compromise.

1. Generate a new key pair:
   ```bash
   age-keygen -o ~/.config/sops/age/keys-new.txt
   ```
2. Update `.sops.yaml` with the new public key.
3. Re-encrypt every `*-secret.yaml` file:
   ```bash
   for f in $(find apps/base -name '*-secret.yaml'); do
     sops --rotate --in-place "$f"
   done
   ```
4. Load the new key into the cluster:
   ```bash
   make sops-load-key
   ```
5. Commit and push.

### BOINC Project Credentials

Project authenticator keys are stored in `apps/base/boinc/boinc-projects-secret.yaml` (SOPS-encrypted). To update:

```bash
sops apps/base/boinc/boinc-projects-secret.yaml
```

Edit the authenticator key for the affected project, save, commit, push, then restart the DaemonSet:

```bash
kubectl rollout restart daemonset/boinc -n boinc
```

---

## Checking Cluster After Mac Wakes from Sleep

Docker Desktop pauses its Linux VM when the Mac sleeps. Istio issues 24-hour workload certificates to each Envoy sidecar; if the VM is paused through the rotation window (~19 h), sidecars will present expired certificates until restarted.

**Symptom:** Grafana dashboards show TLS errors (`CERTIFICATE_VERIFY_FAILED`).

**Fix:**

```bash
kubectl rollout restart deployment statefulset -n observability
kubectl rollout restart deployment -n demo
```

Allow ~60 seconds for pods to restart and istiod to issue fresh certificates. Verify:

```bash
istioctl proxy-config secret -n observability deploy/observability-grafana | grep default
# VALID CERT should show: true
```

---

## Verifying the Full Ingress Stack

After any change to nginx, Contour, or the cluster network, verify the end-to-end path:

```bash
# HTTP ingress via Contour
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: grafana.local" http://localhost:8080/
# Expected: 302

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: prometheus.local" http://localhost:8080/
# Expected: 200

curl -s -o /dev/null -w "%{http_code}\n" -H "Host: httpbin-contour.local" http://localhost:8080/get
# Expected: 200

# TCP path via nginx stream block (iperf3)
iperf3 -4 -c localhost -p 32111 -t 10
# Expected: ~700–800 Mbits/sec, 0 retransmits
```

---

## Useful One-Liners

```bash
# Count vulnerability reports by severity
kubectl get vulnerabilityreports -A -o json \
  | jq '[.items[].report.summary] | {
      critical: (map(.criticalCount) | add),
      high:     (map(.highCount)     | add),
      medium:   (map(.mediumCount)   | add)
    }'

# Show all non-zero Falco rule matches
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=200 \
  | grep -i 'Critical\|Error'

# Show all BOINC active tasks
POD=$(kubectl get pod -n boinc -l app=boinc -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n boinc $POD -- boinccmd --get_tasks

# Force reconcile all HelmReleases (useful after a Flux upgrade)
flux get helmreleases -n flux-system --no-header \
  | awk '{print $1}' \
  | xargs -I {} flux reconcile helmrelease {} -n flux-system
```
