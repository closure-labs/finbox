#!/usr/bin/env bash
set -euo pipefail
profile="${1:?recipe profile is required}"
case "$profile" in
bluefin-generic|bluefin-dx-generic) output=image-payload ;;
bluefin-next|bluefin-dx-next) output=image-payload-next ;;
*) echo "Unknown image profile: $profile" >&2; exit 2 ;;
esac
payload=$(nix build --accept-flake-config --no-link --print-out-paths ".#$output")
test -d "$payload/home-manager-template"
rm -rf files/payload files/system files/scripts/lib
mkdir -p files/payload files/system files/scripts/lib files/dnf
cp -a "$payload/." files/payload/
cp -a modules/aspects/base/rootfs/. files/system/
mv files/system/etc/yum.repos.d/terra.repo files/dnf/terra.repo
cp modules/aspects/base/install-determinate-nix.sh files/scripts/lib/
cp modules/aspects/base/install-nix-systemd-units.sh files/scripts/lib/
chmod -R u+w files/payload files/system files/scripts/lib
