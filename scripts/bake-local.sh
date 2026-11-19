#!/bin/bash
# Local/manual base build — the ONE command that cannot skip the steps.
# Mirrors the CI workflow exactly: apply base-debrand.patch (LABELS-only,
# PROVENANCE rule), pre-gate the patched tree, bake the certbot-node target
# with the same buildx invocation, then assert the shipped labels.
#
# Usage:  bash scripts/bake-local.sh   (from the repo root)
#
# Why this exists: `git apply base-debrand.patch` lives ONLY in the CI
# workflow steps — a manual `docker buildx bake` from the clean checkout
# bakes the VIRGIN vendored tree and ships upstream labels. The real smoke
# gate (check 17) catches that — this script prevents it instead.
set -eu

cd "$(git rev-parse --show-toplevel)"
IMAGE="ghcr.io/funkysys-org/nginx-full"
OR_VERSION=$(sed -n 's/^ARG OPENRESTY_VERSION=//p' vendor/docker-nginx-full/docker/Dockerfile | head -1)
: "${OR_VERSION:=1.31.8.1}"

# 1) Debrand patch — idempotent: skip if already applied, die if apply fails
#    for any other reason (drift must be looked at, never baked around).
cd vendor/docker-nginx-full
if git apply --check ../../base-debrand.patch 2>/dev/null; then
  git apply ../../base-debrand.patch
  echo "[bake-local] base-debrand.patch applied"
elif grep -q 'funkysys-org' docker/Dockerfile.certbot-node; then
  echo "[bake-local] base-debrand.patch already applied — continuing"
else
  echo "ERROR: base-debrand.patch does not apply and the tree is not patched — investigate, never bake around drift" >&2
  exit 1
fi

# 2) Pre-gate the patched tree BEFORE the long bake: zero upstream refs in
#    the label lines of the three Dockerfiles that stamp the final image.
for f in docker/Dockerfile docker/Dockerfile.certbot docker/Dockerfile.certbot-node; do
  if grep -n 'LABEL\|maintainer' "$f" | grep -q 'nginxproxymanager\|jc21'; then
    echo "ERROR: upstream refs still in $f LABEL lines — patch state broken" >&2
    exit 1
  fi
done
echo "[bake-local] pre-gate OK: no upstream refs in the label lines"

# 3) Bake exactly like CI (same file, same target, same export).
docker buildx create --name nginxfull || true
docker buildx use nginxfull
docker buildx bake \
  --file docker/docker-bake.hcl \
  --progress=plain \
  --var DOCKER_IMAGE="${IMAGE}" \
  --var OPENRESTY_VERSION="${OR_VERSION}" \
  --set "common.platforms=linux/amd64" \
  --set "certbot-node.output=type=docker" \
  certbot-node
docker image inspect "${IMAGE}:certbot-node" >/dev/null

# 4) Assert the shipped labels (the same contract the smoke enforces).
bad=$(docker inspect "${IMAGE}:certbot-node" --format '{{json .Config.Labels}}' | grep -c 'nginxproxymanager\|jc21' || true)
[ "$bad" = "0" ] || { echo "ERROR: upstream refs in the baked image LABELS" >&2; exit 1; }
echo "[bake-local] OK: ${IMAGE}:certbot-node — labels clean"
echo "[bake-local] next: bash scripts/waf-smoke.sh for the full gate suite (needs the WAF image)"
