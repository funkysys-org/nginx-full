# nginx-full — the funkysys-org base for the proxywarden stack

Phase A of the independence plan: **we own the base image build.** The
`jc21/nginx-proxy-manager` image dependency dies here — replaced by a build
of our own from vendored sources at pinned commits.

## Layering

```
this repo builds the whole base+app+WAF stack:
  base    vendored docker-nginx-full (openresty + lua + all modules)
          → ghcr.io/funkysys-org/nginx-full:certbot-node-or…-node…
    ↑ app assembly (NPM source @ v2.17.0, vendored: backend + frontend + rootfs + s6)
          → :2.17.0-or1.31.8.1
      ↑ WAF overlay (modsec + vts + purge — the former npm-modsec repo, merged)
          → :2.17.0-or1.31.8.1-modsec3.0.17-crs4.30.0-vts0.2.7-purge3.0.4
proxywarden (product: branded UI, WAF switches, hardening) FROMs the WAF image
```

## What this repo guarantees

| Gate | What it proves |
|---|---|
| `pins-sync` | workflow env == vendored bake hcl defaults (no half-bumped pin sets) |
| **parity gate** (`scripts/parity-check.sh`) | our built base produces the SAME `nginx -V` version **and byte-identical configure args** as the official `jc21/nginx-proxy-manager:${NPM_VERSION}` — cross-checked against the committed oracle from spike 001 (`parity/`) |
| Node floor | the Node WE ship ≥ the security floor (`NODE_FLOOR`, Broccoli2Shell) |
| drift-check (weekly) | openresty / NPM-source moved upstream → loud, never auto-rebuilt |

## Pins (ours now)

`OPENRESTY_VERSION` 1.31.8.1 · `NODE_MAJOR` 26 · `LUA_VERSION` 5.1.5 ·
`LUAROCKS_VERSION` 3.13.0 · `NPM_VERSION` 2.17.0 (app layer, A1) —
mirrored between workflow env and the vendored `docker-bake.hcl`.

## Vendoring

Verbatim from `NginxProxyManager/docker-nginx-full` @ `75b7120` — see
`vendor/PROVENANCE.md`. Upstream after that commit is inspiration, not
dependency.

## Roadmap (Phase A)

- **A0** ✅ — vendoring, pins, CI with parity gate
- **A1** ✅ — app assembly (NPM source @ v2.17.0) on our base; app smoke
- **A2** ✅ — cutover: npm-modsec built FROM our parity-gated base
- **A2b** ✅ — the WAF layer merged into this pipeline
  (`overlay/Dockerfile` + `modsec/` + `rootfs-s6/` + WAF smoke); one repo,
  one pin set, one drift-check; the ABI assertion stays as an internal gate.
  `npm-modsec` is superseded — to be archived once proxywarden re-pins here
- **A4** ✅ (this) — NPM source **vendored**: `vendor/npm/` is the pinned
  tag `v2.17.0` (byte-faithful, `PROVENANCE.md`-gated: pins-sync asserts
  `NPM_COMMIT` == the vendored sha). `app/Dockerfile` builds from `COPY
  vendor/npm/` — **zero build-time clone of jc21's repo**. The backend
  patch layer (WAF-audit as 4th log source, ex-proxywarden F4) moved into
  `overlay/patches/` — applied build-time on the vendored tree, validated
  by `git apply --check`, shipped via the same COPY assembly upstream uses.
  The WAF image's backend is ours now; proxywarden is pure frontend.
  Upstream NPM sync = human ritual: diff the new tag into `vendor/npm/` in
  one reviewable commit + bump pins + re-validate the patch set
- **A4.1** ✅ — first backend patch-layer feature: `GET /api/docs` serves
  a Swagger UI shell (`swagger-ui-dist@5.35.0` from unpkg, exact-pinned,
  one-line bump) rendered against the LIVE OpenAPI 3.1 schema — which stays
  the single source of truth at `GET /api/schema` (version + server URL
  injected per request, exactly like stock). `overlay/patches/002-api-docs.patch`;
  same exposure class as the schema itself (both unauthenticated, like
  stock — bind :81 local if that bothers you).
- **A4.2** ✅ — schema debrand: `info.title` → "Proxywarden API",
  description rewritten (no upstream link); `overlay/patches/003-schema-brand.patch`;
  the live schema keeps serving version + server URL per request, stock.
- **A5** ✅ (this) — **Static Hosts**: the 5th host family (proxy, redirect,
  404, stream + **static**), a full-stack feature through the patch layer:
  `overlay/patches/004-static-host.patch` — model + migration (first
  migration of the layer; also adds `user_permission.static_hosts`), internal
  service (DB is the source of truth; `/data/nginx/static_host/<id>/index.html`
  is a derived artifact regenerated on every save/enable), route, nunjucks
  template (`root` + `try_files /index.html =404`), 9 OpenAPI schema files
  (endpoints visible in `/api/docs`), certificate/permissions/hostname-collision
  integration, and ONE added include line in the stock main nginx.conf.
  WAF rides along: `{{ advanced_config }}` in the template. WAF smoke gains
  the e2e: create via API → serves content on :80 → delete.
- **A6** ✅ — Metrics: vts counters enabled at http level (image conf) + a
  127.0.0.1-only display location on the admin server; the backend reads it
  and re-serves it JWT-gated at `GET /reports/metrics`, **scoped by the
  caller's host visibility** (the same scopeToOwnerOrAllowed semantics);
  recharts UI (006/007 in proxywarden).
- **A7** ✅ (this) — **LDAP auth**: login tries LOCAL first (an LDAP outage
  can never lock out local admins), falls back to service-bind → search →
  user-bind; first-login provisioning with the same user shape the admin
  create flow produces; config in the `ldap-auth` setting (seeded disabled,
  admin-edited); `ldapts@9.3.1` — the first runtime dep added by the patch
  layer, reconciled into node_modules in the overlay (the app image stays
  stock). Anti-enumeration preserved: every failure is the same generic
  auth error.
- **A8** ✅ (this) — the operator wave: **2FA policy** (non-admin logins
  blocked without TOTP; admins exempt by design), **document_root** for
  static hosts (serve a mounted tree; path gate in the value-validator,
  traversal-proof), **WAF tuning API** (exclusions + paranoia level, panel
  side of the canary runbook), **WAF activity report** (audit-log
  aggregation, per-user scoped), **geoblocking** (see below). Login rate
  limiting was verified as already present upstream — not rebuilt.
- **Geoblocking**: `country_deny` on proxy hosts and static hosts (ISO
  3166-1 alpha-2 codes, schema + render-time gated). The geoip2 module is
  compiled into the image (parity configure args); the lookup is ARMED by
  the s6 `geoip2-arm` oneshot when a GeoLite2 Country DB exists at
  `/data/geoip/GeoLite2-Country.mmdb` — without it, hosts with country
  rules stay renderable and the field stays stored (dormant). To arm:
  drop the DB there (or run the official updater sidecar) and restart:

  ```yaml
  # docker-compose.geoip.yml — docker compose -f docker-compose.yml -f docker-compose.geoip.yml up -d
  services:
    geoipupdate:
      image: maxmindinc/geoipupdate:latest   # pin a tag in production
      restart: unless-stopped
      environment:
        GEOIPDB_ACCOUNT_ID: ${MAXMIND_ACCOUNT_ID}
        GEOIPDB_LICENSE_KEY: ${MAXMIND_LICENSE_KEY}
        GEOIPDB_EDITION_IDS: GeoLite2-Country
        GEOIPDB_FREQUENCY: 168               # weekly, hours
      volumes:
        - proxywarden_geoip:/usr/local/share/GeoIP
    proxywarden:
      volumes:
        - proxywarden_geoip:/data/geoip:ro
  volumes:
    proxywarden_geoip: {}
  ```

  After arming (or at first boot with the DB in place), re-save hosts that
  carry country rules so their config regenerates with the `if()` lines.

