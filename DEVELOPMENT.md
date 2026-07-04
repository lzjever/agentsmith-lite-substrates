# Development

## Workflow

Use small shell tests before changing behavior:

```bash
scripts/test.sh
```

The current test slices are:

- S1: env/secrets contract, redaction, and secret file mode
- S2: substrate-only doctor and offline cache validation
- S3: JuiceFS CSI Secret, StorageClass, and RWX PVC contract
- S4: guard against copied legacy governance/reference surfaces

## Shell Style

- Scripts are Bash with `set -euo pipefail`.
- Shared functions live in `scripts/lib`.
- Do not source env files containing secrets; parse them as `KEY=VALUE` text.
- Print secret fingerprints only, never raw values.
- Default paths are local and generated under `out/` or `dist/offline-cache/`.

## Idempotency And Safety

- `install-online.sh` and `install-offline.sh` refuse to overwrite generated env files unless `--force` is supplied.
- `reset-dev.sh` requires `--destroy-data` and a self-hosted config.
- Live cluster mutation is intentionally not implemented in this P0 skeleton.
  Scripts report validate-first or dry-run behavior instead of pretending a
  cluster was changed.
