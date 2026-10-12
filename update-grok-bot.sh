#!/bin/bash
# Update the installed grok-bot package.
# Omarchy's own path is checkupdates + omarchy-update. That only moves the
# package when the Omarchy repo is actually newer. Otherwise hand the upstream
# build URL to whatever `omarchy default agent` is set to. That URL is often
# an AppImage, and it is the only newer build when the repo has not caught up.
set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/grokbot-usage/usage.json"
latest=""
source=""
if [[ -f $state ]]; then
  latest=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); u=d.get("update") or {}; print(u.get("latest") or "")' "$state" 2>/dev/null || true)
  source=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); u=d.get("update") or {}; print(u.get("source") or "")' "$state" 2>/dev/null || true)
  url=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); u=d.get("update") or {}; print(u.get("url") or "")' "$state" 2>/dev/null || true)
fi

repo_newer=0
if checkupdates --nocolor 2>/dev/null | awk '$1=="grok-bot" { found=1 } END { exit !found }'; then
  repo_newer=1
fi

if [[ $source == omarchy || $repo_newer == 1 ]]; then
  exec omarchy-update
fi

if [[ -z $(omarchy-default-agent) ]]; then
  echo "No default agent is set. Choose one with: omarchy default agent <name>" >&2
  exit 1
fi

# The feed is provider-controlled and the agent runs unattended. Only a
# dotted version and a plain downloads.cursor.com URL may enter the prompt.
target="the latest version"
if [[ ${latest:-} =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  target=$latest
fi
feed_step="If the repo is still older, stop. The download URL was not a plain https://downloads.cursor.com link, so it was left out."
url_re='^https://downloads\.cursor\.com/[A-Za-z0-9._~/?&=%+-]+$'
if [[ ${url:-} =~ $url_re ]]; then
  feed_step="If the repo is still older, install the upstream build at ${url}. That file may be an AppImage."
fi
# --inline stays in this terminal. omarchy-agent adds each agent's own
# unattended flags, so this is not pinned to one CLI.
exec omarchy-agent-prompt --inline \
  "Update grok-bot on this Omarchy machine to ${target}. Prefer a newer pacman package from the Omarchy repo when one exists. ${feed_step}"
