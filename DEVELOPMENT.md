# Development

## Workflow

Use small shell tests before changing behavior:

```bash
scripts/test.sh
```

The current test slices are intentionally small:

- env/secrets contract, redaction, and secret file mode
- contract-only offline cache plus `install-online.sh --dry-run`
- p1-real offline cache contract and self-hosted Keycloak render path
- rendered JuiceFS CSI Secret, StorageClass, and RWX PVC contract
- self-hosted install apply, rollout, one-shot Job, and PVC `Bound` checks
  through a kubectl stub

## Shell Style

- Scripts are Bash with `set -euo pipefail`.
- Shared functions live in `scripts/lib`.
- Do not source env files containing secrets; parse them as `KEY=VALUE` text.
- Print secret fingerprints only, never raw values.
- Default paths are local and generated under `out/` or `dist/offline-cache/`.

## Idempotency And Safety

- `install-online.sh` and `install-offline.sh` refuse to overwrite generated env files unless `--force` is supplied.
- `reset-dev.sh` requires `--destroy-data` and a self-hosted config.
- P0 skeletons remain dry-run/contract-only. p1-real offline install performs
  the minimum cached k3s/import/kubectl apply chain, self-hosted PostgreSQL and
  MinIO bootstrap, cached JuiceFS CSI Helm chart install, idempotent JuiceFS
  format, PVC `Bound` wait, local provider readiness, and self-hosted Keycloak
  bootstrap.
- The default `download-online.sh` output is still a P0 static contract
  skeleton. It is useful for contract generation and dry-run validation only.
- A p1-real offline cache must be supplied with all required artifacts and
  checksums before it can satisfy the p1-real contract.
