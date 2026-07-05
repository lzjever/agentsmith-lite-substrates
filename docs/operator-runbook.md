# Operator Runbook

## Supported Baseline

The first implementation records the target runtime versions here before full
cluster mutation is enabled:

| Component | Target |
| --- | --- |
| Kubernetes | k3s-compatible Kubernetes 1.30+ |
| kubectl | matching the target cluster minor when possible |
| JuiceFS CSI | `csi.juicefs.com`, default chart/image version `0.31.10` |
| PostgreSQL | 16-compatible product database |
| Object storage | S3-compatible endpoint; MinIO for self-hosted dev |

## Bring-Up

1. Choose a config example from `config/`.
2. For a real offline cache, run `scripts/prepare-offline-cache.sh
   --artifacts-dir out/artifacts --output dist/offline-cache --force` on an
   online host. Keep `out/artifacts/offline-artifacts.env` and the `file://`
   artifact staging output uncommitted.
3. Run an installer in validate-first mode.
4. Run `validate-env.sh`.
5. Run `validate-juicefs-contract.sh`.
6. Run `preflight.sh` or `doctor.sh --dry-run` for static substrate checks.
7. When the cluster is reachable, rerun doctor without `--dry-run` and provide
   either `--offline-cache` with `name: postgres`, `name: minio-client`, and
   `name: rwx-smoke` in `images.lock`, or explicit `--postgres-probe-image`,
   `--s3-probe-image`, and `--rwx-smoke-image` digest-pinned image refs.

## Doctor Scope

`scripts/doctor.sh` validates substrates only:

- K8s reachability and namespace
- PostgreSQL app and JuiceFS metadata URL/connectivity through read-only probe
  Jobs
- S3 credential presence and read/write/delete object probe
- JuiceFS metadata URL, CSI driver, StorageClass, PVC, and RWX smoke
- offline cache completeness when `--offline-cache` is supplied

App images, app API health, sandbox behavior, and task runtime smoke belong to
the app repo.

Current behavior is intentionally layered:

- `preflight.sh` is a substrate-repo command, not a third repo and not an
  external evidence surface. It accepts `--env`, `--secrets`,
  `--cache`/`--offline-cache`, and `--report`, then delegates to
  `doctor.sh --dry-run`.
- `doctor.sh --dry-run` proves static contracts: split env/secrets, configured
  namespace, PostgreSQL URL shape, S3 endpoint/bucket/key presence, rendered
  JuiceFS Secret/StorageClass/PVC, RWX access mode, and optional offline cache.
- `doctor.sh` without `--dry-run` attempts live checks where implemented:
  kubectl namespace reachability, PostgreSQL `select 1` for both
  `POSTGRES_APP_URL` and `JUICEFS_META_URL` from temporary Jobs, an S3
  read/write/delete probe from a temporary Job, Kubernetes presence checks for
  the provider-owned JuiceFS CSIDriver plus JuiceFS StorageClass/Secret/PVC, the
  PVC phase being `Bound`, and a two-Job RWX smoke that mounts the configured
  PVC from writer and reader Jobs.
- If `KUBECONFIG_PATH` is configured for live doctor, it must point to a
  readable file before any kubectl-backed Postgres, S3, or RWX mutation probe
  can run.
- Checks that cannot be verified are reported as `partial` or `failed`; skipped
  live checks are not treated as a green pass. If the cluster is reachable, a
  missing, mutable, or app-owned Postgres/S3/RWX probe image is a failure before
  creating that probe's Job.

In an environment without a working kubectl context, live doctor should not be
green. Use `--dry-run` for static contract validation.

Preflight does not run app checks, Botified checks, API smoke, live kubectl,
Postgres/S3/RWX probes, Helm, k3s install, downloads, or image import. It does
not replace live doctor, clean-VM install evidence, disconnected-VM validation,
or existing-cloud validation.

## Secret Handling

Generated `out/substrate.secrets.env` must be mode `0600`.
Status output and doctor reports print secret fingerprints only.
S3 raw credentials and `JUICEFS_META_URL` are substrate/CSI scoped inputs; app
workloads should receive PVC and K8s Secret names, not those raw values.
