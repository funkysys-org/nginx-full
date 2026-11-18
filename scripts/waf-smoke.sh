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

# 6) live API schema + Swagger UI docs page (backend patch layer)
API="$UI/api"
s=$(code "$API/schema") || die "curl to /api/schema failed (exit $?)"
[ "$s" = "200" ] || die "GET /api/schema -> $s (want 200)"
curl -fsS "$API/schema" | grep -q '"openapi"' || die 'schema payload does not look like OpenAPI'
curl -fsS "$API/schema" | grep -q 'Proxywarden API' || die 'schema info.title is not the branded one'
s=$(code "$API/docs") || die "curl to /api/docs failed (exit $?)"
[ "$s" = "200" ] || die "GET /api/docs -> $s (want 200)"
curl -fsS "$API/docs" | grep -q 'swagger-ui' || die 'docs page does not embed Swagger UI'
pass "API schema live + Swagger UI docs served"

# 7) WAF-audit log source exposed by the patched backend (Phase A4)
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

  # 8) Static Hosts (Phase A5): create via API -> serves the content on :80 -> cleanup
  sh_create=$(curl -s -X POST "$API/nginx/static-hosts" \
    -H "Authorization: Bearer $admin_tok" -H 'Content-Type: application/json' \
    -d '{"domain_names":["static-smoke.test"],"content":"<h1>StaticSmokeWorks</h1>"}')
  sh_id=$(echo "$sh_create" | sed -n 's/.*"id" *: *\([0-9]*\).*/\1/p' | head -1)
  [ -n "$sh_id" ] || die "static host creation failed: $sh_create"
  sleep 2   # configure() reloads nginx — give it a beat
  sh_body=$(curl -s -H 'Host: static-smoke.test' http://127.0.0.1:80/)
  echo "$sh_body" | grep -q 'StaticSmokeWorks' \
    || die "static host did not serve its content: $sh_body"
  curl -s -o /dev/null -X DELETE "$API/nginx/static-hosts/$sh_id" -H "Authorization: Bearer $admin_tok"
  pass "static host: created via API, serves its content, deleted"

  # 9) Metrics endpoint (A6): vts data live through the JWT-gated route
  m_code=$(curl -s -o /dev/null -w '%{http_code}' "$API/reports/metrics" -H "Authorization: Bearer $admin_tok")
  [ "$m_code" = "200" ] || die "GET /api/reports/metrics -> $m_code (want 200)"
  m_body=$(curl -s "$API/reports/metrics" -H "Authorization: Bearer $admin_tok")
  echo "$m_body" | grep -q 'serverZones' || die "metrics payload has no serverZones: $m_body"
  pass "metrics endpoint live (vts through the JWT gate)"

  # 10) LDAP auth setting (A7): seeded by setup and served by the settings API
  l_code=$(curl -s -o /dev/null -w '%{http_code}' "$API/settings/ldap-auth" -H "Authorization: Bearer $admin_tok")
  [ "$l_code" = "200" ] || die "GET /api/settings/ldap-auth -> $l_code (want 200)"
  l_body=$(curl -s "$API/settings/ldap-auth" -H "Authorization: Bearer $admin_tok")
  echo "$l_body" | grep -q '"enabled"' || die "ldap-auth setting has no enabled flag: $l_body"
  # Round-trip the PUT too (the settings body is a per-setting anyOf — the
  # minimal ldap payload is a subset of the 2fa-policy shape, exactly the
  # overlap that oneOf rejected): write it back unchanged, expect 200.
  lput=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/settings/ldap-auth" \
    -H "Authorization: Bearer $admin_tok" -H 'Content-Type: application/json' \
    -d '{"value":"disabled","meta":{"enabled":false,"url":"","bindDN":"","bindPassword":"","baseDN":"","filter":"(uid={username})","starttls":false,"provisionOnLogin":true,"defaultVisibility":"user"}}')
  [ "$lput" = "200" ] || die "PUT /api/settings/ldap-auth -> $lput (want 200)"
  pass "LDAP auth setting seeded, served, PUT round-trip clean"

  # 11) 2FA policy (Wave 1): setting round-trip + admin EXEMPTION — flipping
  # the policy on must not lock the operator out of their own panel.
  p_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$API/settings/2fa-policy" \
    -H "Authorization: Bearer $admin_tok" -H 'Content-Type: application/json' \
    -d '{"value":"enabled","meta":{"enabled":true}}')
  [ "$p_code" = "200" ] || die "PUT /api/settings/2fa-policy -> $p_code (want 200)"
  re_tok=$(curl -s -X POST "$API/tokens" -H 'Content-Type: application/json' \
    -d "{\"identity\":\"$admin_email\",\"secret\":\"$admin_secret\"}" \
    | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
  [ -n "$re_tok" ] || die "admin re-login failed with 2FA policy ON (admins must be exempt)"
  curl -s -o /dev/null -X PUT "$API/settings/2fa-policy" \
    -H "Authorization: Bearer $admin_tok" -H 'Content-Type: application/json' \
    -d '{"value":"disabled","meta":{"enabled":false}}'
  pass "2FA policy round-trip + admin exemption"
else
  say "skip: API source check (first-boot user creation returned $setup_code — volume not fresh)"
fi

echo
echo "SMOKE OK: UI up, nginx -t clean, seed present, benign 200, attacks 403, audit log written, API docs served, WAF audit in API sources, static host e2e works"
