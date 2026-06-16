# Trivy Operator — Vulnerability & Security Scanning

Cluster: `flux-kind` · Operator namespace: `trivy-system` · Chart: `0.33.1` · App: `0.31.1` · Config: `infrastructure/controllers/trivy.yaml`

---

## What Trivy Operator Does

Trivy Operator is an in-cluster security scanner from Aqua Security. It watches every workload in the cluster and automatically runs vulnerability and configuration checks without any manual intervention. Results are stored as Kubernetes custom resources (CRDs) — they live alongside the workloads they describe and are readable with standard `kubectl` commands.

**It does four things:**

1. **Image vulnerability scanning** — pulls each container image, extracts its package list, and cross-references it against the Trivy vulnerability database (CVEs from NVD, GitHub Advisories, OS vendor feeds). Results appear as `VulnerabilityReport` CRDs.

2. **Configuration auditing** — checks every Kubernetes resource (Deployments, DaemonSets, NetworkPolicies, RBAC roles, etc.) against NSA/CISA hardening guidelines and CIS benchmarks. Results appear as `ConfigAuditReport` CRDs.

3. **RBAC assessment** — checks `Role` and `ClusterRole` bindings for excessive permissions. Results appear as `RbacAssessmentReport` CRDs.

4. **Exposed secret scanning** — scans image layers for accidentally embedded credentials, API keys, and certificates. Results appear as `ExposedSecretReport` CRDs.

### How It Works in This Cluster

This cluster runs Trivy Operator in **ClientServer mode** with a built-in Trivy DB server (`trivy-server-0` pod in `trivy-system`). The server pod downloads and maintains the vulnerability database once. Ephemeral scan Job pods connect to it as lightweight clients — they extract image layers locally and query the server for CVE lookups rather than each downloading the full database independently.

```
[Trivy Operator] ──watches──▶ workload changes
                 ──creates──▶ scan Job pods
                               │
                               └──connects──▶ [trivy-server-0] (CVE DB)
                                              (port 4954, trivy-system)
                 ──writes──▶ VulnerabilityReport / ConfigAuditReport / etc.
```

Scan reports refresh every **24 hours** (`OPERATOR_SCANNER_REPORT_TTL: 24h`). A new report is also triggered immediately whenever a workload's image changes.

Only CVEs that have a fix available are reported (`ignoreUnfixed: true`) — unfixed CVEs are suppressed to keep reports actionable.

---

## Report Types at a Glance

| CRD | Short name | Scope | What it covers |
|---|---|---|---|
| `vulnerabilityreports` | `vuln` | Namespaced | CVEs in container image packages |
| `configauditreports` | `configaudit` | Namespaced | Kubernetes resource misconfigurations |
| `rbacassessmentreports` | `rbacassessment` | Namespaced | Overly permissive RBAC bindings |
| `exposedsecretreports` | `exposedsecret` | Namespaced | Credentials embedded in image layers |
| `clustervulnerabilityreports` | — | Cluster-wide | Aggregated vuln view across all namespaces |
| `clustercompliancereports` | — | Cluster-wide | NSA/CISA and CIS benchmark compliance |

---

## Listing Reports

### All vulnerability reports across the cluster

```bash
kubectl get vulnerabilityreports -A
```

### Filter to one namespace

```bash
kubectl get vulnerabilityreports -n observability
kubectl get configauditreports -n kube-system
```

### Count by type

```bash
kubectl get vulnerabilityreports -A --no-headers | wc -l
kubectl get configauditreports   -A --no-headers | wc -l
kubectl get rbacassessmentreports -A --no-headers | wc -l
kubectl get exposedsecretreports  -A --no-headers | wc -l
```

### Check operator and server health

```bash
kubectl get pods -n trivy-system
# Expected: trivy-server-0 (Running) + trivy-system-trivy-operator-* (Running)
```

---

## Reading a Vulnerability Report

### Summary view (severities at a glance)

```bash
kubectl get vulnerabilityreport daemonset-cilium-cilium-agent -n kube-system \
  -o jsonpath='{.report.summary}'
```

Output:
```json
{"criticalCount":0,"highCount":5,"lowCount":12,"mediumCount":8,"noneCount":0,"unknownCount":0}
```

### All vulnerabilities in a report

```bash
kubectl get vulnerabilityreport daemonset-cilium-cilium-agent -n kube-system \
  -o jsonpath='{range .report.vulnerabilities[*]}{.severity}{"\t"}{.vulnerabilityID}{"\t"}{.resource}{"\t"}{.installedVersion}{" -> "}{.fixedVersion}{"\n"}{end}'
```

### Filter to HIGH and CRITICAL only

```bash
kubectl get vulnerabilityreport daemonset-cilium-cilium-agent -n kube-system \
  -o json | \
  jq '.report.vulnerabilities[] | select(.severity=="HIGH" or .severity=="CRITICAL") |
    {id: .vulnerabilityID, pkg: .resource, installed: .installedVersion, fixed: .fixedVersion, score: .score}'
```

### All HIGH/CRITICAL across every namespace

```bash
kubectl get vulnerabilityreports -A -o json | \
  jq '[.items[] | {
    namespace: .metadata.namespace,
    workload:  .metadata.name,
    image:     .report.artifact.tag,
    vulns: [.report.vulnerabilities[] |
      select(.severity=="HIGH" or .severity=="CRITICAL") |
      {id: .vulnerabilityID, pkg: .resource, fixed: .fixedVersion}
    ]
  } | select(.vulns | length > 0)]'
```

### Export all vulnerability reports to a single JSON file

```bash
kubectl get vulnerabilityreports -A -o json > vuln-reports-$(date +%F).json
```

---

## Reading a Config Audit Report

Config audit reports cover Kubernetes resource hardening — missing resource limits, privilege escalation settings, seccomp profiles, and so on.

### Failed checks only

```bash
kubectl get configauditreport daemonset-cilium -n kube-system \
  -o json | \
  jq '.report.checks[] | select(.success == false) |
    {severity: .severity, id: .checkID, title: .title, remediation: .remediation}'
```

### Count failures by severity across the cluster

```bash
kubectl get configauditreports -A -o json | \
  jq '[.items[].report.checks[] | select(.success == false) | .severity] |
    group_by(.) | map({severity: .[0], count: length}) | sort_by(.count) | reverse'
```

### Export all config audit reports

```bash
kubectl get configauditreports -A -o json > configaudit-reports-$(date +%F).json
```

---

## Reading RBAC Assessment Reports

```bash
# List all RBAC findings
kubectl get rbacassessmentreports -A

# Show failed checks for a specific role
kubectl get rbacassessmentreport <name> -n <namespace> \
  -o json | jq '.report.checks[] | select(.success == false)'
```

---

## Reading Exposed Secret Reports

```bash
# List all reports (a non-zero count in the CRITICAL/HIGH column is urgent)
kubectl get exposedsecretreports -A

# Show any detected secrets
kubectl get exposedsecretreports -A -o json | \
  jq '.items[] | select(.report.summary.criticalCount > 0 or .report.summary.highCount > 0) |
    {workload: .metadata.name, namespace: .metadata.namespace, secrets: .report.secrets}'
```

---

## Prometheus Metrics

Trivy Operator exposes metrics on port `8080` in `trivy-system`, scraped by Prometheus via `additionalScrapeConfigs` in `apps/base/prometheus/helmrelease.yaml`.

### Useful PromQL queries

**Total HIGH + CRITICAL CVEs across all images:**
```promql
sum(trivy_image_vulnerabilities{severity=~"High|Critical"})
```

**CVEs broken down by namespace:**
```promql
sum by (namespace, severity) (trivy_image_vulnerabilities{severity=~"High|Critical"})
```

**Images with at least one CRITICAL CVE:**
```promql
trivy_image_vulnerabilities{severity="Critical"} > 0
```

**Config audit failures by namespace:**
```promql
sum by (namespace) (trivy_resource_configaudits{severity=~"HIGH|CRITICAL", result="failed"})
```

### Check metrics are being scraped

```bash
kubectl exec -n trivy-system deploy/trivy-system-trivy-operator -- \
  wget -qO- http://localhost:8080/metrics | grep "^trivy_image_vulnerabilities" | head -5
```

---

## Forcing a Re-scan

Reports are regenerated automatically when an image changes. To force a re-scan of a specific workload, delete its report — the operator recreates it within seconds:

```bash
# Force re-scan of a single workload
kubectl delete vulnerabilityreport daemonset-cilium-cilium-agent -n kube-system

# Force re-scan of everything in a namespace
kubectl delete vulnerabilityreports -n observability --all
```

To force a full cluster re-scan (e.g., after a DB update), restart the operator:

```bash
kubectl rollout restart deployment -n trivy-system
```

---

## Cluster Compliance Report

The operator ships with an NSA hardening benchmark that aggregates findings across the cluster:

```bash
kubectl get clustercompliancereport nsa -o json | \
  jq '.status.summaryReport.controlCheck[] |
    select(.totalFail > 0) |
    {control: .id, name: .name, failed: .totalFail, severity: .severity}'
```

---

## Configuration Reference

| Setting | Value | Location |
|---|---|---|
| Mode | ClientServer (built-in server) | `infrastructure/controllers/trivy.yaml` |
| Ignore unfixed CVEs | `true` | `trivy.ignoreUnfixed` |
| Concurrent scan jobs | `2` | `operator.scanJobsConcurrentLimit` |
| Report TTL | `24h` | `OPERATOR_SCANNER_REPORT_TTL` |
| Metrics port | `:8080` | `operator.metricsBindAddress` |
| DB server | `trivy-server-0.trivy-service:4954` | Auto-configured by operator |
