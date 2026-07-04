# Offline Install

`scripts/download-online.sh` currently writes a P0 offline cache skeleton:

```text
dist/offline-cache/
  manifest.yaml
  checksums.txt
  bin/
  images/
    images.lock
    oci/
  charts/
  manifests/
    namespace-bootstrap/
  scripts/
    import-images.sh
```

## P0 Skeleton

The default downloader output is `cacheMode: p0-contract`. It is a
network-free static contract skeleton for dry-run validation only. It does not
contain a k3s binary, k3s install script, k3s airgap image archive, kubectl
binary, dependency OCI image archives, or a JuiceFS CSI artifact. It is not a
real offline install cache.

## p1-real Cache

When a supplied cache declares `cacheMode: p1-real`, validation requires:

- `bin/k3s` with manifest kind `k3s-binary`
- `scripts/install-k3s.sh` with manifest kind `k3s-install-script`
- `images/k3s/k3s-airgap-images-amd64.tar.zst` with manifest kind
  `k3s-airgap-images`
- `bin/kubectl` with manifest kind `kubectl-binary`
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
