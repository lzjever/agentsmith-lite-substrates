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
  charts/
    juicefs-csi.tgz
  images/
    images.lock
    k3s/
      k3s-airgap-images-amd64.tar.zst
    oci/
      postgres.tar
      minio.tar
      juicefs-csi.tar
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
- `JUICEFS_CSI_ARTIFACT_URL` / `JUICEFS_CSI_ARTIFACT_SHA256`
- `POSTGRES_IMAGE` / `POSTGRES_ARCHIVE_URL` / `POSTGRES_ARCHIVE_SHA256`
- `MINIO_IMAGE` / `MINIO_ARCHIVE_URL` / `MINIO_ARCHIVE_SHA256`
- `JUICEFS_CSI_IMAGE` / `JUICEFS_CSI_ARCHIVE_URL` /
  `JUICEFS_CSI_ARCHIVE_SHA256`

Image refs must be digest-pinned with `@sha256:<64 lowercase hex>`. The producer
rejects mutable tags, missing required keys, invalid sha256 values, sha
mismatches, app-owned images, and Botified runner images. It writes
`manifest.yaml`, `checksums.txt`, `images/images.lock`, a namespace bootstrap
manifest, and an offline `scripts/import-images.sh` helper without public
download URLs in the cache manifest.

## p1-real Cache

When a produced or supplied cache declares `cacheMode: p1-real`, validation
requires:

- `bin/k3s` with manifest kind `k3s-binary`
- `scripts/install-k3s.sh` with manifest kind `k3s-install-script`
- `images/k3s/k3s-airgap-images-amd64.tar.zst` with manifest kind
  `k3s-airgap-images`
- `bin/kubectl` with manifest kind `kubectl-binary`
- `scripts/import-images.sh` with manifest kind `script` and executable mode
- `manifests/namespace-bootstrap/namespace.yaml` with manifest kind `manifest`
- `images/images.lock` with manifest kind `images-lock`
- `charts/juicefs-csi.tgz` with manifest kind `juicefs-csi-artifact`
- dependency image entries for PostgreSQL, MinIO, and JuiceFS CSI
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

Without `--dry-run`, live offline cluster mutation is not implemented yet. A P0
skeleton fails immediately as not installable; a p1-real cache is validated but
still not applied to a live k3s/CSI cluster by this script.
