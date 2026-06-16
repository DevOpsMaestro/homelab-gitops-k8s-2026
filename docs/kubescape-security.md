# Kubescape Security Findings — Accepted Risks

This document records Kubescape scan findings that have been reviewed and formally accepted as intentional design decisions or third-party constraints. Each entry specifies the control identifier, the affected resource, and the rationale for acceptance in lieu of remediation.

---

## Accepted Findings — 2026-05-27

### Finding 1: Secrets Stored in Environment Variables (CIS-4.4.1)

**Control:** Secrets stored in environment variables
**Framework:** CIS Kubernetes Benchmark 4.4.1
**Affected resource:** `Deployment/grafana` in namespace `observability`
**Severity:** Medium

**Description:**
The Grafana Helm chart injects the admin password into the pod via the `GF_SECURITY_ADMIN_PASSWORD` environment variable. This is an internal chart behavior triggered by the `adminPassword` values key and cannot be modified without forking the upstream chart.

**Rationale for acceptance:**
- The secret value is sourced from a Kubernetes `Secret` object (`grafana-admin-secret`) via Flux's `valuesFrom` mechanism, not hardcoded in any manifest.
- The credential (`changeme`) is a placeholder for a local KinD development cluster with no external network exposure.
- Remediation would require overriding unsupported chart internals or switching to a volume-mounted secret approach, which the Grafana chart does not natively support for admin credentials.
- Risk is contained to the `observability` namespace within a non-production environment.

**Acceptable mitigation:** The credential is stored as a Kubernetes `Secret` object rather than in plaintext within a ConfigMap or YAML manifest. A `ClusterSecurityException` CR may be introduced to suppress this finding in future automated scans once the Kubescape operator exception API is confirmed stable for the deployed version.

---

### Finding 2: Workload Exposed to Internet via Gateway API

**Control:** Exposure to internet via load balancer / Gateway API
**Framework:** NSA Kubernetes Hardening Guide
**Affected resources:** HTTPRoutes in namespace `demo` (httpbin), `observability` (Grafana, Prometheus)
**Severity:** Medium

**Description:**
Kubescape flags workloads whose traffic is routed through a Gateway API `HTTPRoute` as potentially exposed to external networks. The cluster's Envoy Gateway `GatewayClass` presents an externally-reachable listener, and HTTPRoutes for Grafana, Prometheus, and the httpbin demonstration application are attached to it.

**Rationale for acceptance:**
- The exposure is intentional. The KinD cluster is accessible only from `localhost` via `extraPortMappings` in the node configuration. No public IP address or cloud load balancer is involved.
- The effective exposure boundary is `localhost:8080` on the developer's workstation; no external network interface is reachable.
- The httpbin deployment exists solely as a demonstration workload for generating observable traffic through the Istio service mesh.
- Access to Grafana and Prometheus is restricted to the developer's local machine by the KinD port-mapping configuration.

**Acceptable mitigation:** The cluster topology (KinD with `extraPortMappings` bound to localhost) prevents any external network exposure. A `ClusterSecurityException` CR may be introduced to suppress this finding in automated scans once the exception API is confirmed stable for the deployed version of the Kubescape operator.
