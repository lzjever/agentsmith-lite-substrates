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
export OIDC_CLIENT_SECRET='...'

scripts/install-online.sh \
  --config config/substrates.existing-cloud.example.yaml \
  --output out \
  --dry-run
```

The generated contract is the same as self-hosted mode. S3 and JuiceFS raw
credentials remain substrate/CSI scoped. App deployment should render only the
product-secret subset and should reference the existing PVC and CSI Secret by
name.
