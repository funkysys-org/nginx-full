#!/bin/bash
# Parity gate (Phase A): our built base must produce the SAME nginx binary
# signature (version + configure arguments) as the official image at the
# pinned NPM version. Two layers of truth:
#   1. live: our image vs jc21/nginx-proxy-manager:${NPM_VERSION}
#   2. oracle: the capture committed from spike 001 (guards against the
#      official image being silently re-released with different args)
set -eu

OURS="${1:?usage: parity-check.sh <our-image>}"
NPM_VERSION="${NPM_VERSION:-2.17.0}"
OFFICIAL="jc21/nginx-proxy-manager:${NPM_VERSION}"
ORACLE="parity/oracle-configure-args-${NPM_VERSION}.txt"

ver()  { docker run --rm --entrypoint nginx "$1" -V 2>&1 | sed -n 's/^nginx version: //p'; }
args() { docker run --rm --entrypoint nginx "$1" -V 2>&1 | sed -n 's/^configure arguments: //p'; }

fail() { echo "::error::parity: $*" >&2; exit 1; }

docker pull "$OFFICIAL" >/dev/null

[ "$(ver "$OURS")" = "$(ver "$OFFICIAL")" ] \
  || fail "nginx version differs: ours '$(ver "$OURS")' vs official '$(ver "$OFFICIAL")'"
[ "$(args "$OURS")" = "$(args "$OFFICIAL")" ] \
  || fail "configure args differ from the official image"
[ "$(args "$OFFICIAL")" = "$(cat "$ORACLE")" ] \
  || fail "official image no longer matches the committed oracle — investigate upstream before proceeding"

echo "PARITY OK: $(ver "$OURS") — configure args byte-identical to $OFFICIAL and to the committed oracle"
