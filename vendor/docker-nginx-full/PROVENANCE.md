# docker-nginx-full base vendoring — PROVENANCE

| | |
|---|---|
| Upstream repo | https://github.com/nginxproxymanager/docker-nginx-full |
| Commit | 38654e0738a6c19578e0045678480622e48473878c |
| Vendored | 2026-11-19 (sync: LICENSE e9cb203 + the HTTP/2 security backports d361a16 — CVE-2026-123007, CVE-2026-123633, http2-data-frame-queue) |
| Tree | complete checkout of the commit, minus `.git/` — byte-faithful, ZERO local modifications |
| Build-time security carriage | `docker/patches/`: the upstream h2 backports (part of the commit) + `security-1.31.9-batch.patch` (OUR delta: the verbatim nginx.org 1.31.8→1.31.9 diff, 30 security files, v2/version-bump/CHANGES excluded; applied by `build-openresty.sh` after the h2 patches; superseded by the 1.31.9.x bundle bump) |

## Rules

- NEVER edit this tree in place: deltas ride a build-time patch layer only.
- An upstream sync = replace the tree in ONE reviewable commit (this file's
  Commit row + the workflow `NGINX_FULL_COMMIT` pin move together; the CI
  pins-sync asserts they match).
- The configure-args oracle and the parity gate ride the binary built FROM
  this tree — a sync that changes build inputs (like the security backports)
  must re-run the full pipeline; the args themselves must stay byte-identical
  to the official image's, or the parity gate dies (by design).
