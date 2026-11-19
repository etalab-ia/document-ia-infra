#!/usr/bin/env bash
# Vérifie l'opposabilité du contrôle Gitleaks pour document-ia-infra :
# 1. Contrôle négatif #1 : un commit de `.env.local.example` avec placeholders Scaleway passe (exit 0).
# 2. Contrôle négatif #2 : un commit contenant un placeholder autorisé (`YOUR_API_KEY`) passe (exit 0).
# 3. Sonde positive #1 (`scaleway-access-key`) : une clé `SCW...` construite par fragments est détectée et bloquée.
# 4. Sonde positive #2 (`document-ia-token`) : un token `dia_...` construit par fragments est détecté et bloqué.
# 5. Sonde positive #3 (`generic-api-key`) : une clé API haute entropie construite par fragments est détectée et bloquée.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${REPO_ROOT}/.gitleaks.toml"

if [ ! -f "${CONFIG_PATH}" ]; then
  echo "erreur : fichier de configuration introuvable : ${CONFIG_PATH}" >&2
  exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "erreur : binaire 'gitleaks' introuvable dans le PATH." >&2
  exit 1
fi

verify_rule_in_report() {
  local report_path="$1"
  local expected_rule="$2"
  python3 - "${report_path}" "${expected_rule}" <<'PYEOF'
import json
from pathlib import Path
import sys

report_path = Path(sys.argv[1])
expected_rule = sys.argv[2]
if not report_path.is_file():
    print(
        f"erreur: rapport Gitleaks introuvable ({report_path}) — échec probable de configuration.",
        file=sys.stderr,
    )
    sys.exit(1)
findings = json.loads(report_path.read_text(encoding="utf-8"))
rules = {
    rule_id
    for item in findings
    if isinstance(item, dict) and isinstance((rule_id := item.get("RuleID")), str)
}
if expected_rule not in rules:
    print(
        f"erreur: la règle attendue '{expected_rule}' n'apparaît pas dans le rapport Gitleaks (règles: {sorted(rules)}).",
        file=sys.stderr,
    )
    sys.exit(1)
print(f"OK : Sonde synthétique bloquée avec succès par la règle '{expected_rule}'.")
PYEOF
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

git -C "${TMP_DIR}" init -q
git -C "${TMP_DIR}" config core.hooksPath /dev/null
git -C "${TMP_DIR}" config user.name "Security Probe"
git -C "${TMP_DIR}" config user.email "security-probe@document-ia.local"
git -C "${TMP_DIR}" config commit.gpgsign false
cp "${CONFIG_PATH}" "${TMP_DIR}/.gitleaks.toml"

echo "==> [1/5] Contrôle négatif #1 (.env.local.example exclu dans .gitleaks.toml)..."
# Fragments pour qu'aucun motif SCW[A-Z0-9]{17} littéral n'apparaisse dans ce script
SCW_EX_PREFIX="SCW"
SCW_EX_BODY="XXXXXXXXXXXXXXXXX"
SCW_EX_SECRET="00000000-0000-0000-0000-000000000000"
cat > "${TMP_DIR}/.env.local.example" <<EOF
SCW_ACCESS_KEY="${SCW_EX_PREFIX}${SCW_EX_BODY}"
SCW_SECRET_KEY="${SCW_EX_SECRET}"
SCW_DEFAULT_PROJECT_ID="${SCW_EX_SECRET}"
EOF
git -C "${TMP_DIR}" add .gitleaks.toml .env.local.example
git -C "${TMP_DIR}" commit -q -m "chore: add .env.local.example with Scaleway placeholders"

if ! gitleaks git --config "${TMP_DIR}/.gitleaks.toml" --redact "${TMP_DIR}"; then
  echo "erreur : Gitleaks a échoué sur .env.local.example alors qu'il est explicitement exclu." >&2
  exit 1
fi
echo "OK : Contrôle négatif #1 (.env.local.example) passe (exit 0)."

echo "==> [2/5] Contrôle négatif #2 (placeholder autorisé dans .gitleaks.toml)..."
PLACEHOLDER_A="YOUR_API"
PLACEHOLDER_B="_KEY"
cat > "${TMP_DIR}/sample.py" <<EOF
# Exemple avec placeholder autorisé par la liste blanche
HEADER_EXAMPLE = "Bearer ${PLACEHOLDER_A}${PLACEHOLDER_B}"
EOF
git -C "${TMP_DIR}" add sample.py
git -C "${TMP_DIR}" commit -q -m "chore: add clean file with allowed placeholder"
CLEAN_SHA="$(git -C "${TMP_DIR}" rev-parse HEAD)"

if ! gitleaks git --config "${TMP_DIR}/.gitleaks.toml" --redact "${TMP_DIR}"; then
  echo "erreur : Gitleaks a échoué sur un commit propre contenant uniquement un placeholder autorisé." >&2
  exit 1
fi
echo "OK : Contrôle négatif #2 (placeholder autorisé) passe (exit 0)."

echo "==> [3/5] Sonde positive #1 (règle personnalisée 'scaleway-access-key')..."
SCW_P1="SCW"
SCW_P2="SYNTH987"
SCW_P3="K4M2P6Q8W"
SYNTH_SCW_KEY="${SCW_P1}${SCW_P2}${SCW_P3}"

printf 'SCW_ACCESS_KEY = "%s"\n' "${SYNTH_SCW_KEY}" > "${TMP_DIR}/leaked_scw.py"
git -C "${TMP_DIR}" add leaked_scw.py
git -C "${TMP_DIR}" commit -q -m "test: inject synthetic scaleway access key"

REPORT_SCW="${TMP_DIR}/report_scw_key.json"
if gitleaks git \
  --config "${TMP_DIR}/.gitleaks.toml" \
  --report-format json \
  --report-path "${REPORT_SCW}" \
  --redact \
  "${TMP_DIR}" >/dev/null 2>&1; then
  echo "erreur : Gitleaks n'a PAS bloqué la clé d'accès Scaleway synthétique !" >&2
  exit 1
fi
verify_rule_in_report "${REPORT_SCW}" "scaleway-access-key"

echo "==> [4/5] Sonde positive #2 (règle personnalisée 'document-ia-token')..."
git -C "${TMP_DIR}" reset -q --hard "${CLEAN_SHA}"

DIA_P1="dia_"
DIA_P2="prod_v1_"
DIA_P3="SYNTH999_"
DIA_P4="K8M2P9Q4R7T1V5W3X6Y8Z2B4N6M8Q1W3E5R7_"
DIA_P5="Z9X8"
SYNTH_DIA_TOKEN="${DIA_P1}${DIA_P2}${DIA_P3}${DIA_P4}${DIA_P5}"

printf 'SYNTHETIC_TOKEN = "%s"\n' "${SYNTH_DIA_TOKEN}" > "${TMP_DIR}/leaked_token.py"
git -C "${TMP_DIR}" add leaked_token.py
git -C "${TMP_DIR}" commit -q -m "test: inject synthetic document-ia token"

REPORT_DIA="${TMP_DIR}/report_dia_token.json"
if gitleaks git \
  --config "${TMP_DIR}/.gitleaks.toml" \
  --report-format json \
  --report-path "${REPORT_DIA}" \
  --redact \
  "${TMP_DIR}" >/dev/null 2>&1; then
  echo "erreur : Gitleaks n'a PAS bloqué le token synthétique Document IA !" >&2
  exit 1
fi
verify_rule_in_report "${REPORT_DIA}" "document-ia-token"

echo "==> [5/5] Sonde positive #3 (règle par défaut 'generic-api-key')..."
git -C "${TMP_DIR}" reset -q --hard "${CLEAN_SHA}"

K_LEFT="api"
K_RIGHT="_key"
S1="7f9a2b4c"
S2="8e1d3f5a"
S3="6c0b9e2d"
S4="4a7f1c8b"
S5="3e6d9a2f"
printf '%s%s = "%s"\n' "${K_LEFT}" "${K_RIGHT}" "${S1}${S2}${S3}${S4}${S5}" > "${TMP_DIR}/leaked_generic.py"
git -C "${TMP_DIR}" add leaked_generic.py
git -C "${TMP_DIR}" commit -q -m "test: inject synthetic generic high-entropy secret"

REPORT_GENERIC="${TMP_DIR}/report_generic.json"
if gitleaks git \
  --config "${TMP_DIR}/.gitleaks.toml" \
  --report-format json \
  --report-path "${REPORT_GENERIC}" \
  --redact \
  "${TMP_DIR}" >/dev/null 2>&1; then
  echo "erreur : Gitleaks n'a PAS bloqué le secret générique haute entropie !" >&2
  exit 1
fi
verify_rule_in_report "${REPORT_GENERIC}" "generic-api-key"

echo "✅ Vérification Gitleaks (contrôles négatifs + sondes synthétiques) terminée avec succès."
