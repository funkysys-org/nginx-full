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
- **A4.2** ✅ (this) — schema debrand: `info.title` → "Proxywarden API",
  description rewritten (no upstream link); `overlay/patches/003-schema-brand.patch`;
  the live schema keeps serving version + server URL per request, stock.
- **A3** — first sovereignty moves (brotli in-base, Node ours to choose)
