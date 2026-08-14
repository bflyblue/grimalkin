#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for pull_request_target and release workflows that
# still run from a pre-native-CI revision of the default branch. New callers
# should invoke build-macos-native.sh and pass their Make targets explicitly.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ${1:-} == --prepare-only ]]; then
  exec "$script_dir/build-macos-native.sh" --prepare-only
fi

exec "$script_dir/build-macos-native.sh" "$@" test build
