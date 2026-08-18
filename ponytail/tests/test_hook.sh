#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export POLYTOKEN_HOOK_EVENT=pre_model_turn
mkdir -p "$HOME/.config/polytoken"
printf 'rules\n' > "$HOME/.config/polytoken/AGENTS.md"
cp "$root/config.json" "$HOME/.config/polytoken/ponytail-config.json"

result="$(bash "$root/hooks/ponytail-hook.sh")"
[[ "$(jq -r .outcome <<<"$result")" == proceed ]]
[[ "$(jq -r .additional_context <<<"$result")" == *"level: full"* ]]
[[ "$(jq -r .additional_context <<<"$result")" == *"rules"* ]]

export POLYTOKEN_HOOK_EVENT=pre_user_prompt
for command in 'ponytail ultra' '/ponytail ultra' '@ponytail ultra'; do
    result="$(jq -cn --arg prompt "$command" '{prompt:$prompt}' | bash "$root/hooks/ponytail-hook.sh")"
    [[ "$(jq -r .outcome <<<"$result")" == accept ]]
    [[ "$(<"$HOME/.config/polytoken/ponytail/mode")" == ultra ]]
done

result="$(jq -cn '{prompt:"ponytail off"}' | bash "$root/hooks/ponytail-hook.sh")"
[[ "$(jq -r .outcome <<<"$result")" == accept ]]
[[ ! -e "$HOME/.config/polytoken/ponytail/mode" ]]

printf 'Ponytail hook checks passed\n'
