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
export OIDC_ISSUER_URL='https://auth.example.com/realms/agentsmith'
export OIDC_CLIENT_ID='agentsmith-lite'
export OIDC_CLIENT_SECRET='...'

scripts/download-online.sh --contract-only --output dist/offline-cache --force
scripts/install-online.sh \
  --cache dist/offline-cache \
  --config config/substrates.existing-cloud.example.yaml \
  --output out \
  --dry-run
```

Set `kubernetes.kubeconfigPath` to the existing kubeconfig the operator wants
app and substrate commands to use. `kubernetes.kubeconfigOutput` is for
self-hosted k3s output paths and is not needed for existing-cloud configs.

OIDC is the production auth path. `auth.mode: oidc` reads
`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET` by default; set
`auth.issuerUrlFromEnv`, `auth.clientIdFromEnv`, or
`auth.clientSecretFromEnv` only when the operator uses different env names.
`auth.mode: builtin_admin` is still accepted for local or transitional use.
Existing-cloud mode does not install Keycloak; the operator provides an OIDC
issuer/client/secret in the same env/secrets contract that self-hosted emits.

The generated contract is the same as self-hosted mode. S3 and JuiceFS raw
credentials remain substrate/CSI scoped. App deployment should render only the
product-secret subset for the selected auth mode and should reference the
existing PVC and CSI Secret by name.

Existing-cloud mode does not create or mutate a self-hosted PostgreSQL Secret or
StatefulSet, and it does not render self-hosted MinIO resources or install k3s.
Non-dry-run existing-cloud mode still requires a `cacheMode: p1-real` cache and
writes the split env/secrets contract; the operator-owned cluster, database,
bucket, and JuiceFS CSI resources stay outside the installer mutation path.
