# Third-party notices

Grimalkin includes or dynamically links the components below. Their full
license texts are shipped in the `licenses` directory of release packages;
the Nerd Fonts license is also shipped alongside the bundled font in `fonts`.

| Component | Use | License |
| --- | --- | --- |
| [Ghostty](https://github.com/ghostty-org/ghostty) | Terminal parser and state engine | MIT |
| [Microsoft Terminal / ConPTY](https://github.com/microsoft/terminal) | Windows pseudoconsole runtime | MIT |
| [Nerd Fonts Symbols Only](https://github.com/ryanoasis/nerd-fonts) | Optional symbol fallback font | SIL Open Font License 1.1; Nerd Fonts tooling is MIT |
| [Odin](https://odin-lang.org/) | Language runtime and vendor bindings compiled into Grimalkin | zlib License |
| [Zig](https://ziglang.org/) | Runtime code used by the Zig-built Ghostty library | MIT |
| [GLFW](https://www.glfw.org/) | Native windowing and input | zlib License |
| [FreeType](https://freetype.org/) | Font rasterization | FreeType License or GPLv2 |
| [HarfBuzz](https://harfbuzz.github.io/) | Text shaping | Old MIT |
| [Fontconfig](https://www.freedesktop.org/wiki/Software/fontconfig/) | Font discovery and fallback | MIT-style |
| [libpng](http://www.libpng.org/pub/png/libpng.html) | PNG encoding and decoding | PNG Reference Library License 2.0 |
| [zlib](https://zlib.net/) | Compression used by libpng | zlib License |
| [Brotli](https://github.com/google/brotli) | Fontconfig compression dependency | MIT |
| [bzip2](https://sourceware.org/bzip2/) | Fontconfig compression dependency | bzip2 License |
| [Expat](https://libexpat.github.io/) | Fontconfig XML parsing | MIT |
| [Vulkan Loader](https://github.com/KhronosGroup/Vulkan-Loader) | Vulkan driver discovery on macOS | Apache License 2.0 |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Vulkan implementation over Metal on macOS | Apache License 2.0 |
| [libstdc++](https://gcc.gnu.org/onlinedocs/libstdc++/) | C++ runtime code statically linked into the Linux AppImage | GPLv3 with GCC Runtime Library Exception 3.1 |

Linux and Windows use the Vulkan loader and graphics driver installed on the
user's system. The macOS application bundles the Vulkan loader and MoltenVK.
The Microsoft Visual C++ runtime is a Windows package prerequisite and is not
included in Grimalkin's portable archive.
