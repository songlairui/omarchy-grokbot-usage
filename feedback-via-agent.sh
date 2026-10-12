#!/bin/bash
# Ask the Omarchy default agent to file feedback with gh.
# The agent must confirm before creating the issue.
set -euo pipefail

if [[ -z $(omarchy-default-agent) ]]; then
  echo "No default agent is set. Choose one with: omarchy default agent <name>" >&2
  exit 1
fi

exec omarchy-agent-prompt --inline \
  "This is the omarchy-grokbot-usage plugin.
Issue page: https://github.com/songlairui/omarchy-grokbot-usage/issues
Prepare to create a feedback issue with the gh CLI in songlairui/omarchy-grokbot-usage.
If you understand the task, reply with only: Please enter your feedback
If something is unclear, ask that one question first. Do not create the issue yet."
