#!/usr/bin/env bash
set -euo pipefail

state_dir="${HOME}/.config/polytoken/ponytail"
config_file="${HOME}/.config/polytoken/ponytail-config.json"
mode_file="${state_dir}/mode"
instructions_file="${HOME}/.config/polytoken/AGENTS.md"

mkdir -p "$state_dir"

valid_mode() {
    case "$1" in
        off|lite|full|ultra) return 0 ;;
        *) return 1 ;;
    esac
}

default_mode() {
    if [[ -n "${PONYTAIL_DEFAULT_MODE:-}" ]] && valid_mode "$PONYTAIL_DEFAULT_MODE"; then
        printf '%s' "$PONYTAIL_DEFAULT_MODE"
        return
    fi
    if [[ -r "$config_file" ]]; then
        jq -r '.defaultMode // empty' "$config_file" 2>/dev/null | {
            read -r configured || true
            if valid_mode "${configured:-}"; then
                printf '%s' "$configured"
                return
            fi
            printf 'full'
        }
        return
    fi
    printf 'full'
}

mode=""
if [[ -r "$mode_file" ]]; then
    read -r mode <"$mode_file" || true
fi
valid_mode "$mode" || mode="$(default_mode)"

if [[ "$POLYTOKEN_HOOK_EVENT" == "pre_user_prompt" ]]; then
    prompt="$(jq -r '.prompt // empty' 2>/dev/null || true)"
    normalized="${prompt,,}"
    case "$normalized" in
        "ponytail lite"|"/ponytail lite"|"@ponytail lite") mode=lite ;;
        "ponytail full"|"/ponytail full"|"@ponytail full") mode=full ;;
        "ponytail ultra"|"/ponytail ultra"|"@ponytail ultra") mode=ultra ;;
        "ponytail off"|"/ponytail off"|"@ponytail off"|"stop ponytail"|"normal mode") mode=off ;;
        *) jq -cn '{outcome:"accept"}' ; exit 0 ;;
    esac
    printf '%s\n' "$mode" >"$mode_file"
    jq -cn --arg mode "$mode" '{outcome:"accept", additional_context:("PONYTAIL MODE CHANGED — level: " + $mode)}'
    exit 0
fi

if [[ "$mode" == off || ! -r "$instructions_file" ]]; then
    jq -cn '{outcome:"proceed"}'
    exit 0
fi

instructions="$(<"$instructions_file")"
jq -cn --arg context "PONYTAIL MODE ACTIVE — level: ${mode}\n\n${instructions}" \
    '{outcome:"proceed", additional_context:$context}'
