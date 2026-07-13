#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/bin"

manifest='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[]}'
digest="$(printf '%s' "${manifest}" | sha256sum | awk '{print $1}')"
cat >"${tmp_dir}/bin/skopeo" <<'EOF_SKOPEO'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"__TMP_DIR__/skopeo-args"
if [[ "$1" == "copy" ]]; then
  destination="${@: -1}"
  archive="${destination#oci-archive:}"
  archive="${archive%:offline}"
  printf 'archive-bytes' >"${archive}"
else
  printf '%s' '__MANIFEST__'
fi
EOF_SKOPEO
sed -i "s|__TMP_DIR__|${tmp_dir}|g; s|__MANIFEST__|${manifest}|g" "${tmp_dir}/bin/skopeo"
chmod +x "${tmp_dir}/bin/skopeo"

PATH="${tmp_dir}/bin:${PATH}"
# shellcheck source=prepare-offline-cache.sh
source "${ROOT_DIR}/scripts/prepare-offline-cache.sh"

source_ref="docker.io/library/python:3.13-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
archive="${tmp_dir}/python.tar"
record="$(prepare_image_artifact LOCAL_OPENAI_PROVIDER_SOURCE "${source_ref}" "${archive}")"
[[ "${record}" == $'\t' ]] && { printf 'expected image artifact record\n' >&2; exit 1; }
[[ "${record}" == "${archive}"$'\t'"docker.io/library/python:3.13-alpine@sha256:${digest}"$'\t'* ]] \
  || { printf 'expected lock digest from archived platform manifest\n' >&2; exit 1; }
grep -Fqx -- "copy --override-os linux --override-arch amd64 docker://docker.io/library/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa oci-archive:${archive}:offline" "${tmp_dir}/skopeo-args" >/dev/null \
  || { printf 'expected explicit digest to be exported as an OCI archive\n' >&2; exit 1; }
grep -Fqx -- "inspect --raw oci-archive:${archive}" "${tmp_dir}/skopeo-args" >/dev/null \
  || { printf 'expected archived platform manifest to be inspected\n' >&2; exit 1; }

printf 'offline cache image resolution contract passed\n'
