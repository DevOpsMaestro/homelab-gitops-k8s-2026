# Post-Quantum Cryptography Readiness

This document inventories every cryptographic primitive in use in this cluster, maps each
one to the relevant NIST post-quantum standard, and gives an honest verdict on what can
be changed today vs. what requires waiting for upstream tool support.

**Bottom line:** No component in this cluster can be switched to a NIST PQC algorithm
today without losing compatibility. Every relevant tool — Istio, cert-manager, Age/SOPS,
and Contour's Envoy data plane — lacks stable PQC support. The value of this document is a
clear inventory of what to watch and what to change when tool support arrives.

---

## The Three NIST PQC Standards (Finalized August 2024)

| Standard | Former Name | Type | Replaces | Purpose |
|---|---|---|---|---|
| **FIPS 203 — ML-KEM** | CRYSTALS-Kyber | Key Encapsulation Mechanism | ECDH / X25519 / RSA-OAEP | Encrypting session keys, key exchange |
| **FIPS 204 — ML-DSA** | CRYSTALS-Dilithium | Digital Signature | ECDSA / RSA-PSS | Signing and verifying identity |
| **FIPS 205 — SLH-DSA** | Sphincs+ | Digital Signature | ECDSA / RSA-PSS | Backup signature scheme; uses hash-based math rather than lattices |

NIST recommends beginning migration planning immediately. Full integration is expected to
take years as toolchains, libraries, and protocols add support.

**Note on symmetric encryption:** AES-256, ChaCha20-Poly1305, and other 256-bit symmetric
ciphers are already considered quantum-safe. Grover's algorithm halves the effective key
strength, reducing 256-bit security to ~128-bit — still adequate. Symmetric crypto is not
the threat model PQC addresses; the risk is in asymmetric key exchange and digital signatures.

---

## Cryptographic Inventory

### 1. SOPS + Age (Secret Encryption at Rest)

**Config:** `.sops.yaml` · **Docs:** `docs/sops-age-secrets.md`

Age uses a two-step approach:
- **X25519** for key encapsulation (key agreement between sender and recipient)
- **ChaCha20-Poly1305** for symmetric encryption of the actual secret payload

**What's at risk:** X25519 key exchange is vulnerable to Shor's algorithm on a sufficiently
large quantum computer. The ChaCha20-Poly1305 symmetric layer is quantum-safe.

**PQC replacement:** ML-KEM (FIPS 203) to replace the X25519 key encapsulation step.
A hybrid approach (X25519 + ML-KEM) would protect against both classical and quantum
attacks simultaneously.

**Feasible today?** ❌ No. The Age specification only defines X25519 as a recipient type.
The Age community has open discussions about an ML-KEM hybrid mode, but no implementation
has been released. SOPS would need to ship a new `age` provider for it.

---

### 2. Istio mTLS — Workload Certificate PKI

**Config:** `apps/base/istio/peerauthentication.yaml` · `infrastructure/controllers/istio.yaml`

Istio's internal CA (Citadel) automatically issues X.509 certificates to every
sidecar-injected pod. Certificates rotate every 24 hours by default.

- Default key algorithm: **ECDSA P-256** (Istio 1.22+ default)
- STRICT mTLS enforced in the `observability` and `demo` namespaces
- PERMISSIVE mode mesh-wide (pods without sidecars can still communicate)

**What's at risk:** ECDSA P-256 digital signatures are broken by Shor's algorithm.

**PQC replacement:** ML-DSA (FIPS 204) for the signatures on workload certificates.

**Feasible today?** ❌ No.
- Istio 1.30 has no configuration option to change the Citadel CA key algorithm.
- Replacing Citadel with cert-manager as the Istio CA (via `pilot.ca: privateca`) would
  allow custom certificate issuance — but cert-manager 1.20 also has no PQC key type support.
- This is the highest-impact cryptographic surface area in the cluster and the most important
  one to revisit as Istio and cert-manager add PQC support.

---

### 3. cert-manager (Installed, No Active Issuers)

**Config:** `infrastructure/controllers/cert-manager.yaml` — version v1.20.2

cert-manager is installed as an Istio dependency. No `Certificate`, `Issuer`, or
`ClusterIssuer` CRDs are deployed — it is not currently issuing any certificates.

**PQC replacement:** When cert-manager is used to issue certificates in the future,
ML-DSA keys would be specified via `spec.privateKey.algorithm: ML-DSA` in the Certificate
CRD (once that field is supported).

**Feasible today?** ❌ No. cert-manager has no PQC algorithm support. The project is
aware of the need; no release date is set.

---

### 4. Contour — HTTP Ingress

**Config:** `infrastructure/controllers/contour.yaml` · `apps/base/contour/httproxy.yaml`

Contour is the sole HTTP ingress controller. It manages its own Envoy DaemonSet via xDS and routes traffic to Grafana, Prometheus, and the httpbin demonstration workload. The listener is plain HTTP (port 80). No TLS is configured at the ingress layer.

**What's at risk:** Nothing currently — there is no TLS handshake to attack at the ingress layer.

**Future consideration:** When HTTPS is added, both the certificate key algorithm and the TLS handshake key exchange will require PQC-capable variants. Contour's Envoy data plane uses BoringSSL, which added experimental hybrid support (`X25519Kyber768Draft00`) in some builds, but Contour does not expose this through its `HTTPProxy` or `TLSCertificateDelegation` API surface in any stable release.

**Recommendation:** When HTTPS support is added to this cluster, design it PQC-ready from the start rather than retrofitting. The relevant Contour feature to watch is support for custom TLS cipher suites in `HTTPProxy.spec.virtualhost.tls`.

---

### 5. OpenTelemetry Collector → Tempo (gRPC)

**Config:** `apps/base/opentelemetry/helmrelease.yaml`

TLS is explicitly disabled (`tls.insecure: true`). All traffic is in-cluster only.

**Feasible today?** N/A — no cryptographic negotiation occurs on this path.

---

### 6. Cilium Hubble PKI

**Config:** `infrastructure/controllers/cilium.yaml`

Cilium generates its own internal PKI for Hubble relay TLS, stored in the `cilium-secrets`
namespace. The key algorithm is not explicitly configured in the Helm values — Cilium uses
its own built-in certificate generator (RSA or ECDSA, version-dependent).

**Feasible today?** ❌ No. Cilium has no PQC certificate support in any current release.

---

## Summary

| Component | Algorithm at Risk | NIST PQC Replacement | Changeable Today? |
|---|---|---|---|
| SOPS + Age | X25519 key encapsulation | ML-KEM (FIPS 203) | ❌ No |
| Istio mTLS workload certs | ECDSA P-256 | ML-DSA (FIPS 204) | ❌ No |
| cert-manager (future issuers) | ECDSA / RSA | ML-DSA (FIPS 204) | ❌ No |
| Contour (Envoy data plane) | None (HTTP only, no TLS at ingress) | ML-KEM (FIPS 203) when HTTPS added | N/A |
| OTel → Tempo gRPC | None (TLS disabled) | N/A | N/A |
| Cilium Hubble PKI | ECDSA / RSA (default) | ML-DSA (FIPS 204) | ❌ No |

---

## Automated Monitoring

The `Post Quantum Computing` GitHub Actions workflow (`.github/workflows/pqc-watch.yaml`) runs on a weekly schedule. It checks whether Age, Istio, cert-manager, Envoy, and Cilium have shipped PQC support, and creates or updates a GitHub issue in this repository summarizing the findings. When the issue shows a tool has added support, return to the relevant section in this document and proceed with the upgrade steps.

---

## Roadmap — What to Watch

| Tool | What to Wait For |
|---|---|
| **Age / SOPS** | Age spec adds ML-KEM hybrid recipient type; SOPS ships updated `age` provider |
| **Istio** | Citadel CA adds configurable key algorithm, or stable cert-manager PQC integration |
| **cert-manager** | `spec.privateKey.algorithm: ML-DSA` added to the Certificate CRD |
| **Contour** | Custom TLS cipher suite support in `HTTPProxy.spec.virtualhost.tls` — stable BoringSSL PQC cipher suites in the Envoy data plane |
| **Cilium** | Hubble PKI generator adds configurable key algorithm |

---

## References

- [Overview of Post Quantum Cryptography](https://en.wikipedia.org/wiki/Post-quantum_cryptography)
- [NIST Releases First 3 Finalized Post-Quantum Encryption Standards (August 2024)](https://www.nist.gov/news-events/news/2024/08/nist-releases-first-3-finalized-post-quantum-encryption-standards)
- [FIPS 203 — ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [FIPS 204 — ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)
- [FIPS 205 — SLH-DSA](https://csrc.nist.gov/pubs/fips/205/final)
