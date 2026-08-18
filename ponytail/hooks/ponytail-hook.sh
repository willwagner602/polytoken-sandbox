#!/usr/bin/env bash
set -euo pipefail

instructions_file="${HOME}/.config/polytoken/AGENTS.md"
if [[ ! -r "$instructions_file" ]]; then
    jq -cn '{outcome:"proceed"}'
    exit 0
fi

instructions="$(<"$instructions_file")"
jq -cn --arg context "PONYTAIL MODE ACTIVE — level: full\n\n${instructions}" \
    '{outcome:"proceed", additional_context:$context}'
