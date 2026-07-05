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
- S5: `cacheMode: p1-real` offline cache contract, including k3s binary,
  install script, k3s airgap archive, kubectl binary, dependency OCI archives,
  JuiceFS CSI artifact, and `images.lock` archive sha256 validation
- S6: rendered JuiceFS CSI contract, cross-checking env-rendered namespace,
  secretName, storageClass, pvcName, ReadWriteMany, and bucket URL
- S7: doctor dry-run/live layering; dry-run proves static contracts, while live
  unverifiable kubectl/cluster/psql/S3/JuiceFS/RWX checks are partial or failed

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
  MinIO bootstrap, and idempotent JuiceFS format. Live JuiceFS CSI driver
  install and RWX smoke remain open.
- The default `download-online.sh` output is still a P0 static contract
  skeleton. It is useful for contract generation and dry-run validation only.
- A p1-real offline cache must be supplied with all required artifacts and
  checksums before it can satisfy the p1-real contract.
