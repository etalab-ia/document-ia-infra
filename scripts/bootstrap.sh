#!/usr/bin/env bash
# =============================================================================
# Bootstrap unique du backend Pulumi S3 et du secret Vault sur Scaleway
# =============================================================================
# À exécuter UNE SEULE FOIS (idempotent) dès que vous disposez des droits IAM
# (ObjectStorageFullAccess + SecretManagerFullAccess) sur le projet DocumentIA.
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ ! -f "$PROJECT_ROOT/infra.env" ]; then
  echo "❌ Fichier $PROJECT_ROOT/infra.env introuvable." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/infra.env"
set +a

if [ -z "${SCW_ACCESS_KEY:-}" ] || [ -z "${SCW_SECRET_KEY:-}" ]; then
  echo "❌ SCW_ACCESS_KEY et SCW_SECRET_KEY doivent être définis (lancez depuis 'nix develop')." >&2
  exit 1
fi

if [ -z "${SCW_DEFAULT_PROJECT_ID:-}" ]; then
  echo "❌ SCW_DEFAULT_PROJECT_ID doit être défini (dans .env.local ou auto-découvert via 'nix develop')." >&2
  exit 1
fi

# Choisir le nom du bucket S3 de state (doit être unique dans la région Scaleway)
BUCKET_NAME="${PULUMI_STATE_BUCKET:-}"
if [ -z "$BUCKET_NAME" ]; then
  DEFAULT_BUCKET="docia-pulumi-state-${SCW_DEFAULT_PROJECT_ID:0:8}"
  if [ -t 0 ]; then
    read -r -p "📦 Nom du bucket S3 pour les states Pulumi [${DEFAULT_BUCKET}] : " input_bucket
    BUCKET_NAME="${input_bucket:-$DEFAULT_BUCKET}"
  else
    BUCKET_NAME="$DEFAULT_BUCKET"
  fi
fi

S3_ENDPOINT="https://s3.${SCW_DEFAULT_REGION}.scw.cloud"
AWS_CMD=(aws --profile scw-pulumi-backend --endpoint-url "$S3_ENDPOINT" --region "$SCW_DEFAULT_REGION")

echo ""
echo "🚀 Bootstrap de l'infrastructure Pulumi sur Scaleway"
echo "   • Région  : ${SCW_DEFAULT_REGION}"
echo "   • Bucket  : ${BUCKET_NAME}"
echo "   • Vault   : ${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}"
echo ""

# -----------------------------------------------------------------------------
# 1. Bucket Scaleway Object Storage pour le state Pulumi (avec versioning)
# -----------------------------------------------------------------------------
echo "1️⃣  Vérification du bucket S3 '${BUCKET_NAME}'..."
if "${AWS_CMD[@]}" s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "   ✅ Le bucket '${BUCKET_NAME}' existe déjà."
else
  echo "   📦 Création du bucket '${BUCKET_NAME}'..."
  "${AWS_CMD[@]}" s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --create-bucket-configuration "LocationConstraint=${SCW_DEFAULT_REGION}" >/dev/null
  echo "   ✅ Bucket créé."
fi

echo "   🔒 Activation du versioning sur '${BUCKET_NAME}'..."
"${AWS_CMD[@]}" s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled
echo "   ✅ Versioning activé."

# -----------------------------------------------------------------------------
# 2. Secret Scaleway Secret Manager (type: key_value) :
#    PULUMI_STATE_BUCKET + PULUMI_CONFIG_PASSPHRASE (256 bits)
# -----------------------------------------------------------------------------
echo ""
echo "2️⃣  Vérification du secret '${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}'..."
if scw secret version access-by-path \
    secret-path="${SCW_VAULT_SECRET_PATH}" \
    secret-name="${SCW_VAULT_SECRET_NAME}" \
    revision=latest_enabled \
    project-id="${SCW_DEFAULT_PROJECT_ID}" \
    region="${SCW_DEFAULT_REGION}" >/dev/null 2>&1; then
  echo "   ✅ Le secret '${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}' existe déjà avec une version active."
else
  existing_secret_id="$(scw secret secret list \
    project-id="${SCW_DEFAULT_PROJECT_ID}" \
    region="${SCW_DEFAULT_REGION}" \
    path="${SCW_VAULT_SECRET_PATH}" \
    name="${SCW_VAULT_SECRET_NAME}" \
    -o json | jq -r --arg name "${SCW_VAULT_SECRET_NAME}" --arg path "${SCW_VAULT_SECRET_PATH}" \
      '.[] | select(.name == $name and .path == $path) | .id' | head -n 1)"

  if [ -z "$existing_secret_id" ]; then
    echo "   🔐 Création du secret '${SCW_VAULT_SECRET_PATH}/${SCW_VAULT_SECRET_NAME}' (type=key_value, protected=true)..."
    existing_secret_id="$(scw secret secret create \
      project-id="${SCW_DEFAULT_PROJECT_ID}" \
      region="${SCW_DEFAULT_REGION}" \
      path="${SCW_VAULT_SECRET_PATH}" \
      name="${SCW_VAULT_SECRET_NAME}" \
      type=key_value \
      protected=true \
      description="Configuration commune Pulumi Document IA (gérée via document-ia-infra)" \
      -o json | jq -r '.id')"
    echo "   ✅ Secret créé (id: ${existing_secret_id})."
  fi

  echo "   🔑 Génération d'une PULUMI_CONFIG_PASSPHRASE aléatoire (256 bits)..."
  tmp_dir="$(mktemp -d)"
  chmod 700 "$tmp_dir"
  trap 'rm -rf "$tmp_dir"' EXIT

  payload_file="$tmp_dir/payload.json"
  (
    umask 077
    passphrase="$(openssl rand -base64 32)"
    jq -n \
      --arg pp "$passphrase" \
      --arg bucket "$BUCKET_NAME" \
      '{"PULUMI_CONFIG_PASSPHRASE": $pp, "PULUMI_STATE_BUCKET": $bucket}' > "$payload_file"
  )

  scw secret version create "$existing_secret_id" \
    region="${SCW_DEFAULT_REGION}" \
    data="@${payload_file}" \
    description="Initial bootstrap config (state bucket + passphrase)" >/dev/null

  echo "   ✅ Version initiale enregistrée dans Scaleway Secret Manager."
fi

echo ""
echo "🎉 Bootstrap terminé !"
echo "   Exécutez maintenant dans votre shell Nix :"
echo "     infra-reload"
echo "     make preview stack=test env=dev"
echo "     make up stack=test env=dev"
