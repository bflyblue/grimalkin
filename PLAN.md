# Future work

## Propagate terminal damage through rendering

- Use `display_grid_dirty_ranges` for partial mapped-buffer writes instead of uploading the complete cell and decoration grids whenever any row changes.
- Investigate replacing per-frame copies of unchanged grid metadata with persistent shared storage buffers while preserving safe synchronization across frames in flight.
- Restrict small updates to damaged rows or rectangles with Vulkan scissors or per-row draws instead of redrawing the full framebuffer.
- Advertise damaged rectangles to the compositor with `VK_KHR_incremental_present` when the active device and surface support it, with unchanged full-frame presentation as the fallback.
- Re-run vtebench cursor-motion, light-cell, and fullscreen-scroll workloads after each stage. Compare normalized throughput because vtebench may select different payload sizes between terminals.
- Profile the Unicode workload separately before attributing its remaining gap to damage handling. Measure fallback-font lookup, HarfBuzz shaping, grapheme processing, glyph rasterization, atlas allocation, and visual-cache behavior.

## Sign Linux release artifacts

- Add GitHub artifact attestations for every published Linux artifact (`.pkg.tar.zst`, `.deb`, and `.AppImage`) so users can verify build provenance with `gh attestation verify`.
- Produce a detached OpenPGP `.sig` for the Arch Linux package and document how users import and trust the Grimalkin release key.
- Embed an OpenPGP signature in the AppImage during packaging and document verification.
- If Grimalkin gains an APT repository, sign its `InRelease` metadata. Do not treat per-package `.deb` signatures as a replacement for APT repository authentication.
- Keep long-lived signing material out of ordinary build jobs. Prefer an offline primary key with a restricted release-signing subkey, protected GitHub environments, and explicit key-rotation and revocation documentation.
- Publish checksums and verification commands in each release note, and exercise signature/attestation verification in the release workflow before publication.
