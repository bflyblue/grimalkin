# Building packages and publishing releases

This document is for maintainers producing distributable artifacts. Ordinary
contributors should start with [CONTRIBUTING.md](../CONTRIBUTING.md).

## Linux packages

The release script builds an AppImage, Debian package, Arch package, or all
formats:

```sh
scripts/package-linux-release.sh dist all ubuntu-22.04
```

Its second argument is `appimage`, `deb`, `arch`, or `all`; the third labels
distro-specific Debian output. The GitHub release workflow runs it in Ubuntu
22.04, Debian 12, and Arch Linux environments.

The package script calls `scripts/build-linux-native.sh test build`, then stages
the resulting executable and shared fonts, Fontconfig data, notices, and
licences through one payload helper. The builder downloads checksum-pinned Odin
and Zig tools and uses the pinned `vcpkg.json` manifest; packaging downloads
the pinned linuxdeploy tool when needed. `libghostty-vt`, FreeType, HarfBuzz,
Fontconfig, GLFW, libpng, their vcpkg dependencies, and the C++ runtime are
linked statically. glibc and the target system's Vulkan loader and driver remain
dynamic.

The package build rejects unexpected dynamic dependencies and searches staging
trees and artifacts for accidental `/nix/store/` references. Test the finished
package outside the development shell.

## macOS bundle

Build the local application bundle with:

```sh
scripts/build-macos-native.sh build/macos-native/Grimalkin.app test build
open build/macos-native/Grimalkin.app
```

The native builder performs an ad-hoc signature for local verification. Public
artifacts are signed with a Developer ID identity and notarized by the release
workflow. `nix build path:.#grimalkin` remains an optional local package build
using the same tracked `Info.plist`, Fontconfig, and shader-manifest inputs.

## Windows packages

After installing the prerequisites from [CONTRIBUTING.md](../CONTRIBUTING.md),
create the portable archive with:

```powershell
.\package-windows.ps1 -Format ZIP
```

Install NSIS and build both the archive and installer with:

```powershell
winget install NSIS.NSIS
.\package-windows.ps1 -Format All
```

Artifacts are written under `build\windows\packages`. The manifest uses an
explicit DLL allowlist and includes the bundled font license and redistributed
library licenses. Test the installer on a clean Windows 11 machine with the
Visual C++ Redistributable.

## GitHub release workflow

A `v*` tag pushed by the repository owner triggers
`.github/workflows/release.yml`. The tag version must match the checked-in
`VERSION` exactly, `docs/releases/v<version>.md` must contain the curated
release notes, and the tagged commit must be reachable from the blessed `main`
branch. The workflow builds, verifies, and publishes:

- a signed and notarized Apple Silicon DMG;
- Ubuntu and Debian x86-64 packages;
- an Arch Linux x86-64 package;
- an x86-64 AppImage;
- a Windows x64 NSIS installer;
- SHA-256 checksums for every artifact.

If GitHub does not deliver the tag-push event, dispatch the workflow from
`main` with the existing tag instead:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.8
```

The manual path resolves the remote tag once, requires its `VERSION` to match,
requires its commit to be reachable from `main`, and pins every platform build
to that commit. Publishing rechecks that the tag has not moved and refuses to
replace an existing release.

Create a protected GitHub environment named `release`, restrict it to trusted
maintainers, and configure these Actions secrets:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

On macOS, encode binary credentials without line wrapping:

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

The macOS runner does not need a signing identity installed permanently. The
release job imports the certificate into a temporary keychain, keeps the
runner's existing keychains available for certificate-chain validation, and
restores the original keychain search list before removing the temporary
keychain. This restoration is required on persistent self-hosted runners;
GitHub-hosted runners discard their entire environment after each job.

Never expose signing material to pull-request workflows. Push the release tag
only after the protected environment, secrets, version, and clean-tree build
have been verified.

### Native build environment caches

GitHub-hosted Linux and macOS jobs cache their repo-local pinned userland
toolchains and compiled dependencies. Linux caches Odin, Zig, vcpkg,
`libghostty-vt`, and downloaded archives. macOS caches
CMake, pkgconf, autotools, Odin, Zig, MoltenVK, dylibbundler, compiled vcpkg
binary packages, and `libghostty-vt`. Windows caches Odin, NSIS, Zig,
vcpkg, CMake FetchContent sources, vcpkg binary packages, and `libghostty-vt`;
Visual Studio and the Vulkan SDK remain installed on the runner VM. The derived
vcpkg installed trees are recreated from its ABI-aware binary cache rather than
archived directly.

`.github/workflows/native-ci-environments.yml` automatically prepares the
GitHub-hosted cache namespaces when a pinned tool or dependency definition
changes on `main`. Untrusted Linux and macOS CI restore those caches onto fresh
hosted runners. Trusted macOS CI and releases use a persistent native cache directly;
restoring a remote archive over that live cache can corrupt signed application
bundles such as CMake. Versioned tool directories, checksummed downloads,
pinned revisions, and vcpkg's ABI-aware binary cache make tooling updates
rebuild automatically when their pinned inputs change. Windows jobs
on GitHub-hosted runners continue to restore that cache. Trusted Windows CI and
releases instead keep the same inputs under the self-hosted runner's `_cache`
directory, outside the checkout-cleaned workspace, so the VM does not download
and unpack a multi-gigabyte GitHub cache on every run. Empty or version-stale
entries are populated automatically from the pinned, checksummed inputs.
`build-windows.ps1` also detects path-bound CMake FetchContent state moved from
another cache or workspace location and rebuilds that derived tree automatically.

Linux OCI environments use a content-derived tag made from the Containerfile,
the pinned Linux toolchain inputs, and the pulled base-image identities. A
workflow-only change therefore reuses the existing images, while a toolchain or
base-image change automatically produces a new set. Trusted Linux release jobs
mount the shared `grimalkin-linux-vcpkg` Podman volume and keep each
distribution's vcpkg binary packages in a separate directory. This avoids a
GitHub cache download on every self-hosted run while still allowing vcpkg's ABI
keys to select compatible packages when the compiler, triplet, ports, or
manifest change. Completed package archives are reusable immediately; a failed
job cannot publish an incomplete immutable cache snapshot. The volume is local
to the Linux runner host, so a replacement host starts with an empty cache and
warms it normally.

### On-demand Windows runner VM

Trusted platform CI and the release workflow can start a maintainer-controlled
libvirt domain before queueing their Windows jobs. The public workflows obtain
the domain and runner-service identifiers from the validated repository
variables `GRIMALKIN_WINDOWS_VM_NAME` and
`GRIMALKIN_WINDOWS_RUNNER_SERVICE`; host paths and lifecycle automation remain
private operational configuration.

Workflows never stop the VM directly. Trusted CI and releases share one
concurrency group because the repository currently has one Windows runner VM.
The host-side idle watchdog must refresh its lease while a job is running, leave
the VM running when inspection fails, and request graceful shutdown only after
the configured idle interval. The runner account needs `virsh` plus permission
to manage the configured domain through `qemu:///system`.
