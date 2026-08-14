#!/usr/bin/env bash
set -euo pipefail

arguments=()
while (($# > 0)); do
  if [[ $1 == -I ]]; then
    (($# >= 2)) || { echo "glslc compatibility wrapper: -I requires a directory" >&2; exit 2; }
    arguments+=("-I$2")
    shift 2
  else
    arguments+=("$1")
    shift
  fi
done

exec glslangValidator -V "${arguments[@]}"
