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
[[ "$(<"$HOME/.config/polytoken/ponytail/mode")" == off ]]

# Regression: off must persist across the NEXT hook call too — a prior bug
# deleted the mode file instead of writing "off", so the next pre_model_turn
# silently fell back to the configured default and re-injected full mode.
export POLYTOKEN_HOOK_EVENT=pre_model_turn
result="$(bash "$root/hooks/ponytail-hook.sh")"
[[ "$(jq -r .outcome <<<"$result")" == proceed ]]
[[ "$(jq -r 'has("additional_context")' <<<"$result")" == false ]]

printf 'Ponytail hook checks passed\n'

# PTS must not honor repository-controlled host mounts (.polytoken/volumes)
# or a repository-controlled build (.polytoken/Containerfile) without going
# through the trust-confirmation gate first. Keep this contract check cheap
# and independent of Podman; the gate's actual behavior is covered in depth
# by test_trust_gate.sh.
grep -Fq '_pts_confirm_trust "$project_volumes"' "$root/../polytoken-sandbox.sh"
grep -Fq '_pts_confirm_trust "$project_containerfile"' "$root/../polytoken-sandbox.sh"
printf 'PTS mount/build trust-gate contract check passed\n'
