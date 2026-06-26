# SOPS + Age Secrets Management

Cluster: `flux-kind` · GitOps secrets encrypted with [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age)

---

## Overview

SOPS (Secrets OPerationS) encrypts Kubernetes Secret manifests before they are committed to Git. Age is the encryption backend — a modern replacement for GPG with a simpler key format.

**Trust boundary:**

| What | Where It Lives | Safe to Make Public? |
|------|---------------|----------------------|
| Age public key | `.sops.yaml` (committed to repo) | Yes — used only to encrypt |
| Age private key | `~/.config/sops/age/keys.txt` on the local machine + `sops-age` secret in the cluster | No — guards decryption |
| Encrypted secret YAML | Git / GitHub | Yes — unreadable without the private key |
| Cleartext secret YAML | Never on disk, never in Git | — |

Flux's `kustomize-controller` reads the `sops-age` secret from the cluster at reconciliation time and decrypts the YAML **in memory** before applying it to the API server. Cleartext values never touch the filesystem or the Git history.

---

## Prerequisites

```bash
brew install age sops

# Verify both are available
make check-tools
```

---

## One-Time Setup

### 1. Generate the Age Key Pair

```bash
make sops-setup
```

This creates `~/.config/sops/age/keys.txt` containing both the public and private key. The command is idempotent — it skips generation if the file already exists and prints the public key.

Example output:
```
Public key: age1abc123...xyz
```

### 2. Back Up the Private Key Immediately

Store the entire contents of `~/.config/sops/age/keys.txt` in a password manager (1Password, Bitwarden, etc.) before proceeding.

**If the private key is lost, every SOPS-encrypted secret in this repository becomes permanently unreadable.** There is no recovery path. The backup must be completed before the key encrypts anything.

### 3. Configure `.sops.yaml` with the Public Key

Open `.sops.yaml` at the repository root and replace the placeholder:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: apps/base/.*-secret\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1REPLACEME   ← replace this with the public key from step 1
```

The `path_regex` rule matches any `*-secret.yaml` file under `apps/base/` — the naming convention for secrets in this project. `encrypted_regex` restricts encryption to the `data` and `stringData` fields, so `kind`, `metadata`, and `apiVersion` remain readable in Git.

Commit the updated `.sops.yaml` — the public key is safe to be public:

```bash
git add .sops.yaml
git commit -m "chore(sops): set age public key"
```

### 4. Load the Private Key into the Running Cluster

```bash
make sops-load-key
```

This creates the `sops-age` secret in the `flux-system` namespace. The command is idempotent — safe to re-run after every `make bootstrap`.

Verify it was created:

```bash
kubectl get secret sops-age -n flux-system
```

---

## Encrypt the Existing Grafana Admin Secret

`apps/base/grafana/admin-secret.yaml` initially contains a plaintext password. Encrypt it:

```bash
sops --encrypt --in-place apps/base/grafana/admin-secret.yaml
```

The file is transformed from:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-secret
  namespace: flux-system
type: Opaque
stringData:
  admin-password: "changeme"
```

to:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-secret
  namespace: flux-system
type: Opaque
stringData:
  admin-password: ENC[AES256_GCM,data:abc123...,type:str]
sops:
  age:
    - recipient: age1abc123...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

The `sops:` block is metadata SOPS uses to identify the encryption key. The `stringData.admin-password` field is ciphertext.

Commit and push:

```bash
git add apps/base/grafana/admin-secret.yaml
git commit -m "feat(secrets): encrypt grafana admin secret with SOPS"
git push
```

---

## Verify Flux Decrypts It

After pushing, trigger a reconciliation:

```bash
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source
```

Confirm the secret was decrypted and applied to the cluster:

```bash
kubectl get secret grafana-admin-secret -n flux-system
kubectl get secret grafana-admin-secret -n flux-system \
  -o jsonpath='{.data.admin-password}' | base64 -d
# expected: changeme
```

Confirm Grafana is operational:

```bash
curl -s http://grafana.local:8080/api/health | python3 -m json.tool
# expected: "database": "ok"
```

---

## Day-to-Day: Editing an Existing Encrypted Secret

SOPS opens the decrypted file in `$EDITOR` and re-encrypts transparently on save:

```bash
sops apps/base/grafana/admin-secret.yaml
```

Change the value, save, and quit. SOPS writes the re-encrypted file back to disk. Commit and push — the new ciphertext is the only thing that changes in Git.

---

## Day-to-Day: Adding a New Secret

Follow the `*-secret.yaml` naming convention so `.sops.yaml`'s `path_regex` matches automatically.

1. Create the cleartext manifest:

```bash
cat > apps/base/my-app/my-app-secret.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
  namespace: my-namespace
type: Opaque
stringData:
  api-key: "some-value"
EOF
```

2. Encrypt in-place:

```bash
sops --encrypt --in-place apps/base/my-app/my-app-secret.yaml
```

3. Add the file to the app's `kustomization.yaml` resources list, commit, and push.

The `decryption:` block is already configured on the `apps` Kustomization — no additional Flux configuration is required.

---

## Cluster Rebuild Procedure

After `make destroy`, the cluster is gone and the `sops-age` secret is lost with it. The bootstrap script re-loads it automatically on the next `make bootstrap` if the age key exists at the standard path:

```bash
make destroy
make bootstrap        # step 8/10 re-creates sops-age automatically
flux get all -A       # watch reconciliation — secrets decrypt on first sync
```

To restore the key from a password manager on a new machine first:

```bash
mkdir -p ~/.config/sops/age
# paste the key contents from the password manager:
cat > ~/.config/sops/age/keys.txt <<'EOF'
# created: ...
# public key: age1...
AGE-SECRET-KEY-1...
EOF
make bootstrap
```

---

## Architecture Reference

| Component | File | Purpose |
|-----------|------|---------|
| SOPS config | `.sops.yaml` | Tells `sops` which files to encrypt and which public key to use |
| Flux decryption | `clusters/kind/apps.yaml` `spec.decryption` | Tells `kustomize-controller` to decrypt with SOPS using the `sops-age` secret |
| Private key | `sops-age` secret in `flux-system` | The age private key the controller uses to decrypt at apply time |

The `decryption:` block in `clusters/kind/apps.yaml`:

```yaml
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Only the `apps` Kustomization carries this block because that is the layer where encrypted secrets currently reside. If encrypted secrets are added to the `infrastructure-configs` layer in the future, the same block must be added to `clusters/kind/infrastructure-configs.yaml`.

---

## Grafana `secret_key` — A Related Bootstrap Secret

The `grafana-secret-key` Secret is not managed by SOPS. It is not committed to Git. The bootstrap script (step 10 of 10) creates it directly in the `observability` namespace using `openssl rand -base64 32`.

This Secret is separate from the SOPS-managed `grafana-admin-secret`. Its purpose is different: Grafana uses `GF_SECURITY_SECRET_KEY` to encrypt stored datasource passwords and sign browser sessions. Without a stable value, every pod restart generates a new key, which corrupts stored datasource credentials and forces all users to log in again.

**What happens if it is missing:**

If `grafana-secret-key` does not exist in the `observability` namespace when the Grafana HelmRelease first installs, Kubernetes rejects the pod because the `envValueFrom` reference cannot be resolved. The HelmRelease enters a failed state and Grafana does not start.

**How to recreate it on a running cluster:**

```bash
kubectl create secret generic grafana-secret-key \
  --namespace observability \
  --from-literal=secret-key="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Force Grafana to pick it up
flux suspend helmrelease grafana -n flux-system
flux resume helmrelease grafana -n flux-system
```

**After a cluster rebuild:** The bootstrap script recreates this Secret automatically. No manual step is required after `make bootstrap`.

---

## Recovery: Lost Private Key

If the age private key is lost (machine failure, accidental deletion, no backup):

1. Every SOPS-encrypted secret in the repository is permanently unreadable.
2. Generate a new key pair with `make sops-setup`.
3. Update `.sops.yaml` with the new public key.
4. Recreate every encrypted secret manually (the original plaintext values must be known).
5. Re-encrypt all secrets with the new key.
6. Run `make sops-load-key` to load the new key into the cluster.

**Prevention:** Back up `~/.config/sops/age/keys.txt` to a password manager immediately after generation (see step 2 of One-Time Setup). This is the single most critical step in the entire setup.
