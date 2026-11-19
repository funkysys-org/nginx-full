#!/bin/bash
# Parity gate (Phase A, security-carriage form): our built base must produce
# a binary whose CONFIGURE ARGS are byte-identical to the official image at
# the pinned NPM version — OR (the sanctioned exception: our openresty
# deliberately rides AHEAD of the official image for security fixes) to OUR
# OWN committed oracle, which moves only in a reviewed commit.
#
#   args:  ours == official            → PASS (tier 1, the normal case)
#          ours == committed self-     → PASS (tier 2, security carriage;
#               oracle                    the self-oracle diff vs the
#                                         official args is the reviewed
#                                         change, e.g. bumped bundled
#                                         module versions)
#          else                        → FAIL, printing the captured args
#                                         and the file to create
#   version: ours >= official          → PASS (ours newer = the documented
#                                         deviation; ours OLDER = fail)
#
# The official-image-vs-committed-oracle check stays: it guards against the
# official image being silently re-released under us.
set -eu

OURS="${1:?usage: parity-check.sh <our-image>}"
NPM_VERSION="${NPM_VERSION:-2.17.0}"
OFFICIAL="jc21/nginx-proxy-manager:${NPM_VERSION}"
ORACLE="parity/oracle-configure-args-${NPM_VERSION}.txt"
SELF_ORACLE="parity/our-configure-args.txt"

ver()  { docker run --rm --entrypoint nginx "$1" -V 2>&1 | sed -n 's/^nginx version: //p'; }
args() { docker run --rm --entrypoint nginx "$1" -V 2>&1 | sed -n 's/^configure arguments: //p'; }

fail() { echo "::error::parity: $*" >&2; exit 1; }

docker pull "$OFFICIAL" >/dev/null

our_ver="$(ver "$OURS")"
off_ver="$(ver "$OFFICIAL")"
our_args="$(args "$OURS")"
off_args="$(args "$OFFICIAL")"

# Version: equal, or ours NEWER (the security carriage). Older = fail.
[ "$our_ver" = "$off_ver" ] \
  || [ "$(printf '%s\n%s\n' "$off_ver" "$our_ver" | sort -V | tail -1)" = "$our_ver" ] \
  || fail "our nginx version ($our_ver) is OLDER than the official image ($off_ver) — never acceptable"

# Args: tier 1 (byte-identical to the official image)
if [ "$our_args" = "$off_args" ]; then
  args_note="byte-identical to $OFFICIAL"
elif [ -f "$SELF_ORACLE" ] && [ "$our_args" = "$(cat "$SELF_ORACLE")" ]; then
  args_note="match the committed self-oracle (security carriage ahead of the official image — reviewed)"
else
  echo "::error::parity: configure args match NEITHER the official image NOR the committed self-oracle." >&2
  echo "  Official:  $off_args" >&2
  echo "  Ours:      $our_args" >&2
  echo "  If this is the intentional openresty security carriage: review the diff above," >&2
  echo "  then commit ours to $SELF_ORACLE and re-run. Nothing ships until then." >&2
  exit 1
fi

# The official image must still match the committed official oracle.
[ "$(args "$OFFICIAL")" = "$(cat "$ORACLE")" ] \
  || fail "official image no longer matches the committed oracle — investigate upstream before proceeding"

echo "PARITY OK: $our_ver — args $args_note; official matches the committed oracle"
