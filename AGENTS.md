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

## Keep Work Install-Led

Keep only code, docs, scripts, and tests that help install, configure, or debug
the local substrate. Delete process-only material instead of renaming it.

- Do not build process artifacts, matrices, archives, or workflow systems around the installer.
- Do not add generic test/script/stage/document concepts detached from install/runtime behavior.
- Do not test tests, output shapes, prose wording, or command wrappers.
- Keep install diagnostics, error output, and logs when they directly help fix the local substrate path.

Install commands and narrow contract checks should fail fast, print concise
stdout/stderr, and exit non-zero. Keep useful checks named after the concrete
install/config/runtime contract they verify, such as `validate-env`,
`validate-juicefs-contract`, or the local provider artifact contract. Run them
only when a developer chooses them for the current change. If something is
wrong, fix the install/config path in place.

## Testing

- Add tests only when they protect a real install/runtime contract.
- Keep concrete checks for install/config/runtime contracts only, such as
  env/secrets, Keycloak/OIDC config, JuiceFS contract, local provider artifact
  behavior, and core shell helper behavior when that helper is directly changed.
- Do not add tests for process documents or workflow wrappers.
- Choose precise, narrow install/config verification for the current change, selected deliberately by the developer.
- Keep only current-change checks tied to the local single-node K8s install path.

## Boundaries

- No third dependency-preparation repo.
- No cloud-provider resource creation for the current delivery target.
- `existing-cloud` and disconnected/offline are optional profiles, not current delivery blockers.
- Keycloak/OIDC is the only production identity path.
- Raw S3 credentials, JuiceFS metadata URLs, Keycloak admin secrets, and bootstrap secrets stay in substrate-owned files/resources unless explicitly transformed into app-owned runtime secrets.
- Do not install or revive AFSCP, ASBCP, LLMUP, JVS, WebDAV, Codex runner core, or file mount/sync systems.
