# Offline Install

`scripts/download-online.sh` has two producer modes:

- no `--artifacts`, or explicit `--contract-only`: writes a P0 offline cache
  skeleton
- `--artifacts <artifact-lock-env>`: downloads pinned dependency artifacts and
  writes a `cacheMode: p1-real` offline cache

```text
dist/offline-cache/
  manifest.yaml
  checksums.txt
  bin/
    k3s
    kubectl
    helm
  charts/
    juicefs-csi.tgz
  images/
    images.lock
    k3s/
      k3s-airgap-images-amd64.tar.zst
    oci/
      postgres.tar
      minio.tar
      minio-client.tar
      juicefs-csi.tar
      juicefs-csi-liveness-probe.tar
      juicefs-csi-node-driver-registrar.tar
      juicefs-csi-provisioner.tar
      juicefs-csi-resizer.tar
      rwx-smoke.tar
  manifests/
    namespace-bootstrap/
      namespace.yaml
  scripts/
    install-k3s.sh
    import-images.sh
```

## P0 Skeleton

The default downloader output remains `cacheMode: p0-contract`. It is a
network-free static contract skeleton for dry-run validation only. Use
`--contract-only` when you want that behavior to be explicit:

```bash
scripts/download-online.sh --contract-only --output dist/offline-cache --force
```

The P0 skeleton does not contain a k3s binary, k3s install script, k3s airgap
image archive, kubectl binary, dependency OCI image archives, or a JuiceFS CSI
artifact. It does include a namespace bootstrap manifest and a placeholder
`scripts/import-images.sh`, but it is not a real offline install cache.

## p1-real Producer

Create a non-secret artifact lock from `config/offline-artifacts.example.env`.
The example is a template only; every URL, sha256, and image digest must be
replaced with pinned release values before use.

```bash
scripts/download-online.sh \
  --artifacts config/offline-artifacts.env \
  --output dist/offline-cache \
  --force
```

Required artifact lock keys:

- `K3S_BINARY_URL` / `K3S_BINARY_SHA256`
- `K3S_INSTALL_SCRIPT_URL` / `K3S_INSTALL_SCRIPT_SHA256`
- `K3S_AIRGAP_IMAGES_URL` / `K3S_AIRGAP_IMAGES_SHA256`
- `KUBECTL_BINARY_URL` / `KUBECTL_BINARY_SHA256`
- `HELM_BINARY_URL` / `HELM_BINARY_SHA256`
- `JUICEFS_CSI_ARTIFACT_URL` / `JUICEFS_CSI_ARTIFACT_SHA256`
- `POSTGRES_IMAGE` / `POSTGRES_ARCHIVE_URL` / `POSTGRES_ARCHIVE_SHA256`
- `MINIO_IMAGE` / `MINIO_ARCHIVE_URL` / `MINIO_ARCHIVE_SHA256`
- `MINIO_CLIENT_IMAGE` / `MINIO_CLIENT_ARCHIVE_URL` /
  `MINIO_CLIENT_ARCHIVE_SHA256`
- `JUICEFS_CSI_IMAGE` / `JUICEFS_CSI_ARCHIVE_URL` /
  `JUICEFS_CSI_ARCHIVE_SHA256`
- `JUICEFS_CSI_LIVENESS_PROBE_IMAGE` /
  `JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL` /
  `JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_SHA256`
- `JUICEFS_CSI_NODE_DRIVER_REGISTRAR_IMAGE` /
  `JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL` /
  `JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_SHA256`
- `JUICEFS_CSI_PROVISIONER_IMAGE` / `JUICEFS_CSI_PROVISIONER_ARCHIVE_URL` /
  `JUICEFS_CSI_PROVISIONER_ARCHIVE_SHA256`
- `JUICEFS_CSI_RESIZER_IMAGE` / `JUICEFS_CSI_RESIZER_ARCHIVE_URL` /
  `JUICEFS_CSI_RESIZER_ARCHIVE_SHA256`
- `RWX_SMOKE_IMAGE` / `RWX_SMOKE_ARCHIVE_URL` /
  `RWX_SMOKE_ARCHIVE_SHA256`

Image refs must be digest-pinned with `@sha256:<64 lowercase hex>`. The producer
rejects mutable tags, missing required keys, invalid sha256 values, sha
mismatches, app-owned images, and Botified runner images. JuiceFS CSI driver and
CSI sidecar image refs must include a tag before the digest, such as
`repository/name:v1.2.3@sha256:<digest>`, because the Helm chart consumes
separate `repository` and `tag` values. It writes
`manifest.yaml`, `checksums.txt`, `images/images.lock`, a namespace bootstrap
manifest, and an offline `scripts/import-images.sh` helper without public
download URLs in the cache manifest. The generated import helper uses the
cache's executable `bin/k3s ctr`; it does not require or invoke a host `ctr`
from `PATH`.

## Online Entry With an Existing Cache

`scripts/install-online.sh` accepts the same substrate cache with `--cache` or
`--offline-cache`. This entrypoint does not download app images or copy the
offline install chain; it validates the cache and env contract, then reuses the
p1-real install functions.

```bash
scripts/install-online.sh \
  --cache dist/offline-cache \
  --config config/substrates.self-hosted.example.yaml \
  --output out \
  --dry-run
```

Dry-run validates env/cache and skips cluster mutation. Without `--dry-run`, a
`p0-contract` cache fails immediately. For `mode: self-hosted`, a p1-real cache
runs the cached k3s/import/kubectl/Helm chain. For `mode: existing-cloud`, it
writes `substrate.env` and `substrate.secrets.env`, then runs doctor/live
validation only; it does not render or install self-hosted PostgreSQL, MinIO, or
k3s.

## p1-real Cache

When a produced or supplied cache declares `cacheMode: p1-real`, validation
requires:

- `bin/k3s` with manifest kind `k3s-binary`
- `scripts/install-k3s.sh` with manifest kind `k3s-install-script`
- `images/k3s/k3s-airgap-images-amd64.tar.zst` with manifest kind
  `k3s-airgap-images`
- `bin/kubectl` with manifest kind `kubectl-binary`
- `bin/helm` with manifest kind `helm-binary`
- `scripts/import-images.sh` with manifest kind `script` and executable mode
- `manifests/namespace-bootstrap/namespace.yaml` with manifest kind `manifest`
- `images/images.lock` with manifest kind `images-lock`
- `charts/juicefs-csi.tgz` with manifest kind `juicefs-csi-artifact`
- dependency image entries for PostgreSQL, MinIO, MinIO client, JuiceFS CSI,
  the JuiceFS CSI liveness probe, node-driver-registrar, provisioner, and
  resizer sidecars, and the `rwx-smoke` Job image
- digest-pinned image references
- archive paths and per-archive sha256 values in `images.lock`

`scripts/install-offline.sh` never downloads from public locations. It first
validates:

- `manifest.yaml` schema version
- `checksums.txt` entries and file digests
- `images/images.lock` schema version
- digest-pinned image references
- archive paths and sha256 values listed in `images.lock`
- no public download URL fields in the cache manifest

Then it writes `out/substrate.env` and `out/substrate.secrets.env`, validates the
split contract, and clearly skips cluster mutation in `--dry-run`.

Without `--dry-run`, a P0 skeleton fails immediately as not installable. A
p1-real cache runs the cached `scripts/install-k3s.sh` with offline download
guards, runs the cached `scripts/import-images.sh`, renders the namespace
bootstrap to `${output}/rendered/offline-install/namespace.yaml` with
`metadata.name` set from `KUBE_NAMESPACE`, applies it with `bin/kubectl`,
renders the JuiceFS CSI Secret plus StorageClass/PVC contract, renders
non-secret JuiceFS CSI Helm values, installs
the cached `charts/juicefs-csi.tgz` with cached `bin/helm`, renders and applies
the self-hosted PostgreSQL Secret before the PostgreSQL StatefulSet, waits for
`statefulset/postgres`, initializes/verifies the app DB and JuiceFS metadata
DB/user through `kubectl exec -i ... psql` stdin SQL, renders/applies the MinIO
Secret before the MinIO StatefulSet, waits for `statefulset/minio`,
creates/verifies `S3_BUCKET` with a one-shot MinIO client Job, deletes that Job,
runs an idempotent JuiceFS format Job with the cached digest-pinned JuiceFS CSI
image, applies the StorageClass/PVC contract only after the format Job reports a
matching volume, waits for the configured JuiceFS PVC to reach `Bound`, and
finally runs `scripts/doctor.sh --offline-cache ...`. Live doctor reads the
digest-pinned `name: minio-client` image from that cache for an S3 object
read/write/delete probe, then reads `name: rwx-smoke` and runs writer/reader
Jobs against the same PVC. Doctor `partial` is still allowed for live checks
that cannot be verified, such as missing `kubectl` or `psql`; doctor `failed`
still fails the install.
