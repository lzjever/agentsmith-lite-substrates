# Offline Install

`scripts/download-online.sh` writes the offline cache structure:

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

The P0 downloader creates a network-free contract skeleton. Full artifact
mirroring for k3s, kubectl, dependency images, and JuiceFS CSI images remains a
P1 implementation item.

`scripts/install-offline.sh` never downloads from public locations. It first
validates:

- `manifest.yaml` schema version
- `checksums.txt` entries and file digests
- `images/images.lock` schema version
- digest-pinned image references
- archive paths listed in `images.lock`
- no public download URL fields in the cache manifest

Then it writes `out/substrate.env` and `out/substrate.secrets.env`, validates the
split contract, and clearly skips cluster mutation in this skeleton.
