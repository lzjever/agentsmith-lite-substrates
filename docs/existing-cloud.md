# Existing Cloud

Existing-cloud mode is for operators who already own the Kubernetes cluster,
PostgreSQL database, object bucket, and JuiceFS CSI installation.

Use `config/substrates.existing-cloud.example.yaml` as the shape. Sensitive
values are read from environment variables named in the config:

```bash
export POSTGRES_APP_URL='postgresql://...'
export JUICEFS_META_URL='postgresql://...'
export S3_ACCESS_KEY='...'
export S3_SECRET_KEY='...'
export APP_SESSION_SECRET='...'

scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/install-online.sh \
  --cache dist/offline-cache \
  --config config/substrates.existing-cloud.example.yaml \
  --output out \
  --dry-run
```

Set `kubernetes.kubeconfigPath` to the existing kubeconfig the operator wants
doctor/live validation to use. `kubernetes.kubeconfigOutput` is for self-hosted
k3s output paths and is not needed for existing-cloud configs.

OIDC/Keycloak auth is deferred. Keep `auth.mode: builtin_admin`; configs with
non-builtin auth fail validation, and generated env contracts reject non-empty
`OIDC_CLIENT_SECRET`.

The generated contract is the same as self-hosted mode. S3 and JuiceFS raw
credentials remain substrate/CSI scoped. App deployment should render only the
product-secret subset and should reference the existing PVC and CSI Secret by
name.

Existing-cloud mode does not create or mutate a self-hosted PostgreSQL Secret or
StatefulSet, and it does not render self-hosted MinIO resources or install k3s.
Live existing-cloud validation uses the same `--cache`/`--offline-cache`
argument and requires a `cacheMode: p1-real` cache. It runs live doctor checks
only: `doctor.sh` creates temporary probe Secret/Job resources for read-only
Postgres `select 1` checks against both `POSTGRES_APP_URL` and
`JUICEFS_META_URL`, plus the S3 object probe against the configured existing
bucket. Probe images come from digest-pinned `name: postgres`,
`name: minio-client`, and `name: rwx-check` entries in `images.lock`, or explicit
`--postgres-probe-image`, `--s3-probe-image`, and `--rwx-check-image` refs. For
JuiceFS, live doctor verifies the existing StorageClass, Secret, and PVC match
the generated env/secrets contract, not only that they exist. Live install
succeeds only when doctor exits 0; exit code 2 (`partial`), including an
unreachable namespace or missing kubectl, fails closed like exit code 1.
