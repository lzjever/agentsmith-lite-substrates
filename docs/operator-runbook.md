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
| Auth | Keycloak for self-hosted OIDC; external OIDC for existing-cloud |

## Targeted Bring-Up Commands

Use these as developer-selected commands for the install/config path currently
being changed. They are not a default release gate or broad all-clear proof.

1. Choose a config example from `config/`.
2. For a real offline cache, run `scripts/prepare-offline-cache.sh
   --artifacts-dir out/artifacts --output dist/offline-cache --force` on an
   online host. Keep `out/artifacts/offline-artifacts.env` and the `file://`
   artifact staging output uncommitted.
3. Run an installer in validate-first mode.
4. Run `validate-env.sh`.
5. Run `validate-juicefs-contract.sh`.
6. For a self-hosted p1-real install, run the installer only when the operator
   intends to mutate the selected cluster; it fails in place on cached k3s/image
   import, Helm install, kubectl apply, rollout, one-shot Job, or PVC wait
   failures.

App images, app API readiness, sandbox behavior, and task runtime checks belong
to the app repo.

## Secret Handling

Generated `out/substrate.secrets.env` must be mode `0600`.
Status output prints secret fingerprints only.
S3 raw credentials and `JUICEFS_META_URL` are substrate/CSI scoped inputs; app
workloads should receive PVC and K8s Secret names, not those raw values.
