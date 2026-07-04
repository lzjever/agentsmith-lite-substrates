# Env Schema

The repo has exactly three schema files:

- `schemas/substrate.env.v1.schema.json`
- `schemas/substrate.secrets.env.v1.schema.json`
- `schemas/substrates-config.v1.schema.json`

The shell validator parses env files as `KEY=VALUE` records and enforces the
same key boundary as the schemas.

## Non-Secret File

`substrate.env` contains routing and resource names only: namespace,
kubeconfig/context, S3 endpoint metadata, auth mode, JuiceFS StorageClass/PVC
names, ingress settings, and optional registry coordinates.

## Secret File

`substrate.secrets.env` contains:

- product-secret subset: `POSTGRES_APP_URL`, `APP_SESSION_SECRET`,
  `BUILTIN_ADMIN_INITIAL_PASSWORD`, `OIDC_CLIENT_SECRET`
- substrate/CSI scoped values: `S3_ACCESS_KEY`, `S3_SECRET_KEY`,
  `JUICEFS_META_URL`

The validator rejects secret keys in `substrate.env`, rejects unknown keys in
the secret file, checks owner-only permissions, and prints fingerprints only.
