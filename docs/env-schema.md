# Env Schema

The repo has exactly three schema files:

- `schemas/substrate.env.v1.schema.json`
- `schemas/substrate.secrets.env.v1.schema.json`
- `schemas/substrates-config.v1.schema.json`

The shell validator parses env files as `KEY=VALUE` records and enforces the
same key boundary as the schemas.

`schemas/substrates-config.v1.schema.json` is kept aligned with
`scripts/lib/config.sh::validate_config_contract`: required mode-specific config
keys and small enums should be accepted or rejected the same way in both places.
When `kubernetes.distribution` is present it must be `k3s`. For an existing
local kubeconfig, including kind, keep `mode: self-hosted`, set
`kubernetes.skipK3s: true`, and provide a readable
`kubernetes.kubeconfigPath`; do not set `distribution: kind`.
The schema remains intentionally light on unknown keys so operators can carry
future or installer-specific metadata without breaking validation.

For `auth.mode: oidc`, self-hosted config derives the app-facing issuer from
`auth.keycloak.publicBaseUrl` and `auth.realm`, and writes `auth.clientId` to
`OIDC_CLIENT_ID`. It also writes `OIDC_BACKCHANNEL_BASE_URL` as the in-cluster
Keycloak realm URL. Existing-cloud config reads OIDC values from
`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, optional `OIDC_BACKCHANNEL_BASE_URL`, and
`OIDC_CLIENT_SECRET` unless custom `auth.*FromEnv` names are set.
Self-hosted Keycloak DB/bootstrap admin secrets are rendered into
substrate-owned Kubernetes Secrets only; they are not app runtime env fields.
`auth.keycloak.publicBaseUrl` is the browser-facing OIDC issuer identity.
Self-hosted app runtime calls Keycloak through `OIDC_BACKCHANNEL_BASE_URL`,
which substrates generate as the in-cluster Keycloak service realm URL.
Existing-cloud provides an external OIDC issuer and may provide a separate
backchannel URL.

## Non-Secret File

`substrate.env` contains routing and resource names only: namespace,
kubeconfig/context, S3 endpoint metadata, auth mode, JuiceFS StorageClass/PVC
names, ingress settings, and optional registry coordinates.
Self-hosted installs also write a separate `app.env` overlay containing the
local OpenAI-compatible provider base URL and CA ConfigMap reference. App-only
model keys are intentionally not accepted in `substrate.env`.

`kubernetes.kubeconfigPath` in config is normalized to an absolute path relative
to the config file and written to `KUBECONFIG_PATH` as an existing kubeconfig.
If it is empty, `kubernetes.kubeconfigOutput` is normalized the same way and
written as the self-hosted k3s output path. If both are empty,
`KUBECONFIG_PATH` stays empty. A generated self-hosted k3s kubeconfig writes
`KUBE_CONTEXT=default` unless `kubernetes.context` is explicitly configured.
Existing-cloud and `kubernetes.skipK3s: true` configs write `KUBE_CONTEXT` only
from explicit `kubernetes.context`. `kubernetes.skipK3s: true` writes
`KUBERNETES_SKIP_K3S=true` and requires a readable
`kubernetes.kubeconfigPath`. Ingress config is only an app-facing env contract:
`APP_PUBLIC_BASE_URL`, `APP_INGRESS_CLASS`, and `APP_TLS_SECRET_NAME`;
substrates do not install app ingress manifests.

OIDC is the production auth path. `AUTH_MODE=oidc` requires non-empty
`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET`; the issuer must
be an http(s) URL without query or fragment. `OIDC_BACKCHANNEL_BASE_URL` is
optional for existing-cloud and non-empty for self-hosted OIDC.
`AUTH_MODE=builtin_admin` remains for local or transitional use and requires
`BUILTIN_ADMIN_INITIAL_PASSWORD`; the OIDC fields must be empty in that mode.

The static env contract rejects invalid resource names before any live cluster
checks: `KUBE_NAMESPACE`, `JUICEFS_SECRET_NAME`, and `JUICEFS_PVC_NAME` must be
Kubernetes RFC1123 DNS labels; `JUICEFS_STORAGE_CLASS` must be a Kubernetes DNS
subdomain name; `S3_BUCKET` must follow S3 bucket-name shape rules.

## Secret File

`substrate.secrets.env` contains:

- product-secret subset: `POSTGRES_APP_URL`, `APP_SESSION_SECRET`,
  `OIDC_CLIENT_SECRET` for OIDC, or `BUILTIN_ADMIN_INITIAL_PASSWORD` for
  builtin admin
- substrate/CSI scoped values: `S3_ACCESS_KEY`, `S3_SECRET_KEY`,
  `JUICEFS_META_URL`
- substrate-only local Keycloak login: `OIDC_BOOTSTRAP_USERNAME` and
  `OIDC_BOOTSTRAP_PASSWORD`; app runtime Secret/ConfigMap renderers must ignore
  these keys

The validator rejects secret keys in `substrate.env`, rejects unknown keys in
the secret file, rejects duplicate keys in both files, checks owner-only
permissions, requires `APP_SESSION_SECRET` to be at least 32 characters, and
prints fingerprints only.

Self-hosted installs write a separate owner-only `app.secrets.env` overlay with
`AGENTSMITH_LITE_MODEL_API_KEY_LOCAL` for the substrate-owned local provider.
The key is generated or reused from an existing `app.secrets.env` when
reinstalling with `--force`.
