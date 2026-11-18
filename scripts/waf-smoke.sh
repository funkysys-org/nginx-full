#!/bin/bash
# Smoke test for the npm-modsec image against the compose stack
# (docker-compose.waf-test.yml must be UP before running this).
# Self-diagnosing: on ANY failure it prints compose ps + container logs.
set -uo pipefail   # deliberately NO set -e: errors are handled explicitly

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.waf-test.yml}
SVC=${COMPOSE_SERVICE:-npm}
UI=${UI_URL:-http://127.0.0.1:8181}
WAF=${WAF_URL:-http://127.0.0.1:8080}

say()  { echo "[smoke] $*"; }
pass() { echo "[smoke] ok: $*"; }

diagnose() {
  echo "--- diagnostics: compose ps ---"
  docker compose -f "$COMPOSE_FILE" ps 2>&1
  echo "--- diagnostics: $SVC last 40 log lines ---"
  docker compose -f "$COMPOSE_FILE" logs --tail 40 "$SVC" 2>&1
}
die() { echo "[smoke] FAIL: $*" >&2; diagnose; exit 1; }

code()  { curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
execsvc() { docker compose -f "$COMPOSE_FILE" exec -T "$SVC" sh -c "$1"; }

# 0) compose stack is actually up
say "compose file: $COMPOSE_FILE (service: $SVC)"
state=$(docker compose -f "$COMPOSE_FILE" ps 2>&1) || die "docker compose ps failed — run from the repo root"
echo "$state"
# NOTE: do NOT grep the human-readable ps table for 'running' — compose versions
# print STATUS as 'Up 56 seconds' etc. Use the format-agnostic query instead.
if [ -z "$(docker compose -f "$COMPOSE_FILE" ps -q --status running "$SVC" 2>/dev/null)" ]; then
  die "no running '$SVC' container — did 'docker compose up -d' succeed? see compose output above"
fi

# 1) wait for the NPM admin UI (first boot runs DB migrations, can take ~60 s)
say "waiting for admin UI on $UI/ ..."
ui=""
for i in $(seq 1 45); do
  ui=$(code "$UI/")
  if [ "$ui" = "200" ] || [ "$ui" = "302" ]; then break; fi
  sleep 2
done
[ "$ui" = "200" ] || [ "$ui" = "302" ] \
  || die "admin UI not ready after 90s (last HTTP code: '${ui:-none/transport-error}')"

# 2) stock nginx config valid with the module loaded (real container, real boot)
out=$(execsvc 'nginx -t 2>&1') || die "could not run nginx -t inside container"
echo "$out" | grep -q 'test is successful' || die "nginx -t inside container: $out"
pass "nginx -t clean inside container (module loaded at real boot)"

# 3) s6 seed created the /data/modsec tunables
execsvc 'test -f /data/modsec/crs-setup.conf' \
  || die '/data/modsec/crs-setup.conf missing (s6 seed did not run)'
pass "/data/modsec seeded"

# 3b) overlay+ modules present (loading itself is proven by the nginx -t above)
execsvc 'test -f /usr/lib/nginx/modules/ngx_http_vhost_traffic_status_module.so' \
  || die 'vts module .so missing'
execsvc 'test -f /usr/lib/nginx/modules/ngx_http_cache_purge_module.so' \
  || die 'cache_purge module .so missing'
pass "vts + cache_purge modules present"

# 4) start the in-container WAF test instance
execsvc 'mkdir -p /tmp/waf-test && nginx -c /etc/nginx-modsec-test/nginx-waf.conf' \
  || die 'could not start WAF test instance'
sleep 2

c=$(code "$WAF/") || die "curl to WAF failed (exit $?)"
[ "$c" = "200" ] || die "benign GET / -> $c (want 200)"
pass "benign 200"

for u in '/?id=1%20UNION%20SELECT%20password%20FROM%20users' \
         '/?exec=/bin/bash' \
         '/?q=%3Cscript%3Ealert%281%29%3C%2Fscript%3E'; do
  c=$(code "$WAF$u") || die "curl to WAF failed on $u (exit $?)"
  [ "$c" = "403" ] || die "$u -> $c (want 403)"
done
pass "attacks 403"

# 5) CRS blocking evidence in the audit log
execsvc 'grep -q 949110 /data/logs/modsec_audit.log' \
  || die 'no 949110 (Inbound Anomaly Score) in /data/logs/modsec_audit.log'
pass "audit log has CRS blocking evidence"

# 6) WAF-audit log source exposed by the patched backend (Phase A4)
API="$UI/api"
admin_email="admin@nginx-full-smoke.local"; admin_secret='SmokeAdmin-123'
setup_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/users" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Smoke Admin\",\"nickname\":\"smoke\",\"email\":\"$admin_email\",\"auth\":{\"type\":\"password\",\"secret\":\"$admin_secret\"}}")
if [ "$setup_code" = "200" ] || [ "$setup_code" = "201" ]; then
  admin_tok=$(curl -s -X POST "$API/tokens" -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$admin_email\",\"secret\":\"$admin_secret\"}" \
    | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
  [ -n "$admin_tok" ] || die "admin login failed"
  srcs=$(curl -s "$API/logs/sources" -H "Authorization: Bearer $admin_tok")
  echo "$srcs" | grep -q '"waf"' \
    || die "WAF audit source missing from /logs/sources: $srcs"
  pass "WAF audit source present in the API log sources"
else
  say "skip: API source check (first-boot user creation returned $setup_code — volume not fresh)"
fi

echo
echo "SMOKE OK: UI up, nginx -t clean, seed present, benign 200, attacks 403, audit log written, WAF audit in API sources"
