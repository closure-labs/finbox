# Installation

The BlueBuild installation path is currently for finbox sandbox acceptance.
Production/workstation cutover follows successful image, ISO and VM tests.

1. Open a successful **Build Finite** run in `closure-labs/finbox`. Select a
   profile's image evidence, obtain its digest and verify it with the tracked key:
   `cosign verify --key cosign.pub ghcr.io/closure-labs/finbox@sha256:…`.
2. Dispatch **Build installation ISO** on `main` with that digest and its channel
   (`bluefin-generic`, `next`, `bluefin-dx-generic` or `dev-next`). The digest must
   still match the selected channel when ISO generation starts.
3. Download the ISO artifact, then run `sha256sum -c SHA256SUMS` beside the ISO
   and `installation.json`. Check the source and update channel in that record.
4. Boot the ISO in a disposable UEFI VM and install. The Kinoite variant selects
   the installer interface; the installed desktop remains Bluefin/GNOME.
5. After installation, compare `bootc status --json` with the recorded source
   digest and inspect `/usr/share/finite/profile.json`. Test first login and Nix
   persistence before selecting the continuing update channel.

Each ISO uses a short random tag, checked against existing registry tags before
copying. Its length fits the installer's 32-byte volume-label limit. CLI
v0.9.37 loses digest-only references when constructing installer arguments; the
workflow verifies a digest, copies it to this unique tag with digest preservation,
and passes the tag to `generate-iso`. Do not use that one-time tag as a permanent
update channel.

After validating the installed image and its signing policy, select the channel
recorded in `installation.json`. For example, in the disposable generic VM:

```bash
sudo bootc switch --enforce-container-sigpolicy \
  ghcr.io/closure-labs/finbox:bluefin-generic
sudo systemctl reboot
```

Verify the staged digest and signature policy before rebooting. Then test an
upgrade, confirm Home Manager and `/var/home/nix` persist, and test rollback.
The image also records its canonical update reference in
`/usr/share/finite/update-image`.

The Nix seed lives under `/usr/lib/finite/determinate-nix-seed`. First boot copies
it into persistent `/var/home/nix`, installs the SELinux policy and mounts `/nix`
before enabling daemon sockets. Home Manager's first-login flow and standalone
configuration templates remain available; see [configuration](configuration.md).

Dakota source remains in `installer/` for acceptance comparison. Its former
workflow is dormant in `legacy/workflows`; deletion awaits a successful upstream
ISO install and update test. The running workstation is switched separately,
with its previous deployment retained.
