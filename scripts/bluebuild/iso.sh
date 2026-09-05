#!/usr/bin/env bash
set -euo pipefail
channel="${1:?update channel required}"
digest="${2:?verified image digest required}"
case "$channel" in
bluefin-generic|latest|next|bluefin-dx-generic|dev-next) ;;
*) echo 'Unsupported update channel' >&2; exit 2 ;;
esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]
repository=ghcr.io/closure-labs/finbox
source="$repository@$digest"
mkdir -p .bluebuild/iso
cosign verify --key cosign.pub "$source" >.bluebuild/iso/signature.json
# Lorax uses finbox-x86_64-TAG as the ISO volume ID (at most 32 bytes).
# Keep 64 random bits plus a prefix; reject any existing tag before copying.
tag="i$(printf '%s-%s-%s' "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}" \
  "$(cat /proc/sys/kernel/random/uuid)" | sha256sum | cut -c1-16)"
volume_id="finbox-x86_64-$tag"
[[ ${#volume_id} -le 32 ]]
# List must succeed: authentication/transport errors are not proof of absence.
skopeo list-tags "docker://$repository" >.bluebuild/iso/tags.json
jq -e --arg tag "$tag" '.Tags | index($tag) == null' .bluebuild/iso/tags.json >/dev/null
# Verify the requested channel and profile correspond to the supplied digest.
skopeo inspect "docker://$repository:$channel" >.bluebuild/iso/channel.json
[[ $(jq -r .Digest .bluebuild/iso/channel.json) == "$digest" ]]
profile=$(jq -er '.Labels["io.finite.profile"]' .bluebuild/iso/channel.json)
case "$channel:$profile" in
bluefin-generic:bluefin-generic|latest:bluefin-generic|next:bluefin-next|bluefin-dx-generic:bluefin-dx-generic|dev-next:bluefin-dx-next) ;;
*) echo 'Image profile does not match the requested channel' >&2; exit 1 ;;
esac
skopeo copy --all --preserve-digests "docker://$source" "docker://$repository:$tag"
[[ $(skopeo inspect --format '{{.Digest}}' "docker://$repository:$tag") == "$digest" ]]
cosign verify --key cosign.pub "$repository:$tag" >/dev/null
jq -n --arg image "$source" --arg tag "$repository:$tag" \
  --arg channel "$repository:$channel" --arg profile "$profile" \
  '{image: $image, installationTag: $tag, updateChannel: $channel, profile: $profile}' \
  >.bluebuild/iso/installation.json
# v0.9.37 constructs IMAGE_TAG from a tag; a digest-only reference becomes latest.
sudo bluebuild generate-iso --variant kinoite --output-dir .bluebuild/iso \
  --iso-name "finbox-$profile.iso" image "$repository:$tag"
# Confirm that the install source tag has not changed while the ISO was assembled.
[[ $(skopeo inspect --format '{{.Digest}}' "docker://$repository:$tag") == "$digest" ]]
(cd .bluebuild/iso && sha256sum -- *.iso installation.json >SHA256SUMS)
