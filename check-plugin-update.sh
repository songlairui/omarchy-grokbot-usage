#!/bin/bash
# Print "behind" only when GitHub's manifest version is newer than the
# manifest on disk, and this checkout can fast-forward to that commit.
# The menu version is the file Quickshell loaded. A dirty 1.2.0 tree is
# not "behind" GitHub 1.1.0 just because HEAD still points at 1.0.1.
# The marketplace verified snapshot is not consulted here.
dir=$(cd "$(dirname "$0")" && pwd)
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git -C "$dir" fetch --quiet origin HEAD || exit 0

local_head=$(git -C "$dir" rev-parse HEAD)
remote_head=$(git -C "$dir" rev-parse FETCH_HEAD)
if [[ $local_head == "$remote_head" ]]; then
  echo current
  exit 0
fi
git -C "$dir" merge-base --is-ancestor "$local_head" "$remote_head" || {
  echo current
  exit 0
}

read_version() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))'
}
local_ver=$(read_version <"$dir/manifest.json" 2>/dev/null || true)
remote_ver=$(git -C "$dir" show FETCH_HEAD:manifest.json 2>/dev/null | read_version || true)
if [[ -z $local_ver || -z $remote_ver || $local_ver == "$remote_ver" ]]; then
  echo current
  exit 0
fi
newer=$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort -V | tail -n 1)
if [[ $newer == "$remote_ver" ]]; then
  echo behind
else
  echo current
fi
