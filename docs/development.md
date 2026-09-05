# Development

Edit the four recipes directly; Nix does not generate YAML. Shared modules live
under `recipes/shared`. System files currently stage from
`modules/aspects/base/rootfs` so the legacy build and sandbox use the same vendor
units, udev rules, policies and branding while acceptance is pending.

```bash
nix build --accept-flake-config --no-link .#ci-checks
bash scripts/bluebuild/stage.sh bluefin-generic
bluebuild validate recipes/bluefin-generic.yml
bluebuild generate --registry ghcr.io --registry-namespace closure-labs \
  recipes/bluefin-generic.yml
```

Use CLI v0.9.37. `stage.sh` creates ignored `files/payload`, `files/system`,
`files/dnf` and `files/scripts/lib` directories. Stage the selected profile before
each build; next profiles include the locked kernel RPMs. The payload is separate
from recipes and the old Nix build graph. Home Manager first-login consumers use
foundation and hardware from the compact `/usr/share/finite/profile.json`.

Prefer hosted finbox Actions for full image builds and ISO generation. Local
schema validation, shell/workflow linting and lifecycle fixture tests are small;
four Bluefin images and UEFI VMs require substantial storage. Inspect a Nix dry
run before fetching large dependencies and avoid concurrent local image builds.

The reference checkout revisions used for implementation are recorded in
[reference-revisions.json](bluebuild/reference-revisions.json). Workshop is an
optional reference, not a development dependency.

Before production cutover, verify all four signed images and install generic and
next variants in disposable UEFI VMs. Check first boot, Nix SELinux setup, Home
Manager activation, persistence over upgrades, signature rejection and rollback.
Install an upstream ISO and confirm subsequent bootc updating. Only then remove
the dormant legacy Containerfiles, Den image composition, CI applications and
Dakota implementation. A separate hardware cutover must retain the previous
workstation deployment and verify graphics, PipeWire camera, Espanso,
suspend/resume and authentication.
