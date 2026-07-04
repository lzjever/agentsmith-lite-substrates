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
  bootstrap/import artifacts
- validates the rendered JuiceFS CSI Secret, StorageClass, and RWX PVC contract
- runs a substrate-only doctor for static dry-run checks and partial live checks

It does not yet mutate a cluster by installing k3s, PostgreSQL, MinIO, or
JuiceFS CSI. Scripts say that clearly when they skip live mutation.

## Quick Start

```bash
scripts/test.sh

scripts/install-online.sh \
  --config config/substrates.self-hosted.example.yaml \
  --output out \
  --dry-run

scripts/validate-env.sh \
  --env out/substrate.env \
  --secrets out/substrate.secrets.env

scripts/doctor.sh \
  --env out/substrate.env \
  --secrets out/substrate.secrets.env \
  --dry-run
```

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

## Secret Boundary

`substrate.env` is non-secret and can be attached to support tickets.
`substrate.secrets.env` is owner-only (`0600`) and contains both product secrets
and substrate/CSI setup secrets.

The product-secret subset is `POSTGRES_APP_URL`, `APP_SESSION_SECRET`,
`BUILTIN_ADMIN_INITIAL_PASSWORD`, and OIDC/admin secrets when enabled.
`S3_ACCESS_KEY`, `S3_SECRET_KEY`, and `JUICEFS_META_URL` are substrate/CSI scoped
only. They are used by substrate setup and doctor checks to create or validate
the JuiceFS CSI Secret; they must not be projected into app workload env.

## Main Commands

```bash
scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/download-online.sh --artifacts config/offline-artifacts.env --output dist/offline-cache --force
scripts/install-online.sh --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/install-offline.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ --dry-run
scripts/validate-env.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/validate-juicefs-contract.sh --env out/substrate.env --secrets out/substrate.secrets.env
scripts/doctor.sh --env out/substrate.env --secrets out/substrate.secrets.env --dry-run
scripts/reset-dev.sh --config config/substrates.self-hosted.example.yaml --destroy-data
```
