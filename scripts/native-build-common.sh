#!/usr/bin/env bash

# Shared helpers for the native Unix builders. Callers retain ownership of
# platform-specific toolchain downloads, dependency installation, and linking.

grimalkin_read_pinned_inputs() {
  local project_root=$1

  GRIMALKIN_VCPKG_BASELINE=$(sed -n \
    's/.*"builtin-baseline": "\([^"]*\)".*/\1/p' \
    "$project_root/vcpkg.json")
  GRIMALKIN_GHOSTTY_REVISION=$(tr -d '\r\n' < \
    "$project_root/ghostty-revision.txt")
  if [[ ! "$GRIMALKIN_VCPKG_BASELINE" =~ ^[0-9a-f]{40}$ ||
        ! "$GRIMALKIN_GHOSTTY_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Could not read the pinned native build inputs" >&2
    return 1
  fi
}

grimalkin_prepare_git_checkout() {
  local source_root=$1
  local repository=$2
  local revision=$3
  local cmake=$4

  if [[ ! -d "$source_root/.git" ]]; then
    "$cmake" -E remove_directory "$source_root"
    mkdir -p "$(dirname -- "$source_root")"
    git init --quiet "$source_root"
    git -C "$source_root" remote add origin "$repository"
  fi
  git -C "$source_root" fetch --depth 1 origin "$revision"
  git -C "$source_root" checkout --quiet --detach FETCH_HEAD
}

grimalkin_write_ghostty_pkgconfig() {
  local project_root=$1
  local source_root=$2
  local destination=$3

  mkdir -p "$destination"
  sed \
    -e "s|@INCLUDEDIR@|$source_root/include|g" \
    -e "s|@LIBDIR@|$source_root/zig-out/lib|g" \
    "$project_root/scripts/libghostty-vt.pc.in" \
    > "$destination/libghostty-vt.pc"
}

grimalkin_stage_make_work_tree() {
  local project_root=$1
  local work_tree=$2
  local cmake=$3

  "$cmake" -E remove_directory "$work_tree"
  mkdir -p "$work_tree"
	cp -R "$project_root/src" "$work_tree/src"
	mkdir -p "$work_tree/assets"
	cp -R "$project_root/assets/fonts" "$work_tree/assets/fonts"
	cp "$project_root/Makefile" "$work_tree/Makefile"
  cp "$project_root/VERSION" "$work_tree/VERSION"
}
