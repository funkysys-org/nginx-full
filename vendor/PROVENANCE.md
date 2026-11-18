# Vendoring provenance

This tree is a verbatim vendor of **NginxProxyManager/docker-nginx-full**
at commit **`75b7120`** ("Lua ssl is intermittently failing, attempt to
download 6 times") — the tip that built the openresty base shipped inside
`jc21/nginx-proxy-manager:2.17.0` (image built 2026-11-13; the next upstream
commit `e9cb203` only adds a licence file).

Re-verify on any re-vendoring:

```bash
git clone https://github.com/NginxProxyManager/docker-nginx-full.git
git -C docker-nginx-full checkout 75b7120
diff -r --exclude=.git docker-nginx-full vendor/docker-nginx-full
```

The parity gate (`scripts/parity-check.sh`, oracle in `parity/`) proves at
every build that OUR base produces a byte-identical `nginx -V` signature to
the official image. Upstream commits after the vendor point are
**inspiration, not dependency** — Phase A sovereignty.
