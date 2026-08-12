#!/usr/bin/env bash
# Concatenate installer/parts/*.sh into the single deliverable script.
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="${here}/rw-edge-install.sh"

: >"${out}"
for part in "${here}"/parts/*.sh; do
    cat "${part}" >>"${out}"
done

chmod 0755 "${out}"
bash -n "${out}"

printf 'built %s (%s bytes, %s lines)\n' \
    "${out}" "$(stat -c%s "${out}")" "$(wc -l <"${out}")"
