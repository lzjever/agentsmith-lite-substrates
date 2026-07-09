# Agent Instructions For `agentsmith-lite-substrates`

## Focus

This repo owns the local single-node K8s substrate:

- k3s bootstrap;
- PostgreSQL setup and app database URL;
- S3-compatible storage access;
- JuiceFS CSI install and PVC contract;
- Keycloak install, realm/client/user bootstrap, OIDC issuer/client output;
- namespace, quota, StorageClass, PVC, and dev ingress resources;
- `substrate.env`, `substrate.secrets.env`, and `kubeconfig`.

The repo exists to make the product run locally on K8s. Do not turn it into an operations governance system.

## Delete Governance Overhead

Remove governance overhead aggressively:

- process bureaucracy unrelated to install/runtime behavior;
- generated diagnostic documents;
- output-only flags and output-shape tests;
- umbrella validation commands detached from core install paths;
- one-size-fits-all install proof labels detached from install/config contracts;
- tests of the test harness;
- broad fake test sets that do not protect core install/runtime behavior.

Install commands and narrow contract checks should fail fast, print concise
stdout/stderr, and exit non-zero. If something is wrong, fix the install/config
path in place.

## Testing

- Keep `scripts/test.sh` focused on install inputs, env/secrets, Keycloak config, JuiceFS contract, and core shell behavior.
- Add tests only when they protect a real install/runtime contract.
- Do not add tests for diagnostic document formats or release workflows.
- Choose the minimum install/config contract verification for the current change; do not run long, unrelated, or umbrella install checks by default.

## Boundaries

- No third dependency-preparation repo.
- No cloud-provider resource creation for the current delivery target.
- `existing-cloud` and disconnected/offline are optional profiles, not current delivery blockers.
- Keycloak/OIDC is the only production identity path.
- Raw S3 credentials, JuiceFS metadata URLs, Keycloak admin secrets, and bootstrap secrets stay in substrate-owned files/resources unless explicitly transformed into app-owned runtime secrets.
- Do not install or revive AFSCP, ASBCP, LLMUP, JVS, WebDAV, Codex runner core, or file mount/sync systems.
