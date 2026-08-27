{
  description = "Grimalkin terminal emulator";

  inputs = {
    nixpkgs-latest.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs-latest,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      appVersion = nixpkgs-latest.lib.removeSuffix "\n" (builtins.readFile ./VERSION);
      macosBundleVersion = builtins.head (nixpkgs-latest.lib.splitString "-" appVersion);
      ghosttyRevision = nixpkgs-latest.lib.removeSuffix "\n" (builtins.readFile ./ghostty-revision.txt);
      latestGhosttyPackage = "${nixpkgs-latest}/pkgs/by-name/li/libghostty-vt/package.nix";
      ghosttyPackage =
        pkgs:
        let
          version = "0.1.0-unstable-2026-08-26";
          package = (pkgs.callPackage latestGhosttyPackage {
            zig_0_15 = pkgs.zig_0_16;
          }).overrideAttrs (previous: {
            inherit version;
            src = pkgs.fetchFromGitHub {
              owner = "ghostty-org";
              repo = "ghostty";
              rev = ghosttyRevision;
              hash = "sha256-fusLdmDwW3+zaGyQnrHtGySbTsPjelju74h/k08ukEA=";
            };
            deps = pkgs.callPackage ./nix/ghostty-deps.nix {
              name = "libghostty-vt-cache-${version}";
              # Zig computes dependency paths lexically, so use real copied
              # directories instead of linkFarm symlinks.
              linkFarm =
                name: entries:
                pkgs.runCommand name { } ''
                  mkdir -p $out
                  ${pkgs.lib.concatMapStringsSep "\n" (entry: ''
                    cp -rL ${entry.path} $out/${entry.name}
                  '') entries}
                '';
            };
            # Zig 0.16's static archive carries compiler-rt, which duplicates
            # Odin's compiler-rt symbols under Apple's linker. Use Ghostty's
            # dylib on macOS; the app bundler copies it into the application.
            postInstall =
              if pkgs.stdenv.hostPlatform.isDarwin then
                ''
                  rm "$out/lib/libghostty-vt.a"
                ''
              else
                previous.postInstall;
          });
        in
        assert package.src.rev == ghosttyRevision;
        package;
      harmonyFontOverlay = final: previous: {
        freetype = previous.freetype.override { useEncumberedCode = false; };
      };
      harmonyFontStack = pkgs: {
        inherit (pkgs) freetype harfbuzz fontconfig;
      };
      odinPackage =
        pkgs:
        if pkgs.stdenv.hostPlatform.isDarwin then
          pkgs.stdenvNoCC.mkDerivation {
            pname = "odin";
            version = "dev-2026-07a";

            src = pkgs.fetchurl {
              url = "https://github.com/odin-lang/Odin/releases/download/dev-2026-07a/odin-macos-arm64-dev-2026-07a.tar.gz";
              hash = "sha256-QOn1lwvc4ZOHaaeS69p6w509EL/nA6chrFtXi8jdNFg=";
            };
            sourceRoot = "odin-macos-arm64-nightly+2026-07-10";

            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/share/odin"
              cp -R . "$out/share/odin"
              makeWrapper "$out/share/odin/odin" "$out/bin/odin" \
                --set ODIN_ROOT "$out/share/odin"
              runHook postInstall
            '';

            meta = {
              description = "Odin compiler official macOS ARM64 release";
              homepage = "https://odin-lang.org/";
              license = pkgs.lib.licenses.zlib;
              platforms = [ "aarch64-darwin" ];
              sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
            };
          }
        else
          pkgs.odin;
      forallSystems =
        f:
        nixpkgs-latest.lib.genAttrs supportedSystems (
          system:
          let
            basePkgs = import nixpkgs-latest { inherit system; };
            pkgs = basePkgs.extend harmonyFontOverlay;
          in
          f {
            inherit system pkgs basePkgs;
            odinCompiler = odinPackage pkgs;
          }
        );
    in
    {
      packages = forallSystems (
        { pkgs, odinCompiler, ... }:
        let
          ghosttyVt = ghosttyPackage pkgs;
          fontStack = harmonyFontStack pkgs;
          nerdFont = ./assets/fonts/SymbolsNerdFontMono-Regular.ttf;
          nerdFontLicense = ./assets/fonts/NerdFonts-LICENSE.txt;
          projectLicense = ./LICENSE;
          thirdPartyNotices = ./THIRD_PARTY_NOTICES.md;
          thirdPartyLicenses = ./third_party/licenses;
          macosIcon = ./assets/macos/Grimalkin.icns;
          grimalkin = pkgs.stdenv.mkDerivation {
            pname = "grimalkin";
            version = appVersion;
            src = pkgs.lib.cleanSource ./.;

            nativeBuildInputs = with pkgs; [
              gnumake
              makeWrapper
              odinCompiler
              pkg-config
              shaderc
            ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              darwin.sigtool
              macdylibbundler
            ];

            buildInputs = [
              fontStack.fontconfig
              fontStack.freetype
              pkgs.glfw
              fontStack.harfbuzz
              ghosttyVt
              pkgs.libpng
              pkgs.vulkan-loader
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.libx11 ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.moltenvk ];

            dontConfigure = true;
            dontStrip = pkgs.stdenv.isDarwin;

            buildPhase = ''
              runHook preBuild
              make build \
                ODIN_FLAGS=-o:speed \
                ODIN_GLFW_FLAGS='${pkgs.lib.optionalString pkgs.stdenv.isDarwin "-define:GLFW_SHARED=true"}' \
                ODIN_EXTRA_LINKER_FLAGS='-Lsrc ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "-Wl,-rpath,${pkgs.vulkan-loader}/lib -framework AppKit"}'
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 grimalkin $out/bin/grimalkin
              install -Dm644 "${nerdFont}" \
                $out/share/grimalkin/fonts/SymbolsNerdFontMono-Regular.ttf
              install -Dm644 "${nerdFontLicense}" \
                $out/share/grimalkin/fonts/NerdFonts-LICENSE.txt
              install -Dm644 "${projectLicense}" \
                $out/share/licenses/grimalkin/LICENSE
              install -Dm644 "${thirdPartyNotices}" \
                $out/share/licenses/grimalkin/THIRD_PARTY_NOTICES.md
              cp -R "${thirdPartyLicenses}" \
                $out/share/licenses/grimalkin/third-party
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                wrapProgram $out/bin/grimalkin \
                  --prefix DYLD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader pkgs.moltenvk ]}" \
                  --set VK_ICD_FILENAMES "${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"

                app="$out/Applications/Grimalkin.app"
                mkdir -p "$app/Contents"
                substitute "${./assets/macos/Info.plist.in}" "$app/Contents/Info.plist" \
                  --replace-fail '@GRIMALKIN_VERSION@' '${appVersion}' \
                  --replace-fail '@GRIMALKIN_BUNDLE_VERSION@' '${macosBundleVersion}'
                install -Dm644 "${macosIcon}" "$app/Contents/Resources/Grimalkin.icns"
                install -Dm644 "${./assets/macos/fonts.conf}" "$app/Contents/Resources/fonts.conf"
                mkdir -p \
                  "$app/Contents/Frameworks" \
                  "$app/Contents/Resources/fonts" \
                  "$app/Contents/Resources/licenses" \
                  "$app/Contents/Resources/vulkan/icd.d"
                cp "${nerdFont}" \
                  "$app/Contents/Resources/fonts/SymbolsNerdFontMono-Regular.ttf"
                cp "${nerdFontLicense}" \
                  "$app/Contents/Resources/fonts/NerdFonts-LICENSE.txt"
                cp "${projectLicense}" \
                  "$app/Contents/Resources/licenses/Grimalkin-LICENSE.txt"
                cp "${thirdPartyNotices}" \
                  "$app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
                cp -R "${thirdPartyLicenses}" \
                  "$app/Contents/Resources/licenses/third-party"
                mkdir bundle-inputs
                cp grimalkin bundle-inputs/grimalkin
                cp -L "${pkgs.vulkan-loader}/lib/libvulkan.1.dylib" \
                  bundle-inputs/libvulkan.1.dylib
                cp -L "${pkgs.moltenvk}/lib/libMoltenVK.dylib" \
                  bundle-inputs/libMoltenVK.dylib
                chmod +w bundle-inputs/*
                dylibbundler -od -b --no-codesign \
                  -x bundle-inputs/grimalkin \
                  -x bundle-inputs/libvulkan.1.dylib \
                  -x bundle-inputs/libMoltenVK.dylib \
                  -d "$app/Contents/Frameworks" \
                  -p '@executable_path/../Frameworks/' \
                  -i /usr/lib -i /System/Library
                install_name_tool -id '@rpath/libvulkan.1.dylib' \
                  bundle-inputs/libvulkan.1.dylib
                install_name_tool -id '@rpath/libMoltenVK.dylib' \
                  bundle-inputs/libMoltenVK.dylib
                codesign -f -s - bundle-inputs/libvulkan.1.dylib
                codesign -f -s - bundle-inputs/libMoltenVK.dylib
                codesign -f -s - bundle-inputs/grimalkin
                install -Dm755 bundle-inputs/grimalkin "$app/Contents/MacOS/grimalkin"
                install -Dm755 bundle-inputs/libvulkan.1.dylib \
                  "$app/Contents/Frameworks/libvulkan.1.dylib"
                install -Dm755 bundle-inputs/libMoltenVK.dylib \
                  "$app/Contents/Frameworks/libMoltenVK.dylib"
                substitute "${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json" \
                  "$app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" \
                  --replace-fail \
                    "${pkgs.moltenvk}/lib/libMoltenVK.dylib" \
                    "../../../Frameworks/libMoltenVK.dylib"
                find "$app/Contents/Frameworks" -type f -name '*.dylib' \
                  -exec codesign -f -s - '{}' ';'
                /usr/bin/codesign -f -s - "$app"
              ''}
              runHook postInstall
            '';

            postFixup = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              ${pkgs.patchelf}/bin/patchelf \
                --add-needed "${pkgs.lib.getLib pkgs.vulkan-loader}/lib/libvulkan.so.1" \
                "$out/bin/grimalkin"
            '';

            meta = {
              description = "Grimalkin terminal emulator";
              homepage = "https://github.com/bflyblue/grimalkin";
              license = pkgs.lib.licenses.gpl3Plus;
              mainProgram = "grimalkin";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        in
        {
          inherit grimalkin;
          default = grimalkin;
        }
      );

      apps = forallSystems (
        { system, ... }:
        let
          grimalkin = {
            type = "app";
            program = "${self.packages.${system}.grimalkin}/bin/grimalkin";
            meta.description = "Run Grimalkin";
          };
        in
        {
          inherit grimalkin;
          default = grimalkin;
        }
      );

      checks = forallSystems (
        { system, pkgs, basePkgs, ... }:
        {
          inherit (self.packages.${system}) grimalkin;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          cursor-gpu = basePkgs.runCommand "grimalkin-cursor-gpu-test" {
            nativeBuildInputs = with basePkgs; [
              dejavu_fonts
              noto-fonts-cjk-sans
              mesa
              vulkan-loader
              xvfb-run
            ];
          } ''
            export GRIMALKIN_FONT_PATH="${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf"
            export GRIMALKIN_FONT_BOLD_PATH="${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-Bold.ttf"
            export GRIMALKIN_FONT_ITALIC_PATH="${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-Oblique.ttf"
            export GRIMALKIN_FONT_BOLD_ITALIC_PATH="${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-BoldOblique.ttf"
            export GRIMALKIN_CJK_FONT_PATH="${basePkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansMonoCJK-VF.otf.ttc"
            export VK_DRIVER_FILES="${basePkgs.mesa}/share/vulkan/icd.d/lvp_icd.${
              basePkgs.stdenv.hostPlatform.parsed.cpu.name
            }.json"
            export XDG_CACHE_HOME="$TMPDIR/fontconfig-cache"
            export XDG_RUNTIME_DIR="$TMPDIR/runtime"
            mkdir -p "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
            chmod 700 "$XDG_RUNTIME_DIR"
            xvfb-run -a ${self.packages.${system}.grimalkin}/bin/grimalkin --cursor-gpu-test
            touch "$out"
          '';
        }
      );

      devShells = forallSystems (
        { pkgs, basePkgs, odinCompiler, ... }:
        let
          ghosttyVt = ghosttyPackage pkgs;
          fontStack = harmonyFontStack pkgs;
        in
        {
          default = pkgs.mkShell {
            packages =
              [
                fontStack.fontconfig
                fontStack.freetype
                pkgs.glfw
                basePkgs.gnumake
                basePkgs.dejavu_fonts
                fontStack.harfbuzz
                ghosttyVt
                basePkgs.libpng
                odinCompiler
                basePkgs.pkg-config
                basePkgs.shaderc
                basePkgs.vulkan-loader
                basePkgs.vulkan-tools
                basePkgs.vulkan-validation-layers
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                basePkgs.libx11
                basePkgs.xvfb-run
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ basePkgs.moltenvk ];

            ODIN_GLFW_FLAGS = pkgs.lib.optionalString pkgs.stdenv.isDarwin "-define:GLFW_SHARED=true";
            GRIMALKIN_TEST_FONT_PATH = "${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";
            GRIMALKIN_TEST_FONT_BOLD_PATH = "${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-Bold.ttf";
            GRIMALKIN_TEST_FONT_ITALIC_PATH = "${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-Oblique.ttf";
            GRIMALKIN_TEST_FONT_BOLD_ITALIC_PATH = "${basePkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-BoldOblique.ttf";
            GRIMALKIN_TEST_CJK_FONT_PATH = "${basePkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansMonoCJK-VF.otf.ttc";
            ODIN_EXTRA_LINKER_FLAGS =
              if pkgs.stdenv.isDarwin then
                "-Lsrc -Wl,-rpath,${basePkgs.vulkan-loader}/lib"
              else
                "-Lsrc";
            DYLD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.isDarwin (
              pkgs.lib.makeLibraryPath [ basePkgs.vulkan-loader basePkgs.moltenvk ]
            );
            VK_ICD_FILENAMES = pkgs.lib.optionalString pkgs.stdenv.isDarwin (
              "${basePkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"
            );
            shellHook =
              pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                export FONTCONFIG_FILE="${
                  basePkgs.makeFontsConf { fontDirectories = [ basePkgs.noto-fonts-cjk-sans ]; }
                }"
              ''
              + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                if [ -z "''${VK_DRIVER_FILES:-}" ] && \
                   [ -d /run/opengl-driver/share/vulkan/icd.d ]; then
                  export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d
                fi
              '';
          };
        }
      );
    };
}
