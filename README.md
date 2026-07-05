# AgentSmith Lite Substrates

Self-hosted substrate installer and offline cache tooling for AgentSmith Lite.
This repo owns Kubernetes substrate validation, dependency service bootstrap
boundaries, JuiceFS CSI setup contracts, and the generated env contract consumed
by the app repo.

## Current Scope

This first public-ready skeleton is validate-first:

- writes and validates split `substrate.env` and `substrate.secrets.env`
- validates secret redaction and owner-only secret file permissions
- writes P0 offline-cache skeletons for contract-only dry-runs
- produces `cacheMode: p1-real` offline caches from a non-secret artifact lock
- includes namespace bootstrap and offline image import helper artifacts in
  p1-real caches
- validates p1-real manifest/checksum/images lock contracts, including required
  bootstrap/import artifacts, cached Helm, and JuiceFS CSI sidecar archives
- performs the p1-real non-dry-run offline chain with cached k3s installer,
  cached OCI import helper, cached kubectl applies, cached Helm chart install,
  and digest-pinned PostgreSQL/MinIO manifests
- renders the self-hosted PostgreSQL Secret, waits for `statefulset/postgres`,
  and initializes/verifies the app DB plus JuiceFS metadata DB/user before any
  JuiceFS format bootstrap
- renders the self-hosted MinIO Secret, waits for `statefulset/minio`, and
  creates/verifies `S3_BUCKET` with the cached MinIO client image
- runs an idempotent `juicefs format` bootstrap Job with the cached
  digest-pinned JuiceFS CSI image before applying the JuiceFS PVC contract and
  waiting for that PVC to reach `Bound`
- installs the cached JuiceFS CSI Helm chart with cached driver and sidecar
  images while leaving StorageClass/Secret/PVC ownership to the substrate
  contract
- validates the rendered JuiceFS CSI Secret, StorageClass, and RWX PVC contract
- provides `scripts/preflight.sh` as a substrate-repo thin wrapper over
  `scripts/doctor.sh --dry-run` for local/static configuration diagnostics
- runs a substrate-only doctor for static dry-run checks and live K8s,
  PostgreSQL, S3 object read/write/delete, JuiceFS PVC, and two-Job RWX smoke
  checks

## Quick Start

```bash
scripts/test.sh

scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/install-online.sh \
  --cache dist/offline-cache \
  --config config/substrates.self-hosted.example.yaml \
  --output out \
  --dry-run

scripts/validate-env.sh \
  --env out/substrate.env \
  --secrets out/substrate.secrets.env

scripts/preflight.sh \
  --env out/substrate.env \
  --secrets out/substrate.secrets.env \
  --cache dist/offline-cache

scripts/doctor.sh \
  --env out/substrate.env \
  --secrets out/substrate.secrets.env \
  --dry-run
```

Live doctor runs the S3 object probe from the cluster network with the
digest-pinned `name: minio-client` image from `--offline-cache
images/images.lock`, or from explicit `--s3-probe-image
image@sha256:<digest>`. It runs the RWX smoke only after the configured JuiceFS
PVC is `Bound`, using `name: rwx-smoke` from the same lock or
`--rwx-smoke-image image@sha256:<digest>`.

For an offline contract skeleton dry-run:

```bash
scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/install-offline.sh \
  --cache dist/offline-cache \
  --config config/substrates.self-hosted.example.yaml \
  --output out \
  --dry-run \
  --force
```

For a real offline cache artifact set:

```bash
cp config/offline-artifacts.example.env config/offline-artifacts.env
# Fill config/offline-artifacts.env with pinned URLs, sha256 values, and image digests.
scripts/download-online.sh \
  --artifacts config/offline-artifacts.env \
  --output dist/offline-cache \
  --force
```

Use that p1-real cache with the online entrypoint when the operator host has
network access but installation should still reuse the substrate dependency
cache:

```bash
scripts/install-online.sh \
  --cache dist/offline-cache \
  --config config/substrates.self-hosted.example.yaml \
  --output out \
  --dry-run
```

`--offline-cache` is accepted as an alias for `--cache`. Dry-run validates the
env contract and cache only. Non-dry-run requires `cacheMode: p1-real`; a
`p0-contract` cache fails instead of pretending to install. In `existing-cloud`
mode, non-dry-run writes the same env files and runs doctor/live validation
without rendering or installing self-hosted PostgreSQL, MinIO, or k3s.

## Config Boundaries

`kubernetes.kubeconfigPath` means an existing kubeconfig path owned by the
operator, most commonly in `existing-cloud` mode. `kubernetes.kubeconfigOutput`
means the path where a self-hosted k3s install should write its generated
kubeconfig. If both are set, `kubeconfigPath` wins; if neither is set,
`KUBECONFIG_PATH` is empty in `substrate.env`.

Substrates do not install an app ingress or reference app Services. The ingress
block only writes the app-facing env contract: `APP_PUBLIC_BASE_URL`,
`APP_INGRESS_CLASS`, and `APP_TLS_SECRET_NAME`. The app repo consumes those
values when it renders app-owned ingress resources.

OIDC/Keycloak auth is deferred. The only valid auth mode in the substrate
contract is `AUTH_MODE=builtin_admin`; non-builtin auth and non-empty
`OIDC_CLIENT_SECRET` are invalid. The v1 env shape may still include empty OIDC
placeholder keys so older consumers can filter them safely.

## Preflight Boundary

`scripts/preflight.sh` is a command in this substrate repo, not a third repo or
external evidence surface. It accepts `--env`, `--secrets`,
`--cache`/`--offline-cache`, and `--report`, then delegates to
`scripts/doctor.sh --dry-run`.

Preflight is static only: it does not run app checks, Botified checks, API smoke,
live kubectl, psql, S3 probes, RWX smoke, Helm, k3s install, downloads, or image
import. It does not replace live doctor, clean-VM install evidence,
disconnected-VM validation, or existing-cloud validation.

## Secret Boundary

`substrate.env` is non-secret and can be attached to support tickets.
`substrate.secrets.env` is owner-only (`0600`) and contains both product secrets
and substrate/CSI setup secrets.

The product-secret subset is `POSTGRES_APP_URL`, `APP_SESSION_SECRET`, and
`BUILTIN_ADMIN_INITIAL_PASSWORD`.
`S3_ACCESS_KEY`, `S3_SECRET_KEY`, and `JUICEFS_META_URL` are substrate/CSI scoped
only. They are used by substrate setup and doctor checks to create or validate
the JuiceFS CSI Secret, metadata database, and one-shot format Job; they must
not be projected into app workload env.

## Main Commands

```bash
scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/download-online.sh --artifacts config/offline-artifacts.env --output dist/offline-cache --force
scripts/install-online.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/install-offline.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/validate-env.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/validate-juicefs-contract.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/preflight.sh --env out/substrate.env --secrets out/substrate.secrets.env --cache dist/offline-cache
scripts/doctor.sh --env out/substrate.env --secrets out/substrate.secrets.env --dry-run
scripts/reset-dev.sh --config config/substrates.self-hosted.example.yaml --destroy-data
```
