#!/usr/bin/env bash
# Creates the MinIO root credentials Secret out-of-band (GitOps never sees it).
# Credentials are written to .secrets/minio-root (gitignored) for local reference.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT_DIR/kubeconfig}"

NS=minio
SECRET=minio-root-creds
USER=alohomora
PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "Secret $SECRET already exists in ns/$NS — leaving it untouched."
  exit 0
fi

kubectl -n "$NS" create secret generic "$SECRET" \
  --from-literal=rootUser="$USER" \
  --from-literal=rootPassword="$PASS"

mkdir -p "$ROOT_DIR/.secrets"
umask 077
printf 'rootUser=%s\nrootPassword=%s\n' "$USER" "$PASS" > "$ROOT_DIR/.secrets/minio-root"
echo "Created ns/$NS secret/$SECRET. Local copy: .secrets/minio-root (gitignored)."
