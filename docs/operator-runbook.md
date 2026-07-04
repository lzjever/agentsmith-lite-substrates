# Operator Runbook

## Supported Baseline

The first implementation records the target runtime versions here before full
cluster mutation is enabled:

| Component | Target |
| --- | --- |
| Kubernetes | k3s-compatible Kubernetes 1.30+ |
| kubectl | matching the target cluster minor when possible |
| JuiceFS CSI | `csi.juicefs.com`, version to be pinned in the offline manifest |
| PostgreSQL | 16-compatible product database |
| Object storage | S3-compatible endpoint; MinIO for self-hosted dev |

## Bring-Up

1. Choose a config example from `config/`.
2. Run an installer in validate-first mode.
3. Run `validate-env.sh`.
4. Run `validate-juicefs-contract.sh`.
5. Run `doctor.sh --dry-run`.
6. When live cluster mutation is implemented, rerun doctor without `--dry-run`.

## Doctor Scope

`scripts/doctor.sh` validates substrates only:

- K8s reachability and namespace
- PostgreSQL app URL/connectivity
- S3 credential presence and future object probe
- JuiceFS metadata URL, CSI driver, StorageClass, PVC, and RWX smoke
- offline cache completeness when `--offline-cache` is supplied

App images, app API health, sandbox behavior, and task runtime smoke belong to
the app repo.

Current behavior is intentionally layered:

- `doctor.sh --dry-run` proves static contracts: split env/secrets, configured
  namespace, PostgreSQL URL shape, S3 endpoint/bucket/key presence, rendered
  JuiceFS Secret/StorageClass/PVC, RWX access mode, and optional offline cache.
- `doctor.sh` without `--dry-run` attempts live checks where implemented:
  kubectl namespace reachability, PostgreSQL `select 1` for both
  `POSTGRES_APP_URL` and `JUICEFS_META_URL`, and Kubernetes presence checks for
  JuiceFS StorageClass/Secret/PVC.
- Live S3 read/write/delete, full JuiceFS CSI behavior, and two-pod RWX smoke
  are not fully implemented in this repo yet. When those checks cannot be
  verified, doctor reports `partial` or `failed`; skipped live checks are not
  treated as a green pass.

In an environment without a working kubectl context, live doctor should not be
green. Use `--dry-run` for static contract validation.

## Secret Handling

Generated `out/substrate.secrets.env` must be mode `0600`.
Status output and doctor reports print secret fingerprints only.
S3 raw credentials and `JUICEFS_META_URL` are substrate/CSI scoped inputs; app
workloads should receive PVC and K8s Secret names, not those raw values.
