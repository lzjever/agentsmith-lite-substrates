# AgentSmith Lite Substrates

Self-hosted substrate installer and offline cache tooling for AgentSmith Lite.
This repo owns Kubernetes substrate validation, dependency service bootstrap
boundaries, JuiceFS CSI setup contracts, and the generated env contract consumed
by the app repo.

## Current Scope

This first public-ready skeleton is validate-first:

- writes and validates split `substrate.env` and `substrate.secrets.env`
- writes self-hosted app overlay files `app.env` and `app.secrets.env` for the
  local OpenAI-compatible provider without adding app-only keys to
  `substrate.env`
- validates secret redaction and owner-only secret file permissions
- writes P0 offline-cache skeletons for contract-only dry-runs
- produces `cacheMode: p1-real` offline caches from a non-secret artifact lock
- provides `scripts/prepare-offline-cache.sh` as a thin one-command helper that
  downloads fixed-version substrate artifacts, resolves/export images with
  `skopeo`, writes `out/artifacts/offline-artifacts.env`, and calls the
  p1-real producer
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
- renders self-hosted Keycloak from the same OIDC env contract, uses the
  existing PostgreSQL service for the Keycloak DB, waits for `deployment/keycloak`,
  and bootstraps the realm/client with a one-shot cached Keycloak Job
- renders a substrate-owned HTTPS OpenAI-compatible local provider, including
  generated local CA/server TLS Secret, API key Secret, CA ConfigMap, Service
  port 443, and Deployment
- installs the cached JuiceFS CSI Helm chart with cached driver and sidecar
  images while leaving StorageClass/Secret/PVC ownership to the substrate
  contract
- validates the rendered JuiceFS CSI Secret, StorageClass, and RWX PVC contract
- uses installer-local apply, rollout, Job, and PVC wait checks for the
  self-hosted Kubernetes path

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
```

Non-dry-run self-hosted install fails in place when cached k3s/image import,
Helm install, kubectl apply, rollout status, one-shot bootstrap Jobs, or the
configured JuiceFS PVC `Bound` wait fails.

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
scripts/prepare-offline-cache.sh \
  --artifacts-dir out/artifacts \
  --output dist/offline-cache \
  --force
```

The generated `out/artifacts/offline-artifacts.env` lock is local output and
should not be committed. To supply a hand-maintained lock instead:

```bash
scripts/download-online.sh \
  --artifacts config/offline-artifacts.env \
  --output dist/offline-cache \
  --force
```

The generated cache manifest shape is illustrated by
`config/offline-cache-manifest.example.yaml`. The `dist/offline-cache/` path is
download-owned generated output.

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
mode, non-dry-run writes the same env files without rendering or installing
self-hosted PostgreSQL, MinIO, or k3s.

## Config Boundaries

`kubernetes.kubeconfigPath` means an existing kubeconfig path owned by the
operator, most commonly in `existing-cloud` mode. `kubernetes.kubeconfigOutput`
means the path where a self-hosted k3s install should write its generated
kubeconfig. If both are set, `kubeconfigPath` wins; if neither is set,
`KUBECONFIG_PATH` is empty in `substrate.env`. `KUBE_CONTEXT` is emitted only
when `kubernetes.context` is explicitly configured.

Substrates do not install an app ingress or reference app Services. The ingress
block only writes the app-facing env contract: `APP_PUBLIC_BASE_URL`,
`APP_INGRESS_CLASS`, and `APP_TLS_SECRET_NAME`. The app repo consumes those
values when it renders app-owned ingress resources.

OIDC/Keycloak is the production auth path. `AUTH_MODE=oidc` uses the existing
`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` env contract.
Self-hosted config derives the issuer from
`auth.keycloak.publicBaseUrl` + `auth.realm`; existing-cloud config reads the
same OIDC values from env by default. `AUTH_MODE=builtin_admin` remains for
local or transitional use and requires empty OIDC fields.
In self-hosted OIDC mode, substrates install Keycloak as the auth provider.
They also emit `OIDC_BACKCHANNEL_BASE_URL` as
`http://keycloak.<namespace>.svc.cluster.local:8080/realms/<realm>` and create
or update the substrate-owned local login from `OIDC_BOOTSTRAP_USERNAME` and
`OIDC_BOOTSTRAP_PASSWORD`.
Existing-cloud mode does not install Keycloak; it supplies the same app-facing
OIDC env/secrets contract from operator-owned identity infrastructure and may
read `OIDC_BACKCHANNEL_BASE_URL` from env.
`auth.keycloak.publicBaseUrl` is the browser-facing OIDC issuer identity.
Self-hosted app runtime calls Keycloak through `OIDC_BACKCHANNEL_BASE_URL`,
which substrates generate as the in-cluster Keycloak service realm URL.
Existing-cloud provides an external OIDC issuer and may provide a separate
backchannel URL.

## Secret Boundary

`substrate.env` is non-secret and can be attached to support tickets.
`substrate.secrets.env` is owner-only (`0600`) and contains both product secrets
and substrate/CSI setup secrets.

The product-secret subset is `POSTGRES_APP_URL`, `APP_SESSION_SECRET`, and the
selected auth secret: `OIDC_CLIENT_SECRET` for OIDC or
`BUILTIN_ADMIN_INITIAL_PASSWORD` for builtin admin.
`S3_ACCESS_KEY`, `S3_SECRET_KEY`, and `JUICEFS_META_URL` are substrate/CSI scoped
only. They are used by substrate setup to create the JuiceFS CSI Secret,
metadata database, and one-shot format Job; they must not be projected into app
workload env.
`OIDC_BOOTSTRAP_USERNAME` and `OIDC_BOOTSTRAP_PASSWORD` are substrate-only
operator/local login credentials for self-hosted Keycloak and must not be
projected into app runtime Secret/ConfigMap resources.
Self-hosted Keycloak DB and bootstrap admin secrets are rendered only into
substrate-owned Kubernetes Secrets and are not added to the app env contract.
Self-hosted installs also write `app.env` with
`AGENTSMITH_LITE_MODEL_BASE_URL_LOCAL`,
`AGENTSMITH_LITE_MODEL_CA_CONFIG_MAP`, and
`AGENTSMITH_LITE_MODEL_CA_CONFIG_KEY`, plus owner-only `app.secrets.env` with
`AGENTSMITH_LITE_MODEL_API_KEY_LOCAL`. These are app overlay files, not
substrate env keys.

## Main Commands

```bash
scripts/prepare-offline-cache.sh --artifacts-dir out/artifacts --output dist/offline-cache --force
scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/download-online.sh --artifacts config/offline-artifacts.env --output dist/offline-cache --force
scripts/install-online.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/install-offline.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/validate-env.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/validate-juicefs-contract.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/reset-dev.sh --config config/substrates.self-hosted.example.yaml --destroy-data
```
