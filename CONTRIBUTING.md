# Contributing to Grimalkin

Thanks for helping improve Grimalkin. Bug reports, compatibility findings,
documentation fixes, and focused code changes are all welcome.

## Before opening a change

- Search existing issues before starting substantial work.
- Open an issue first for large features or architectural changes so the scope
  can be agreed before implementation.
- Keep pull requests focused. Avoid mixing refactors with behaviour changes.
- Never include credentials, private terminal output, or third-party material
  whose license is unclear.
- Use comments to preserve context the code cannot express: intent, constraints,
  ownership, platform behaviour, or the reason behind a surprising choice.
  Avoid comments that merely restate a name or narrate the next operation.

Security reports follow [SECURITY.md](SECURITY.md), not the public issue tracker.

## Development environment

### Linux and macOS

The supported Linux entry point downloads checksum-pinned Odin and Zig tools,
prepares vcpkg and `libghostty-vt` under `build/`, then executes Make:

```sh
scripts/build-linux-native.sh check test build test-gpu
./build/linux-native/work/grimalkin
```

Set `GRIMALKIN_LINUX_BUILD_DIR` and `GRIMALKIN_LINUX_CACHE_DIR` to relocate
derived build state and reusable downloads. `--prepare-only` populates the
pinned toolchain and dependency environment without compiling Grimalkin.

On Apple Silicon macOS, the corresponding interface creates a verified bundle:

```sh
scripts/build-macos-native.sh build/macos-native/Grimalkin.app check test build
open build/macos-native/Grimalkin.app
```

It accepts `--prepare-only`, and `GRIMALKIN_MACOS_BUILD_DIR` /
`GRIMALKIN_MACOS_CACHE_DIR` relocate its output and cache. With dependencies
already configured, both scripts use the Make targets below directly.

Common targets are:

| Command | Purpose |
| --- | --- |
| `make check` | Type-check the Odin source |
| `make test` | Run the native session test and Odin test suite |
| `make test-gpu` | Build and run deterministic Vulkan pixel tests |
| `make build` | Build the terminal executable |
| `make run` | Build and launch Grimalkin |
| `make benchmark` | Run the deterministic renderer benchmark |
| `make clean` | Remove generated local build products |

`make test-gpu` renders offscreen and never presents, so it needs no display
server and runs unchanged over SSH or in a container. By default it picks a CPU
device, which keeps results deterministic; two environment variables select
otherwise:

| Variable | Values | Effect |
| --- | --- | --- |
| `GRIMALKIN_GPU_TEST_DEVICE` | `cpu`, `hardware`, `any` | Which physical device to run on. Defaults to preferring a CPU device. |
| `GRIMALKIN_GPU_TEST_FORMAT` | `srgb`, `unorm` | Render target format. `unorm` exercises the manual sRGB encoding path that an sRGB surface would otherwise hide. |

Visual renderer changes must also be exercised on a hardware Vulkan device with
validation layers enabled: `GRIMALKIN_GPU_TEST_DEVICE=hardware make test-gpu`.

The Nix flake is optional. `nix develop`, `nix flake check path:.`, and
`nix build path:.#grimalkin` provide local development and packaging
alternatives, but are not required by the native scripts or CI.

### Windows

Windows development requires Visual Studio 2022 with C++ CMake/vcpkg support,
the Vulkan SDK, and Odin on `PATH`. From PowerShell:

```powershell
.\build-windows.ps1 -Configuration Release -Target grimalkin_tests
.\build-windows.ps1 -Configuration Release -Target grimalkin
.\build-windows.ps1 -Configuration Release -Target grimalkin_ci
.\build\windows\bin\grimalkin.exe
```

`grimalkin_ci` is the normal verification target: it runs the native session
and Odin tests and builds the executable in one CMake build.

Do not apply a Linux or macOS dependency workaround to the Windows CMake/vcpkg
path, or vice versa. Platform packaging is described in
[docs/releasing.md](docs/releasing.md).

## Repository map

- `src/ghostty_shim.{c,h}` and `src/ghostty_vt.odin`: the isolated,
  intentionally narrow `libghostty-vt` ABI boundary.
- `src/session_shim.c` and `src/session.odin`: PTY/ConPTY lifecycle and I/O.
- `src/display_compiler.odin`: terminal snapshot to render-cell compilation,
  shaping, and texture registry updates.
- `src/vulkan_app.odin`: window loop, GPU resource ownership, and rendering.
- `src/shaders/`: terminal, overlay, selection, scroll indicator, and padding
  shaders.
- `src/settings.odin` and `src/osd.odin`: persistent settings and live UI.
- `assets/`, `scripts/`, `nix/`, and `cmake/`: platform resources and builds;
  the native Unix builders share pinned checkout/work-tree preparation, while
  platform-specific scripts retain dependency and packaging policy.

Read [docs/architecture.md](docs/architecture.md) before changing the display
compiler, font stack, renderer, allocator ownership, or terminal shim.

## Testing expectations

Run tests in proportion to the change:

- Documentation-only: check links, commands, and Markdown rendering.
- Input, terminal, settings, or CPU rendering: `make test` and `make build`.
- Shader or Vulkan resource changes: `make test`, `make test-gpu`, and
  `make build`, with validation layers where possible.
- Unix build or packaging: the relevant native builder targets and affected
  release package script; optionally run `nix flake check path:.` as a separate
  flake validation.
- Windows session/build changes: the native Windows test and build targets.

Rendering changes need deterministic test coverage and a real, rapidly updating
terminal workload such as `htop`. Include before/after screenshots for visible
changes, but do not rely on screenshots in place of pixel or state tests.

## Pull requests

Every pull request runs native Linux, Apple Silicon macOS, and Windows CI. A PR
authored and updated by the repository owner from a branch in this repository is
trusted and uses the self-hosted platform fleet. All other PRs run the same
matrix on isolated GitHub-hosted runners. See [SECURITY.md](SECURITY.md) for the
trust boundary; workflow approval does not move an untrusted PR onto a
self-hosted runner.

A good pull request explains:

1. The user-visible problem or maintenance need.
2. The chosen approach and important trade-offs.
3. The exact validation performed.
4. Any platform or workload that could not be tested.

Keep generated files and local build outputs out of commits. Update user and
technical documentation when behaviour or architecture changes. If AI tools
materially contributed, review every change and ensure you can explain and
maintain it; do not submit unverifiable generated code or text.

By contributing, you agree that your work is licensed under the repository's
GPL-3.0-or-later license.
