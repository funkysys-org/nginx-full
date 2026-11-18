# nginx-full — the funkysys-org base for the proxywarden stack

Phase A of the independence plan: **we own the base image build.** The
`jc21/nginx-proxy-manager` image dependency dies here — replaced by a build
of our own from vendored sources at pinned commits.

## Layering

```
this repo   = vendored docker-nginx-full (openresty + lua + all modules)
              + certbot + node   →  ghcr.io/funkysys-org/nginx-full:certbot-node-or…-node…
      ↑ FROM (A1: app assembly — NPM backend+frontend from pinned source tag v2.17.0)
npm-modsec  (overlay: modsec + vts + purge)
      ↑ FROM
proxywarden (product: branded UI, WAF switches, hardening)
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
- **A1** ✅ (this) — app assembly: NPM source @ v2.17.0 (backend + frontend
  built in-image + rootfs + s6) on our base →
  `ghcr.io/funkysys-org/nginx-full:2.17.0-or1.31.8.1`; smoke: boots, stock
  UI on :81, `nginx -t` clean. Deliberate deviations from upstream's
  assembly: frontend built inside the image; the testca root CA is not
  included (upstream's test harness, not production function)
- **A2** — cutover: `npm-modsec` FROM ours; drift-check inverted
- **A3** — first sovereignty moves (brotli in-base, Node ours to choose)
