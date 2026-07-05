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
  install script, k3s airgap archive, kubectl/Helm binaries, dependency OCI
  archives, JuiceFS CSI artifact, CSI sidecar image archives, the `rwx-smoke`
  OCI archive, and `images.lock` archive sha256 validation
- S6: rendered JuiceFS CSI contract, cross-checking env-rendered namespace,
  secretName, storageClass, pvcName, ReadWriteMany, and bucket URL
- S7: doctor dry-run/live layering; dry-run proves static contracts, while live
  kubectl/cluster checks observe reachable resources, Postgres `select 1` via
  the cached `postgres` image, JuiceFS PVC `Bound`, S3 object read/write/delete
  via the cached `minio-client` image, and two-Job RWX behavior when a
  digest-pinned smoke image is available

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
  MinIO bootstrap, cached JuiceFS CSI Helm chart install, and idempotent JuiceFS
  format. Live doctor then runs the Postgres probe from cached `postgres`, the
  S3 probe from cached `minio-client`, and the RWX smoke from cached
  `rwx-smoke` after the JuiceFS PVC is `Bound`.
- The default `download-online.sh` output is still a P0 static contract
  skeleton. It is useful for contract generation and dry-run validation only.
- A p1-real offline cache must be supplied with all required artifacts and
  checksums before it can satisfy the p1-real contract.
