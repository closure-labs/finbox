#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == closure-labs/finbox ]] || {
  echo 'Prepare the installer only on the ephemeral finbox ISO runner.' >&2
  exit 2
}
lock=sources/bluebuild-installer.json
source=$(jq -er '.image + "@" + .digest' "$lock")
alias=$(jq -er .cliAlias "$lock")
version=$(jq -er .version "$lock")
revision=$(jq -er .revision "$lock")
[[ $source =~ ^ghcr.io/jasonn3/build-container-installer@sha256:[0-9a-f]{64}$ ]]
[[ $alias == ghcr.io/jasonn3/build-container-installer:v1.4.0 ]]
docker pull "$source"
docker inspect "$source" | jq -e --arg version "$version" --arg revision "$revision" '
  .[0].Config.Labels |
  .["org.opencontainers.image.version"] == $version and
  .["org.opencontainers.image.revision"] == $revision
' >/dev/null
# Old Lorax strips these executables although newer Anaconda needs load_policy
# to restore the installer SELinux policy before shutdown (RHEL-144456).
docker run --rm --entrypoint /bin/bash "$source" -euo pipefail -c '
  template=/usr/share/lorax/templates.d/99-generic/runtime-cleanup.tmpl
  rpm -q lorax
  grep -q "^removefrom policycoreutils " "$template"
  if grep -E "^removefrom policycoreutils .*usr/(bin|sbin|\\*bin)" "$template"; then
    echo "Installer cleanup would remove the SELinux policy loader" >&2
    exit 1
  fi
'
# CLI v0.9.37 has no installer-image option. This local alias keeps generate-iso
# usable with the fixed upstream release; neither registry tag is changed.
printf 'Using installer %s (%s) through local CLI compatibility alias %s\n' "$version" "$source" "$alias"
docker tag "$source" "$alias"
[[ $(docker inspect --format '{{.Id}}' "$alias") == "$(docker inspect --format '{{.Id}}' "$source")" ]]
mkdir -p .bluebuild/iso
jq --arg resolved "$source" '. + {resolvedImage: $resolved}' "$lock" >.bluebuild/iso/installer.json
