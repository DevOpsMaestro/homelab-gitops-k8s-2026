# BOINC — Distributed Computing

Cluster: `flux-kind` · Image: `boinc/client:arm64v8` · DaemonSet in `boinc` namespace

---

## Overview

BOINC (Berkeley Open Infrastructure for Network Computing) donates idle CPU cycles to scientific research. When the cluster is not under load, BOINC uses spare CPU to run computations and submits results back to project servers over the internet.

This cluster participates in two projects:

| Project | Server | Research Area |
|---------|--------|---------------|
| Rosetta@Home | boinc.bakerlab.org | Protein structure prediction — medical research |
| Einstein@Home | einstein.phys.uwm.edu | Gravitational wave and pulsar detection |

Each project receives an equal share of available CPU time (50/50 split) via equal `resource_share` values in the account XML files.

---

## Architecture

BOINC runs as a DaemonSet — one pod per cluster node — and uses a `hostPath` volume at `/var/lib/boinc` so work-in-progress task checkpoints survive pod restarts.

### Why hostPath Instead of a PVC

BOINC continuously writes checkpoint files and commits them with atomic `rename()` syscalls. Kubernetes Secret `subPath` mounts create read-only bind mounts that the `rename()` syscall cannot move files over (`EBUSY`). The `hostPath` volume is writable and avoids this limitation entirely.

### initContainer Pattern for Credentials

Project credentials are stored in a SOPS-encrypted Secret (`boinc-projects-secret`). At pod startup, a `busybox` initContainer copies the account XML files from the Secret volume to the writable `hostPath` directory using `cp -n` (no-clobber):

- **First start** — files do not exist on the host. `cp -n` copies them. BOINC reads them on startup and attaches to both projects.
- **Restart** — files already exist from the previous run. `cp -n` skips them. BOINC preserves its full project state, including task progress and downloaded work units.

### Network Policy

The `boinc` namespace uses a **default-deny** NetworkPolicy that blocks all ingress and all egress by default. A second policy then permits only the traffic BOINC actually requires:

| Direction | Port | Purpose |
|-----------|------|---------|
| Egress | 53 UDP/TCP | DNS resolution |
| Egress | 80, 443 TCP | BOINC project server communication |

No ingress is allowed. BOINC is a pure compute client — it connects outward to project servers and never accepts inbound connections. The Cilium CNI enforces both policies using eBPF.

Source file: [apps/base/boinc/netpol.yaml](../apps/base/boinc/netpol.yaml)

### CPU Limit and Thermal Management

The DaemonSet is capped at `950m` (0.95 CPU cores out of 10 on the M5 chip). On the passively cooled MacBook Air M5, this keeps peak core temperatures below 65°C. Raising the limit above 1500m pushes cores to 74°C+, which is within Apple Silicon's safe operating range but above the thermal target for this cluster.

---

## Status Commands

```bash
# Pod status — one pod per node, all should be Running
kubectl get pods -n boinc -o wide

# Watch BOINC startup and project attach messages
kubectl logs -n boinc -l app=boinc --tail=50

# Confirm both projects attached
kubectl logs -n boinc -l app=boinc --tail=100 | grep -iE "attach|project|account"

# Store a pod name for exec commands
POD=$(kubectl get pod -n boinc -l app=boinc -o jsonpath='{.items[0].metadata.name}')

# Check project status via boinccmd
kubectl exec -n boinc $POD -- boinccmd --get_project_status

# Check active work units
kubectl exec -n boinc $POD -- boinccmd --get_tasks

# Check CPU and memory usage as BOINC sees it
kubectl exec -n boinc $POD -- boinccmd --get_host_info
```

Expected output from `--get_project_status`: two projects listed with URLs `https://boinc.bakerlab.org/rosetta/` and `https://einstein.phys.uwm.edu/`.

---

## Updating Project Credentials

Credentials are stored in `apps/base/boinc/boinc-projects-secret.yaml` (SOPS-encrypted). The Secret contains three keys:

| Key | Contents |
|-----|----------|
| `gui-rpc-password` | Local RPC password used by `boinccmd` |
| `account_boinc.bakerlab.org_rosetta.xml` | Rosetta@Home account XML with authenticator key |
| `account_einstein.phys.uwm.edu.xml` | Einstein@Home account XML with authenticator key |

To update a credential:

```bash
# Opens the decrypted YAML in $EDITOR — re-encrypts automatically on save
sops apps/base/boinc/boinc-projects-secret.yaml
```

After saving, commit and push. Flux will reconcile the updated Secret. Restart the DaemonSet to apply the new credentials immediately:

```bash
kubectl rollout restart daemonset/boinc -n boinc
```

The weak account key is available from the project website: account settings → look for "account key" or "weak account key".

---

## Adding a New BOINC Project

1. Locate the project's BOINC URL and log in to the project website.
2. Copy the **weak account key** from account settings.
3. Edit the Secret:
   ```bash
   sops apps/base/boinc/boinc-projects-secret.yaml
   ```
   Add a `stringData` key named `account_<project-hostname>.xml`:
   ```yaml
   account_setiathome.example.edu.xml: |
     <account>
       <master_url>https://setiathome.example.edu/</master_url>
       <authenticator>YOUR_WEAK_KEY_HERE</authenticator>
       <project_preferences>
         <resource_share>100</resource_share>
       </project_preferences>
     </account>
   ```
4. Add a matching `cp -n` line in the initContainer command in `apps/base/boinc/daemonset.yaml`:
   ```sh
   cp -n /boinc-account-init/account_setiathome.example.edu.xml \
          /var/lib/boinc/account_setiathome.example.edu.xml
   ```
5. Commit, push, and restart the DaemonSet:
   ```bash
   kubectl rollout restart daemonset/boinc -n boinc
   ```

---

## Troubleshooting

### BOINC Not Attached to a Project

```bash
# Verify the initContainer completed (Status should show Terminated with exit code 0)
kubectl describe pod -n boinc <pod-name> | grep -A 15 "Init Containers:"

# Verify account files were copied to the hostPath volume
kubectl exec -n boinc $POD -- ls -la /var/lib/boinc/account_*.xml

# Check BOINC logs for authentication errors
kubectl logs -n boinc $POD | grep -iE "error|failed|invalid|authenticator"
```

The most common cause is an incorrect authenticator key in the Secret. Fix with `sops`, commit, push, and `kubectl rollout restart daemonset/boinc -n boinc`.

### High CPU Temperatures

BOINC uses its full limit (950m) whenever work units are available. If temperatures are consistently above 65°C, lower the CPU limit in [apps/base/boinc/daemonset.yaml](../apps/base/boinc/daemonset.yaml):

```yaml
limits:
  cpu: 750m   # down from 950m
```

Alternatively, set CPU usage preferences on the BOINC project website: account settings → computing preferences → "Use at most X% of CPU time".

### initContainer Stuck or Failed

```bash
kubectl logs -n boinc <pod-name> -c boinc-account-init
```

If the initContainer cannot find the Secret volume, Flux has not yet decrypted `boinc-projects-secret`. Verify:

```bash
kubectl get secret boinc-projects-secret -n boinc
```

If the Secret is missing, check the `apps` Kustomization for SOPS decryption errors:

```bash
flux get kustomization apps -n flux-system
kubectl describe kustomization apps -n flux-system | grep -A 10 "Status:"
```

See [docs/sops-age-secrets.md](sops-age-secrets.md) for the complete SOPS troubleshooting procedure.

### Understanding hostPID

The BOINC DaemonSet sets `hostPID: true`. This allows BOINC to observe host-level process IDs, which it requires to accurately account for CPU time consumed by its compute work unit processes (which spawn as child processes). Without `hostPID`, BOINC's internal CPU accounting would be inaccurate and throttling would not function correctly.

The Kubernetes resource limit (`1000m`) is enforced by the container runtime via cgroups regardless of BOINC's internal accounting, so the thermal ceiling holds either way. `hostPID` affects only BOINC's visibility, not its actual resource consumption.
