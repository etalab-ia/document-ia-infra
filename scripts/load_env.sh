#!/usr/bin/env bash
# =============================================================================
# Chargement isolé de l'environnement Document IA Infra (sourcé par flake.nix)
# =============================================================================
# Objectifs :
#   1. Ne jamais lire ni modifier ~/.pulumi, ~/.config/scw ou ~/.aws
#   2. Ne stocker aucun secret ni identifiant interne (Project ID, nom de bucket) dans Git
#   3. Utiliser la clé API IAM personnelle du développeur (traçabilité Grafana/Audit Trail)
#   4. Charger PULUMI_STATE_BUCKET & PULUMI_CONFIG_PASSPHRASE depuis Scaleway Secret Manager
#   5. Configurer le backend Pulumi S3 sur Scaleway Object Storage avec profil éphémère
#
# NOTE : ce fichier est SOURCÉ dans un shell interactif -> ne jamais appeler `exit` ni `set -e`.

_docia_load_env() {
  local project_root="${PROJECT_ROOT:-$PWD}"
  local infra_env_file="$project_root/infra.env"
  local local_env_file="$project_root/.env.local"

  # ---------------------------------------------------------------------------
  # 1. Isolation totale des configurations locales de la machine hôte
  # ---------------------------------------------------------------------------
  export PULUMI_HOME="$project_root/.pulumi"
  mkdir -p "$PULUMI_HOME"

  # Répertoire runtime éphémère hors dépôt (chmod 700)
  local runtime_dir=""
  if [ "$(uname -s)" = "Darwin" ]; then
    runtime_dir="$HOME/Library/Caches/TemporaryItems/document-ia-infra"
  else
    runtime_dir="${XDG_RUNTIME_DIR:-/tmp}/document-ia-infra-${USER:-user}"
  fi
  (
    umask 077
    mkdir -p "$runtime_dir"
    chmod 700 "$runtime_dir"
    : > "$runtime_dir/scw-config.yaml"
    chmod 600 "$runtime_dir/scw-config.yaml"
  )
  export DOCIA_INFRA_RUNTIME_DIR="$runtime_dir"

  # Fichier scw vide en chmod 600 pour isoler ~/.config/scw sans warning de permissions
  export SCW_CONFIG_PATH="$runtime_dir/scw-config.yaml"
  export SCW_CLI_CHECK_VERSION="false"
  # Nettoyer les éventuelles variables Scaleway héritées du shell hôte (~/.zshrc, autre projet)
  unset SCW_PROFILE SCW_DEFAULT_ORGANIZATION_ID SCW_ORGANIZATION_ID SCW_PROJECT_ID SCW_REGION SCW_ZONE

  # Empêcher tout profil ~/.aws local d'interférer avec Scaleway Object Storage
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  export AWS_CONFIG_FILE="/dev/null"
  export AWS_SHARED_CREDENTIALS_FILE="/dev/null"

  # Requis par AWS SDK Go v2 (Pulumi >= 3.x) pour éviter les erreurs InvalidDigest sur Scaleway S3
  export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"

  # Réinitialiser les variables Pulumi sensibles avant rechargement
  unset PULUMI_BACKEND_URL PULUMI_STATE_BUCKET PULUMI_CONFIG_PASSPHRASE PULUMI_CONFIG_PASSPHRASE_FILE

  # ---------------------------------------------------------------------------
  # 2. Chargement de la configuration publique générique (infra.env)
  # ---------------------------------------------------------------------------
  if [ ! -f "$infra_env_file" ]; then
    echo "❌ Fichier $infra_env_file introuvable." >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$infra_env_file"
  set +a

  # ---------------------------------------------------------------------------
  # 3. Chargement des credentials personnels Scaleway (.env.local ou interactif)
  # ---------------------------------------------------------------------------
  if [ -f "$local_env_file" ]; then
    local perms=""
    if stat -f "%Lp" "$local_env_file" >/dev/null 2>&1; then
      perms="$(stat -f "%Lp" "$local_env_file")"
    elif stat -c "%a" "$local_env_file" >/dev/null 2>&1; then
      perms="$(stat -c "%a" "$local_env_file")"
    fi
    if [ -n "$perms" ] && [ "$perms" != "600" ]; then
      echo "⚠️  Permissions trop larges sur .env.local ($perms) -> application de chmod 600."
      chmod 600 "$local_env_file"
    fi

    # En local, .env.local a toujours la priorité sur les variables SCW_* du shell hôte
    # (en CI, .env.local n'existe pas et les variables d'env CI sont utilisées directement).
    unset SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID
    set -a
    # shellcheck disable=SC1090
    source "$local_env_file"
    set +a
  fi

  local need_save="false"

  if [ "${INFRA_SKIP_VAULT:-0}" != "1" ] && { [ -z "${SCW_ACCESS_KEY:-}" ] || [ -z "${SCW_SECRET_KEY:-}" ]; }; then
    if [ -t 0 ]; then
      echo ""
      echo "🔑 Identifiants API Scaleway personnels requis (projet DocumentIA)."
      echo "   (Appuyez sur Entrée sans rien saisir pour ouvrir le shell en mode hors-ligne)"
      local input_access=""
      local input_secret=""
      read -r -p "   SCW_ACCESS_KEY : " input_access
      if [ -n "$input_access" ]; then
        read -r -s -p "   SCW_SECRET_KEY : " input_secret
        echo ""
        if [ -n "$input_secret" ]; then
          export SCW_ACCESS_KEY="$input_access"
          export SCW_SECRET_KEY="$input_secret"
          need_save="true"
        fi
      fi
    fi
  fi

  # Auto-découverte du SCW_DEFAULT_PROJECT_ID depuis la clé API IAM (si absent)
  if [ "${INFRA_SKIP_VAULT:-0}" != "1" ] && [ -n "${SCW_ACCESS_KEY:-}" ] && [ -n "${SCW_SECRET_KEY:-}" ] && [ -z "${SCW_DEFAULT_PROJECT_ID:-}" ]; then
    local discovered_project_id=""
    discovered_project_id="$(scw iam api-key get "${SCW_ACCESS_KEY}" -o json 2>/dev/null | jq -r '.default_project_id // empty' 2>/dev/null || true)"
    if [ -n "$discovered_project_id" ]; then
      export SCW_DEFAULT_PROJECT_ID="$discovered_project_id"
      echo "🔎 SCW_DEFAULT_PROJECT_ID auto-découvert depuis votre clé API Scaleway."
    elif [ -t 0 ]; then
      echo "ℹ️  Auto-découverte du Project ID indisponible avec vos droits IAM actuels."
      local input_project=""
      read -r -p "   SCW_DEFAULT_PROJECT_ID (UUID du projet DocumentIA) : " input_project
      if [ -n "$input_project" ]; then
        export SCW_DEFAULT_PROJECT_ID="$input_project"
        need_save="true"
      fi
    fi
  fi

  if [ "$need_save" = "true" ] && [ -t 0 ]; then
    local save_choice=""
    read -r -p "   Mémoriser dans .env.local (chmod 600, ignoré par Git) ? [O/n] : " save_choice
    if [ -z "$save_choice" ] || [[ "$save_choice" =~ ^[OoYy]$ ]]; then
      (
        umask 077
        {
          printf 'SCW_ACCESS_KEY=%q\n' "${SCW_ACCESS_KEY}"
          printf 'SCW_SECRET_KEY=%q\n' "${SCW_SECRET_KEY}"
          if [ -n "${SCW_DEFAULT_PROJECT_ID:-}" ]; then
            printf 'SCW_DEFAULT_PROJECT_ID=%q\n' "${SCW_DEFAULT_PROJECT_ID}"
          fi
        } > "$local_env_file"
      )
      echo "   ✅ Enregistré dans .env.local (chmod 600)."
    fi
  fi

  # ---------------------------------------------------------------------------
  # 5. Profil S3 éphémère pour Object Storage Scaleway (hors ~/.aws)
  # ---------------------------------------------------------------------------
  if [ -n "${SCW_ACCESS_KEY:-}" ] && [ -n "${SCW_SECRET_KEY:-}" ]; then
    local aws_creds_file="$runtime_dir/aws-credentials"
    local aws_config_file="$runtime_dir/aws-config"
    (
      umask 077
      cat > "$aws_creds_file" <<CREDS
[scw-pulumi-backend]
aws_access_key_id = ${SCW_ACCESS_KEY}
aws_secret_access_key = ${SCW_SECRET_KEY}
CREDS
      cat > "$aws_config_file" <<CFG
[profile scw-pulumi-backend]
region = ${SCW_DEFAULT_REGION}
output = json
request_checksum_calculation = when_required
response_checksum_validation = when_required
CFG
    )
    export AWS_SHARED_CREDENTIALS_FILE="$aws_creds_file"
    export AWS_CONFIG_FILE="$aws_config_file"
    export AWS_REGION="${SCW_DEFAULT_REGION}"
  fi

  # ---------------------------------------------------------------------------
  # 6. Chargement du vault Scaleway Secret Manager (type: key_value)
  # ---------------------------------------------------------------------------
  if [ "${INFRA_SKIP_VAULT:-0}" = "1" ]; then
    echo "ℹ️  Mode INFRA_SKIP_VAULT=1 : chargement du vault Scaleway ignoré."
    return 0
  fi

  if [ -z "${SCW_ACCESS_KEY:-}" ] || [ -z "${SCW_SECRET_KEY:-}" ]; then
    echo "⚠️  Shell Nix prêt en mode hors-ligne (SCW_ACCESS_KEY/SCW_SECRET_KEY non définis)."
    echo "   → Copiez .env.local.example vers .env.local puis lancez 'infra-reload'."
    return 0
  fi

  if [ -z "${SCW_DEFAULT_PROJECT_ID:-}" ]; then
    echo "⚠️  SCW_DEFAULT_PROJECT_ID non défini."
    echo "   → Renseignez SCW_DEFAULT_PROJECT_ID dans .env.local puis lancez 'infra-reload'."
    return 0
  fi

  local secret_json=""
  if ! secret_json="$(scw secret version access-by-path \
      secret-path="${SCW_VAULT_SECRET_PATH}" \
      secret-name="${SCW_VAULT_SECRET_NAME}" \
      revision=latest_enabled \
      project-id="${SCW_DEFAULT_PROJECT_ID}" \
      region="${SCW_DEFAULT_REGION}" \
      -o json 2>/dev/null)"; then
    echo "⚠️  Secret '${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}' introuvable ou inaccessible dans Scaleway Secret Manager."
    echo "   → Si c'est la 1ère initialisation du projet, lancez : make bootstrap"
    echo "   → Sinon vérifiez vos droits IAM (SecretManagerReadOnly) et votre SCW_DEFAULT_PROJECT_ID."
    return 0
  fi

  local loaded_keys=()
  local key=""
  local val=""

  while IFS= read -r -d '' key && IFS= read -r -d '' val; do
    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      echo "⚠️  Clé ignorée dans le secret Scaleway (nom de variable invalide) : $key" >&2
      continue
    fi

    if [ "$key" = "PULUMI_CONFIG_PASSPHRASE" ]; then
      local pass_file="$runtime_dir/pulumi-passphrase"
      (
        umask 077
        printf '%s' "$val" > "$pass_file"
      )
      export PULUMI_CONFIG_PASSPHRASE_FILE="$pass_file"
      unset PULUMI_CONFIG_PASSPHRASE
      loaded_keys+=("PULUMI_CONFIG_PASSPHRASE_FILE (depuis PULUMI_CONFIG_PASSPHRASE)")
    else
      export "$key=$val"
      loaded_keys+=("$key")
    fi
  done < <(
    printf '%s' "$secret_json" | python3 -c '
import base64, json, sys
payload = json.load(sys.stdin)
raw = base64.b64decode(payload["data"]).decode("utf-8")
kv = json.loads(raw)
if not isinstance(kv, dict):
    sys.exit("Le secret Scaleway doit être de type key_value (objet JSON).")
for k, v in kv.items():
    sys.stdout.write(str(k) + "\0" + str(v) + "\0")
'
  )

  # ---------------------------------------------------------------------------
  # 7. Configuration du backend S3 Pulumi à partir du nom de bucket issu du Vault
  # ---------------------------------------------------------------------------
  if [ -n "${PULUMI_STATE_BUCKET:-}" ]; then
    export PULUMI_BACKEND_URL="s3://${PULUMI_STATE_BUCKET}?endpoint=s3.${SCW_DEFAULT_REGION}.scw.cloud&region=${SCW_DEFAULT_REGION}&s3ForcePathStyle=true&profile=scw-pulumi-backend"
  else
    echo "⚠️  PULUMI_STATE_BUCKET absent du secret '${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}'." >&2
  fi

  echo "✅ Environnement Document IA Infra prêt :"
  echo "   • Python  : $(python3 --version 2>&1) (venv: .venv)"
  echo "   • Pulumi  : $(pulumi version 2>&1) (PULUMI_HOME=.pulumi)"
  if [ -n "${PULUMI_STATE_BUCKET:-}" ]; then
    echo "   • Backend : Scaleway Object Storage (${SCW_DEFAULT_REGION}, profil éphémère)"
  fi
  if [ "${#loaded_keys[@]}" -gt 0 ]; then
    echo "   • Vault   : ${loaded_keys[*]}"
  fi
}

_docia_load_env
unset -f _docia_load_env
