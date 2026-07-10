#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/bin"

digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat >"${tmp_dir}/bin/skopeo" <<EOF_SKOPEO
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${tmp_dir}/skopeo-args"
printf '%s\n' '${digest}'
EOF_SKOPEO
chmod +x "${tmp_dir}/bin/skopeo"

PATH="${tmp_dir}/bin:${PATH}"
# shellcheck source=prepare-offline-cache.sh
source "${ROOT_DIR}/scripts/prepare-offline-cache.sh"

source_ref="docker.io/library/python:3.13-alpine@${digest}"
[[ "$(resolve_image_digest LOCAL_OPENAI_PROVIDER_SOURCE "${source_ref}")" == "${digest#sha256:}" ]] \
  || { printf 'expected explicit digest to be accepted\n' >&2; exit 1; }
grep -Fqx -- "inspect --override-os linux --override-arch amd64 --format {{.Digest}} docker://docker.io/library/python@${digest}" "${tmp_dir}/skopeo-args" >/dev/null \
  || { printf 'expected resolver to retain the supplied digest override\n' >&2; exit 1; }

printf 'offline cache image resolution contract passed\n'
