#!/usr/bin/env bash
# This creates and destroys only a disk in an ephemeral GitHub-hosted runner.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == closure-labs/finbox ]] || {
  echo 'Run VM acceptance through the finbox hosted workflow.' >&2
  exit 2
}
artifact=$(realpath "${1:?ISO artifact directory required}")
state="$PWD/.bluebuild/vm"
mkdir -p "$state"
(cd "$artifact" && sha256sum -c SHA256SUMS)
source=$(jq -er .image "$artifact/installation.json")
channel=$(jq -er .updateChannel "$artifact/installation.json")
installation_tag=$(jq -er .installationTag "$artifact/installation.json")
profile=$(jq -er .profile "$artifact/installation.json")
[[ $source =~ ^ghcr.io/closure-labs/finbox@sha256:[0-9a-f]{64}$ ]]
[[ $channel =~ ^ghcr.io/closure-labs/finbox:(bluefin-generic|next|bluefin-dx-generic|dev-next)$ ]]
cosign verify --key cosign.pub "$source" >"$state/signature.json"
skopeo inspect --raw "docker://$source" >"$state/source-manifest.json"
mapfile -t isos < <(find "$artifact" -maxdepth 1 -name '*.iso' -type f)
[[ ${#isos[@]} == 1 ]]
test -r /usr/share/OVMF/OVMF_CODE_4M.fd
test -e /dev/kvm
sudo chmod a+rw /dev/kvm
ssh-keygen -q -t ed25519 -N '' -f "$state/ssh-key"
key=$(cat "$state/ssh-key.pub")
cat >"$state/ks.cfg" <<KS
lang en_US.UTF-8
keyboard us
timezone America/Chicago
zerombr
clearpart --all --initlabel --drives=vda
autopart
poweroff
rootpw --lock
user --name=finite-test --groups=wheel --lock
sshkey --username=finite-test "$key"
%include /usr/share/anaconda/interactive-defaults.ks
%post --erroronfail
printf 'finite-test ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/finite-test
chmod 0440 /etc/sudoers.d/finite-test
systemctl enable sshd
%end
KS
# Follow the upstream test: add unattended answers to a temporary ISO copy.
xorriso -osirrox on -indev "${isos[0]}" -extract /boot/grub2/grub.cfg "$state/grub.cfg"
sed -i -e 's/quiet/console=ttyS0,115200n8 inst.ks=cdrom:\/ks.cfg/g' \
  -e 's/set default=.*/set default="0"/' -e 's/set timeout=.*/set timeout=1/' "$state/grub.cfg"
xorriso -indev "${isos[0]}" -outdev "$state/install.iso" -boot_image any replay \
  -map "$state/ks.cfg" /ks.cfg -chmod 0444 /ks.cfg -- \
  -map "$state/grub.cfg" /boot/grub2/grub.cfg
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$state/OVMF_VARS.fd"
qemu-img create -f qcow2 "$state/disk.qcow2" 64G
qemu_args=(
  -enable-kvm -machine q35 -cpu host -smp 2 -m 4096 -display none -no-reboot
  -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd"
  -drive "if=pflash,format=raw,file=$state/OVMF_VARS.fd"
  -drive "if=virtio,format=qcow2,file=$state/disk.qcow2"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22" -device "virtio-net-pci,netdev=net0"
)
pid=
cleanup() {
  if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -f "$state/ssh-key" "$state/install.iso" "$state/disk.qcow2"
}
trap cleanup EXIT
# timeout also bounds Anaconda errors that leave the installer UI waiting.
timeout 45m qemu-system-x86_64 "${qemu_args[@]}" -boot d -cdrom "$state/install.iso" \
  -serial "file:$state/install.log" &
pid=$!
wait "$pid"
pid=
rm "$state/install.iso"
ssh_args=(-i "$state/ssh-key" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 finite-test@127.0.0.1)
boot_vm() {
  local phase=$1
  qemu-system-x86_64 "${qemu_args[@]}" -boot c -serial "file:$state/$phase.log" &
  pid=$!
  for _ in {1..120}; do
    kill -0 "$pid"
    if ssh "${ssh_args[@]}" true 2>/dev/null; then return; fi
    sleep 5
  done
  echo "SSH did not become available during $phase" >&2
  return 1
}
poweroff_vm() {
  ssh "${ssh_args[@]}" sudo systemctl poweroff || true
  for _ in {1..60}; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; pid=; return; fi
    sleep 2
  done
  echo 'Guest did not shut down' >&2
  return 1
}
boot_vm first-boot
ssh "${ssh_args[@]}" sudo bootc status --json >"$state/first-boot.json"
# The imported digest can be the architecture manifest, rather than its signed index.
jq -e --arg tag "$installation_tag" '.status.booted.image.image.image == $tag' \
  "$state/first-boot.json" >/dev/null
installed_digest=$(jq -er '.status.booted.image.imageDigest' "$state/first-boot.json")
jq -e --arg installed "$installed_digest" --arg index "${source##*@}" \
  '$installed == $index or any(.manifests[]?; .digest == $installed)' \
  "$state/source-manifest.json" >/dev/null
ssh "${ssh_args[@]}" bash -s -- "$profile" <<'GUEST'
set -euo pipefail
[[ $(cat /usr/share/finite/build-profile) == "$1" ]]
[[ $(getenforce) == Enforcing ]]
sudo systemctl is-active finite-nix-seed.service finite-nix-selinux.service nix.mount
sudo systemctl is-active nix-daemon.socket determinate-nixd.socket
mountpoint /nix
/nix/var/nix/profiles/default/bin/nix store ping --store daemon
printf 'persistent-nix-state\n' | sudo tee /var/home/nix/finite-acceptance >/dev/null
jq -n --arg foundation "$(jq -r .foundation /usr/share/finite/profile.json)" \
  '{schema:2,foundation:$foundation,hardware:"generic-x86_64",packages:[],roles:[],identity:{}}' >"$HOME/profile.json"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export FINITE_NIX_COMMAND=/nix/var/nix/profiles/default/bin/nix
/usr/libexec/finite/home-init --profile "$HOME/profile.json"
printf '\n# VM acceptance customization\n' >>"$HOME/.config/home-manager/customize.nix"
GUEST
# Use a deliberately wrong public key, then restore policy even if the test fails.
ssh "${ssh_args[@]}" bash -s -- "$channel" <<'GUEST'
set -euo pipefail
work=$(mktemp -d)
trap 'sudo cp "$work/policy.json" /etc/containers/policy.json; sudo rm -f /etc/pki/containers/finite-acceptance-wrong.pub; rm -rf "$work"' EXIT
sudo cp /etc/containers/policy.json "$work/policy.json"
sudo chown "$(id -u):$(id -g)" "$work/policy.json"
COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix "$work/wrong" >/dev/null
sudo install -m 0644 "$work/wrong.pub" /etc/pki/containers/finite-acceptance-wrong.pub
sudo restorecon /etc/pki/containers/finite-acceptance-wrong.pub
jq --arg key /etc/pki/containers/finite-acceptance-wrong.pub \
  '.transports.docker["ghcr.io/closure-labs/finbox"][0].keyPath = $key' \
  "$work/policy.json" | sudo tee /etc/containers/policy.json >/dev/null
if sudo bootc switch --enforce-container-sigpolicy "$1" >"$work/rejection.log" 2>&1; then
  echo 'bootc accepted an image with the wrong signing key' >&2
  exit 1
fi
grep -Ei 'invalid signature|no matching signatures|none of the signatures|signature verification failed' "$work/rejection.log"
GUEST
ssh "${ssh_args[@]}" sudo bootc switch --enforce-container-sigpolicy "$channel"
ssh "${ssh_args[@]}" sudo bootc status --json >"$state/staged.json"
jq -e '.status.staged != null' "$state/staged.json" >/dev/null
poweroff_vm
boot_vm updated
ssh "${ssh_args[@]}" sudo bootc status --json >"$state/updated.json"
ssh "${ssh_args[@]}" bash -s <<'GUEST'
set -euo pipefail
[[ $(cat /var/home/nix/finite-acceptance) == persistent-nix-state ]]
grep -q 'VM acceptance customization' "$HOME/.config/home-manager/customize.nix"
/nix/var/nix/profiles/default/bin/nix store ping --store daemon
sudo bootc rollback
GUEST
poweroff_vm
boot_vm rollback
ssh "${ssh_args[@]}" sudo bootc status --json >"$state/rollback.json"
initial=$(jq -er '.status.booted.ostree.checksum' "$state/first-boot.json")
jq -e --arg initial "$initial" '.status.booted.ostree.checksum == $initial' "$state/rollback.json" >/dev/null
ssh "${ssh_args[@]}" sudo journalctl -b -u finite-nix-seed -u finite-nix-selinux -u nix-daemon \
  >"$state/nix-journal.log"
poweroff_vm
jq -n --arg source "$source" --arg channel "$channel" --arg profile "$profile" \
  '{source:$source,updateChannel:$channel,profile:$profile,uefi:true,accepted:true}' >"$state/acceptance.json"
