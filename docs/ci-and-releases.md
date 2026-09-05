# CI and publishing

`recipes/*.yml` authoritatively define four independent BlueBuild images. The
sandbox builds Bluefin and Bluefin DX `stable` channels daily and on main pushes,
PRs, merge groups and manual dispatches. The pinned action is BlueBuild v1.12.0
(`836161eb076426a451e6a0054f722b1153b8b3ad`) and the CLI is v0.9.37.

The `CI gate` requires both the Nix/runtime checks and every image job to pass.
The four jobs use the same Docker build mode; rechunking is disabled. Failed
profiles do not cancel the others. Only trusted main runs in `closure-labs/finbox`
receive registry credentials and `COSIGN_PRIVATE_KEY`. PR and merge-group
builds neither publish nor receive signing secrets. Publication runs serialize
under `finbox-publication`; successful profiles publish independently through
the upstream action, including its cache and signature handling.

BlueBuild resolves upstream digests during generation/build. Image evidence
artifacts retain final labels (including base digests), image references,
signature verification and generated Containerfiles for review. The generated
review Containerfile resolves the current stable digest; the final image's
base-digest label records the actual build input if upstream changes mid-run.
Checks run inside the assembled image after BlueBuild cleanup, explicitly
verifying the immutable Nix seed under `/usr` and running `bootc container lint`.

Cosign uses a key pair. `cosign.pub` is tracked; the private key is an Actions
secret and must never enter Git, Nix derivations, build contexts or artifacts.
To rotate a sandbox key, generate it outside this repository with
`COSIGN_PASSWORD='' cosign generate-key-pair`, install its private half with
`gh secret set COSIGN_PRIVATE_KEY --repo closure-labs/finbox < cosign.key`, and
replace the public half in the repository. Validate signatures and host policy
before any signature-enforced bootc switch. Sandbox package visibility must
permit the installer to pull the image.

The former graph promotion, registry repair, release state machine, mandatory
SBOM/provenance publication, installer cache and Bluefin digest updater are not
part of this workflow. Their code and workflow copies remain dormant under the
legacy path until replacements pass acceptance. Nix dependency updates and the
Determinate checksum lock update remain available. The repository policy allows
the pinned BlueBuild action and its transitive actions.

Use the manual **Build installation ISO** workflow with a channel and a verified
sandbox digest. Each ISO gets a unique immutable-intent installation tag, source
record, signature evidence and SHA-256 checksums. See
[installation](installation.md) for selecting the ongoing update channel.
