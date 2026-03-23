#!/bin/bash

# claude-switch.sh - Bash version of claude-switch utility
# Switch between Claude Code settings profiles

set -euo pipefail

PROG_NAME="claude-switch"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG_NAME"
CONFIG_FILE="$CONFIG_DIR/claude-switch.json"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Verify dependencies
for cmd in jq bc; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: $PROG_NAME requires '$cmd' but it is not installed" >&2
        exit 1
    fi
done

# Function to print usage
usage() {
    cat >&2 <<EOF
Usage: $PROG_NAME [flags] [profile]

Switch between Claude Code settings.json profiles.

With no arguments, shows an interactive selection menu.
With a profile name, switches to that profile directly.

Flags:
  -l, --list     list available profiles
  -c, --current  show current active profile
  -h, --help     show this help message

Config: $CONFIG_FILE
Target: $SETTINGS_FILE
EOF
}

# Function to get current settings as compact JSON
get_current_settings() {
    if [[ -f "$SETTINGS_FILE" ]]; then
        jq -c . "$SETTINGS_FILE"
    else
        echo ""
    fi
}

# Function to load config
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Function to initialize config (mirrors Go's initConfig)
init_config() {
    mkdir -p "$CONFIG_DIR"

    local default_profile
    if [[ -f "$SETTINGS_FILE" ]]; then
        default_profile=$(jq -c . "$SETTINGS_FILE")
    else
        default_profile='{"model":"opus","effortLevel":"high"}'
    fi

    local z_profile='{"env":{"ANTHROPIC_AUTH_TOKEN":"your_zai_api_key","ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","API_TIMEOUT_MS":"3000000"}}'

    # Build config with default and z profiles, then pretty-print
    jq -n --argjson default "$default_profile" --argjson z "$z_profile" \
        '{"default": $default, "z": $z}' > "$CONFIG_FILE"

    printf 'Created config at:\n\n'
    printf '    \033[32m%s\033[0m\n\n' "$CONFIG_FILE"
    printf 'Your current ~/.claude/settings.json has been saved as the "default" profile.\n'
    printf 'Edit the file to add more profiles, then run %s again. Each top-level key is a profile name.\nIts value becomes ~/.claude/settings.json when that profile is selected.\n' "$PROG_NAME"
}

# Function to calculate string similarity
calculate_similarity() {
    local str1="$1"
    local str2="$2"

    if [[ "$str1" == "$str2" ]]; then
        echo "1.0"
        return
    fi

    if [[ -z "$str1" && -z "$str2" ]]; then
        echo "1.0"
        return
    fi

    if [[ -z "$str1" || -z "$str2" ]]; then
        echo "0.0"
        return
    fi

    local len1=${#str1}
    local len2=${#str2}
    local max_len=$((len1 > len2 ? len1 : len2))

    if [[ $max_len -eq 0 ]]; then
        echo "1.0"
        return
    fi

    local matches=0
    local min_len=$((len1 < len2 ? len1 : len2))

    for ((i=0; i<min_len; i++)); do
        if [[ "${str1:$i:1}" == "${str2:$i:1}" ]]; then
            ((matches++))
        fi
    done

    echo "scale=10; $matches / $max_len" | bc -l
}

# Function to detect current profile
# Returns two lines: exact_match and closest_match (either may be empty)
detect_current_profile() {
    local profiles_json="$1"
    local current_settings
    current_settings=$(get_current_settings)

    if [[ -z "$current_settings" ]]; then
        echo ""
        echo ""
        return
    fi

    # Try exact match first (compare compact JSON)
    local profile_name
    while IFS= read -r profile_name; do
        [[ -z "$profile_name" ]] && continue
        local profile_json
        profile_json=$(jq -c --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")
        if [[ "$current_settings" == "$profile_json" ]]; then
            echo "$profile_name"
            echo ""
            return
        fi
    done < <(jq -r 'keys[]' <<< "$profiles_json")

    # No exact match - find closest using string similarity
    local best_score=0
    local best_profile=""

    while IFS= read -r profile_name; do
        [[ -z "$profile_name" ]] && continue

        local profile_json
        profile_json=$(jq -c --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

        local score
        score=$(calculate_similarity "$current_settings" "$profile_json")

        if (( $(echo "$score > $best_score" | bc -l) )); then
            best_score=$score
            best_profile="$profile_name"
        fi
    done < <(jq -r 'keys[]' <<< "$profiles_json")

    echo ""
    echo "$best_profile"
}

# Read detect_current_profile results into two variables
read_profile_detection() {
    local profiles_json="$1"
    local result
    result=$(detect_current_profile "$profiles_json")
    DETECTED_EXACT=$(sed -n '1p' <<< "$result")
    DETECTED_SIMILAR=$(sed -n '2p' <<< "$result")
}

# Function to apply profile
apply_profile() {
    local profile_name="$1"
    local profiles_json="$2"

    local profile_data
    profile_data=$(jq --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

    if [[ -z "$profile_data" || "$profile_data" == "null" ]]; then
        echo "error: unknown profile '$profile_name'" >&2
        return 1
    fi

    # Create settings directory if needed
    mkdir -p "$(dirname "$SETTINGS_FILE")"

    # Pretty-print with 2-space indent and trailing newline (matches Go's MarshalIndent)
    jq --indent 2 '.' <<< "$profile_data" > "$SETTINGS_FILE"
}

# Function to get profile summary
profile_summary() {
    local profile_name="$1"
    local profiles_json="$2"

    local profile_data
    profile_data=$(jq -r --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

    local parts=()

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue

        local value_type
        value_type=$(jq -r --arg k "$key" '.[$k] | type' <<< "$profile_data")

        case "$value_type" in
            string)
                local value
                value=$(jq -r --arg k "$key" '.[$k]' <<< "$profile_data")
                parts+=("$key=$value")
                ;;
            object)
                if [[ "$key" == "env" ]]; then
                    local env_keys
                    env_keys=$(jq -r --arg k "$key" '.[$k] | keys | join(",")' <<< "$profile_data")
                    parts+=("env=[$env_keys]")
                else
                    parts+=("$key={...}")
                fi
                ;;
            *)
                local value
                value=$(jq -r --arg k "$key" '.[$k]' <<< "$profile_data")
                parts+=("$key=$value")
                ;;
        esac
    done < <(jq -r 'keys[]' <<< "$profile_data")

    mapfile -t sorted_parts < <(printf '%s\n' "${parts[@]}" | sort)
    echo "${sorted_parts[*]}"
}

# Function to list profiles
list_profiles() {
    local profiles_json="$1"

    read_profile_detection "$profiles_json"
    local current_profile="$DETECTED_EXACT"
    local similar_profile="$DETECTED_SIMILAR"

    local profile_names
    mapfile -t profile_names < <(jq -r 'keys[]' <<< "$profiles_json")

    # Find max name length for formatting
    local max_name_len=0
    for name in "${profile_names[@]}"; do
        if [[ ${#name} -gt $max_name_len ]]; then
            max_name_len=${#name}
        fi
    done

    # Print each profile
    for name in "${profile_names[@]}"; do
        local marker="  "
        if [[ "$name" == "$current_profile" ]]; then
            marker="* "
        elif [[ -z "$current_profile" && "$name" == "$similar_profile" ]]; then
            marker="~ "
        fi

        local summary
        summary=$(profile_summary "$name" "$profiles_json")
        printf "%s%-${max_name_len}s %s\n" "$marker" "$name" "$summary"
    done

    if [[ -z "$current_profile" && -n "$similar_profile" ]]; then
        printf '\n\033[33m~\033[0m = closest match - current settings differ from all profiles. Some providers modify settings (e.g., model names).\n'
    fi
}

# Function for interactive selection
interactive_select() {
    local profiles_json="$1"

    read_profile_detection "$profiles_json"
    local current_profile="$DETECTED_EXACT"

    echo "Available profiles:"
    echo

    local profile_names
    mapfile -t profile_names < <(jq -r 'keys[]' <<< "$profiles_json")
    local num_profiles=${#profile_names[@]}

    # Find max name length for formatting
    local max_name_len=0
    for name in "${profile_names[@]}"; do
        if [[ ${#name} -gt $max_name_len ]]; then
            max_name_len=${#name}
        fi
    done

    local idx_width=${#num_profiles}

    # Print each profile with index
    for ((i=0; i<num_profiles; i++)); do
        local name="${profile_names[$i]}"
        local marker="  "
        if [[ "$name" == "$current_profile" ]]; then
            marker="* "
        fi

        local summary
        summary=$(profile_summary "$name" "$profiles_json")
        printf "%s[%*d] %-*s %s\n" "$marker" "$idx_width" "$((i+1))" "$max_name_len" "$name" "$summary"
    done

    echo
    printf "Select profile [1-%d] or name: " "$num_profiles"

    local input
    read -r input

    if [[ -z "$input" ]]; then
        return
    fi

    # Try numeric selection first
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        if [[ $input -ge 1 && $input -le $num_profiles ]]; then
            local selected_name="${profile_names[$((input-1))]}"
            apply_profile "$selected_name" "$profiles_json"
            echo "Switched to profile: $selected_name"
            return
        else
            echo "error: invalid selection $input" >&2
            exit 1
        fi
    fi

    # Try named selection
    if jq -e --arg prof "$input" 'has($prof)' <<< "$profiles_json" >/dev/null 2>&1; then
        apply_profile "$input" "$profiles_json"
        echo "Switched to profile: $input"
        return
    fi

    printf 'error: unknown profile %q\n' "$input" >&2
    exit 1
}

# Main execution
main() {
    local list_flag=false
    local current_flag=false
    local profile_arg=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--list)
                list_flag=true
                shift
                ;;
            -c|--current)
                current_flag=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown flag: $1" >&2
                usage
                exit 1
                ;;
            *)
                profile_arg="$1"
                shift
                ;;
        esac
    done

    # Load config (or initialize if missing)
    local profiles_json
    if ! profiles_json=$(load_config); then
        init_config
        return
    fi

    # Execute based on flags and arguments
    if [[ "$list_flag" == true ]]; then
        list_profiles "$profiles_json"
    elif [[ "$current_flag" == true ]]; then
        read_profile_detection "$profiles_json"
        if [[ -n "$DETECTED_EXACT" ]]; then
            echo "$DETECTED_EXACT"
        elif [[ -n "$DETECTED_SIMILAR" ]]; then
            printf '(no exact match, closest: %s)\n' "$DETECTED_SIMILAR"
            echo "" >&2
            echo "Note: Some providers modify settings (e.g., model names), causing drift from saved profiles." >&2
        else
            echo "(no matching profile)"
        fi
    elif [[ -n "$profile_arg" ]]; then
        if jq -e --arg prof "$profile_arg" 'has($prof)' <<< "$profiles_json" >/dev/null 2>&1; then
            apply_profile "$profile_arg" "$profiles_json"
            echo "Switched to profile: $profile_arg"
        else
            printf 'error: unknown profile %q\n' "$profile_arg" >&2
            echo "Available profiles: $(jq -r 'keys | join(", ")' <<< "$profiles_json")" >&2
            exit 1
        fi
    else
        interactive_select "$profiles_json"
    fi
}

# Run main function with all arguments
main "$@"
