# Security Model, Host Isolation & Secrets Management

This document defines the security boundaries, secret lifecycle, host isolation guarantees, and Scaleway IAM requirements for **`document-ia-infra`**.

---

## 1. Security Principles

1. **Zero secrets and zero internal identifiers in Git**: Neither credentials, nor the DINUM Scaleway Project UUID (`SCW_DEFAULT_PROJECT_ID`), nor the Pulumi state bucket name (`PULUMI_STATE_BUCKET`) are stored in version control. The repository is safe to host publicly (e.g., under `etalab-ia`).
2. **No host configuration pollution**: Developer machines often hold personal or multi-project `~/.pulumi`, `~/.config/scw`, and `~/.aws` profiles. All CLI state and credentials are strictly confined to the project or an ephemeral `0700` runtime directory.
3. **No shared human credentials**: Every developer uses their own Scaleway IAM API key to preserve per-user attribution in Scaleway Audit Trail and Cockpit (Grafana) logs.
4. **No secret leakage via process arguments or stdout**:
   * `PULUMI_CONFIG_PASSPHRASE` is never exported as a plain environment variable once loaded; it is written to a `chmod 600` ephemeral file and referenced via `PULUMI_CONFIG_PASSPHRASE_FILE`.
   * During `scripts/bootstrap.sh`, the generated passphrase is written to a `0700`/`0600` temporary JSON file (cleaned via `trap EXIT`) and uploaded using `scw secret version create ... data=@<file>` so it never appears in `ps` output or terminal logs.
   * `scripts/load_env.sh` logs only **key names** loaded from Secret Manager, never values.
   * Secret Manager key/value parsing avoids `eval`, validates environment variable names against `^[A-Z_][A-Z0-9_]*$`, and passes pairs NUL-delimited from Python.

---

## 2. Data Classification Matrix

| Location | Contents | Tracked in Git | Permissions / Protection |
|---|---|---|---|
| `infra.env` | `SCW_DEFAULT_REGION`, `SCW_DEFAULT_ZONE`, `SCW_VAULT_SECRET_PATH`, `SCW_VAULT_SECRET_NAME` | Yes | Public / non-sensitive |
| `.env.local` | `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` | **No** (`.gitignore`) | Auto-enforced `chmod 600` |
| Scaleway Secret Manager (`/pulumi/config`) | `PULUMI_CONFIG_PASSPHRASE` (256-bit random), `PULUMI_STATE_BUCKET` | **No** | `type=key_value`, `protected=true`, IAM-gated |
| Ephemeral runtime dir (`$DOCIA_INFRA_RUNTIME_DIR`) | `scw-config.yaml`, `aws-credentials`, `aws-config`, `pulumi-passphrase` | **No** (outside repo) | Dir `chmod 700`, files `chmod 600` |
| `.pulumi/` | Pulumi CLI plugin cache & workspace metadata | **No** (`.gitignore`) | Local to repository |
| `stacks/*/Pulumi.<env>.yaml` | Stack configs & `secure:` encrypted secrets | Yes | Encrypted via `PULUMI_CONFIG_PASSPHRASE` |

### Ephemeral Runtime Directory Locations

| OS | Path | Mode |
|---|---|---|
| macOS (`Darwin`) | `~/Library/Caches/TemporaryItems/document-ia-infra` | `0700` (files `0600`) |
| Linux | `${XDG_RUNTIME_DIR:-/tmp}/document-ia-infra-${USER}` | `0700` (files `0600`) |

---

## 3. Host Configuration Isolation Matrix

| Tool / Subsystem | Environment Override Set by `scripts/load_env.sh` | Host Config Protected |
|---|---|---|
| **Pulumi CLI** | `PULUMI_HOME="$PROJECT_ROOT/.pulumi"` | `~/.pulumi` untouched |
| **Scaleway CLI (`scw`)** | `SCW_CONFIG_PATH="$RUNTIME_DIR/scw-config.yaml"` (empty `0600` file) | `~/.config/scw/config.yaml` untouched (no `0600 /dev/null` warning) |
| **AWS SDK / S3 Backend** | `unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`<br>`AWS_SHARED_CREDENTIALS_FILE="$RUNTIME_DIR/aws-credentials"`<br>`AWS_CONFIG_FILE="$RUNTIME_DIR/aws-config"` | `~/.aws/credentials` and `~/.aws/config` ignored |
| **AWS SDK Checksums** | `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`<br>`AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` | Prevents Scaleway S3 `InvalidDigest` errors |
| **Python / `uv`** | `UV_PYTHON="<nix-store>/bin/python3.14"`<br>`UV_PYTHON_DOWNLOADS=never` | System/pyenv/Homebrew Python untouched |

---

## 4. Scaleway IAM Requirements

### Mandatory Constraint: API Key "Preferred Project for Object Storage"

Standard S3 requests (`ListBuckets`, `CreateBucket`, `GetObject`, `PutObject`) do not carry a Scaleway `project_id` header. Scaleway routes every S3 request to the **`default_project_id` ("Preferred Project for Object Storage")** attached to the caller's IAM API key.

> [!IMPORTANT]
> If a developer's IAM API key has a *Preferred Project* set to another project (e.g., the DINUM organization's `default` project), S3 calls to `DocumentIA` buckets will fail with `403 AccessDenied` — **even if the developer can create buckets in the Scaleway web console** (because the console signs requests for the active project directly).

### Recommended IAM Permission Sets

| Role / Principal | Scope | Required Scaleway Permission Sets | Notes |
|---|---|---|---|
| **Organization-level (Developers)** | Organization (DINUM) | Permission to manage own API keys & set `default_project_id` to `DocumentIA` (or admin-assigned `Preferred Project` on each developer key) | Required once per API key for S3 state access |
| **Bootstrap Admin** (one-time) | Project `DocumentIA` | `ObjectStorageFullAccess`, `SecretManagerFullAccess` | Runs `make bootstrap` once |
| **Developer (daily IaC)** | Project `DocumentIA` | `ObjectStorageFullAccess` (or bucket R/W on state bucket), `SecretManagerReadOnly`, plus permission sets for managed resources (e.g., `KubernetesFullAccess`, `RDBFullAccess`, `VPCFullAccess`) | Uses personal IAM API key |
| **CI/CD (future)** | Project `DocumentIA` | Dedicated **IAM Application** (`document-ia-ci`) with `Preferred Project = DocumentIA` and least-privilege resource permissions | Separates CI actions from human actions in Audit Trail |

---

## 5. Operational Security Procedures

### Rotating a Developer's API Key
1. Generate a new personal API key in the Scaleway Console with **Preferred Project = `DocumentIA`**.
2. Update `SCW_ACCESS_KEY` and `SCW_SECRET_KEY` in `.env.local` (ensure `chmod 600`).
3. Run `infra-reload` in your Nix shell and verify with `make preview stack=test env=dev`.
4. Revoke the old API key in the Scaleway Console.

### Offboarding a Developer
1. Remove the user from the `DocumentIA` IAM group or revoke their personal API keys in the Scaleway Console.
2. Because no shared S3 key is stored in the vault, S3 state access is revoked immediately.
3. If the developer had access to `PULUMI_CONFIG_PASSPHRASE` and prod secrets, consider rotating the passphrase (`pulumi stack change-secrets-provider passphrase` per stack) and updating `/pulumi/config` in Scaleway Secret Manager.

### Protecting Pulumi State
* The state bucket has **Object Versioning enabled** (`scripts/bootstrap.sh`), allowing point-in-time recovery of `.pulumi/stacks/<project>/<env>.json` if state corruption ever occurs.
* The `/pulumi/config` secret is created with **`protected=true`** in Scaleway Secret Manager to prevent accidental deletion.
