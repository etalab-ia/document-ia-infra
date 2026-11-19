#!/usr/bin/env bash
# Scan Gitleaks des commits sortants d'une référence poussée.
#
# Le script natif scripts/pre-push transmet chaque ligne du protocole Git :
# <ref locale> <SHA local> <ref distante> <SHA distant> <remote>
# Les appels sans argument (via pre-commit ou tests manuels) peuvent fournir
# PRE_COMMIT_FROM_REF / PRE_COMMIT_TO_REF ou, à défaut,
# PRE_COMMIT_LOCAL_BRANCH et PRE_COMMIT_REMOTE_NAME.
#
# Échec (code de sortie non nul) => push bloqué.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="${REPO_ROOT}/.gitleaks.toml"
ZERO_SHA="0000000000000000000000000000000000000000"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "erreur : gitleaks est introuvable dans le PATH." >&2
  echo "Installez gitleaks v8.30.1 : https://github.com/gitleaks/gitleaks/releases" >&2
  exit 1
fi

if [ "$#" -eq 5 ]; then
  LOCAL_REF="$1"
  LOCAL_SHA="$2"
  REMOTE_SHA="$4"
  REMOTE="$5"
elif [ "$#" -eq 0 ]; then
  LOCAL_REF="${PRE_COMMIT_LOCAL_BRANCH:-HEAD}"
  LOCAL_SHA="${PRE_COMMIT_TO_REF:-$(git rev-parse --verify "${LOCAL_REF}^{commit}")}"
  REMOTE_SHA="${PRE_COMMIT_FROM_REF:-}"
  REMOTE="${PRE_COMMIT_REMOTE_NAME:-origin}"
else
  echo "usage : $0 [<ref locale> <SHA local> <ref distante> <SHA distant> <remote>]" >&2
  exit 1
fi

if [ "$LOCAL_SHA" = "$ZERO_SHA" ]; then
  # Une suppression de référence ne publie aucun nouveau commit.
  exit 0
fi

if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" != "$ZERO_SHA" ] && git cat-file -e "${REMOTE_SHA}^{commit}" 2>/dev/null; then
  RANGE="${REMOTE_SHA}..${LOCAL_SHA}"
else
  # Nouvelle branche, nouveau tag, ou REMOTE_SHA absent localement :
  # scanner tous les commits atteignables depuis LOCAL_SHA absents du remote.
  RANGE="${LOCAL_SHA} --not --remotes=${REMOTE}"
fi

gitleaks git \
  --log-opts="${RANGE}" \
  --config "${CONFIG}" \
  --redact --verbose \
  "${REPO_ROOT}"
