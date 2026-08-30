# Future work

## Sign Linux release artifacts

- Add GitHub artifact attestations for every published Linux artifact (`.pkg.tar.zst`, `.deb`, and `.AppImage`) so users can verify build provenance with `gh attestation verify`.
- Produce a detached OpenPGP `.sig` for the Arch Linux package and document how users import and trust the Grimalkin release key.
- Embed an OpenPGP signature in the AppImage during packaging and document verification.
- If Grimalkin gains an APT repository, sign its `InRelease` metadata. Do not treat per-package `.deb` signatures as a replacement for APT repository authentication.
- Keep long-lived signing material out of ordinary build jobs. Prefer an offline primary key with a restricted release-signing subkey, protected GitHub environments, and explicit key-rotation and revocation documentation.
- Publish checksums and verification commands in each release note, and exercise signature/attestation verification in the release workflow before publication.
