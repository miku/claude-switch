#!/bin/bash

# claude-switch.sh - Bash version of claude-switch utility
# Switch between Claude Code settings profiles

set -euo pipefail

PROG_NAME="claude-switch"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG_NAME"
CONFIG_FILE="$CONFIG_DIR/claude-switch.json"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

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

# Function to get current settings as JSON
get_current_settings() {
    if [[ -f "$SETTINGS_FILE" ]]; then
        cat "$SETTINGS_FILE"
    else
        echo "{}"
    fi
}

# Function to load config
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        # Create initial config
        local initial_config
        initial_config=$(cat <<EOF
{
  "default": {
    "model": "opus",
    "effortLevel": "high"
  },
  "z": {
    "env": {
      "ANTHROPIC_AUTH_TOKEN": "your_zai_api_key",
      "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
      "API_TIMEOUT_MS": "3000000"
    }
  }
}
EOF
)
        echo "$initial_config" > "$CONFIG_FILE"
        echo "$initial_config"
    fi
}

# Function to detect current profile
detect_current_profile() {
    local profiles_json="$1"
    local current_settings
    current_settings=$(get_current_settings)

    # Try exact match first
    local matched_profile
    matched_profile=$(jq -r --argjson current "$current_settings" '
        to_entries[] |
        select(.value | tostring == $current | tostring) |
        .key
    ' <<< "$profiles_json" 2>/dev/null)

    if [[ -n "$matched_profile" ]]; then
        echo "$matched_profile"
        return
    fi

    # No exact match - find closest using string similarity
    local best_score=0
    local best_profile=""

    # Process each profile to calculate similarity
    while IFS= read -r profile_name; do
        if [[ -z "$profile_name" ]]; then continue; fi

        local profile_json
        profile_json=$(jq -r --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

        # Calculate similarity score
        local current_str
        current_str=$(echo "$current_settings" | jq -c .)
        local profile_str
        profile_str=$(echo "$profile_json" | jq -c .)

        local score
        score=$(calculate_similarity "$current_str" "$profile_str")

        if (( $(echo "$score > $best_score" | bc -l) )); then
            best_score=$score
            best_profile="$profile_name"
        fi
    done < <(jq -r 'keys[]' <<< "$profiles_json")

    if (( $(echo "$best_score > 0.5" | bc -l) )); then
        echo "$best_profile"
    else
        echo ""
    fi
}

# Function to calculate string similarity (simple implementation)
calculate_similarity() {
    local str1="$1"
    local str2="$2"

    # Handle empty strings
    if [[ -z "$str1" && -z "$str2" ]]; then
        echo "1.0"
        return
    fi

    if [[ -z "$str1" || -z "$str2" ]]; then
        echo "0.0"
        return
    fi

    # Simple approach: count matching characters from start
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

# Function to apply profile
apply_profile() {
    local profile_name="$1"
    local profiles_json="$2"

    local profile_data
    profile_data=$(jq -r --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

    if [[ -z "$profile_data" || "$profile_data" == "null" ]]; then
        echo "error: unknown profile '$profile_name'" >&2
        return 1
    fi

    # Create settings directory if needed
    mkdir -p "$(dirname "$SETTINGS_FILE")"

    # Apply the profile
    echo "$profile_data" > "$SETTINGS_FILE"
    echo "Switched to profile: $profile_name"
}

# Function to list profiles
list_profiles() {
    local profiles_json="$1"

    local current_profile
    current_profile=$(detect_current_profile "$profiles_json")

    # Get all profile names
    local profile_names
    profile_names=$(jq -r 'keys[]' <<< "$profiles_json")

    # Find max name length for formatting
    local max_name_len=0
    while IFS= read -r name; do
        if [[ -z "$name" ]]; then continue; fi
        local name_len=${#name}
        if [[ $name_len -gt $max_name_len ]]; then
            max_name_len=$name_len
        fi
    done <<< "$profile_names"

    # Print each profile
    while IFS= read -r name; do
        if [[ -z "$name" ]]; then continue; fi

        local marker="  "
        if [[ "$name" == "$current_profile" ]]; then
            marker="* "
        fi

        local summary
        summary=$(profile_summary "$name" "$profiles_json")
        printf "%s%-${max_name_len}s %s\n" "$marker" "$name" "$summary"
    done <<< "$profile_names"
}

# Function to get profile summary
profile_summary() {
    local profile_name="$1"
    local profiles_json="$2"

    local profile_data
    profile_data=$(jq -r --arg prof "$profile_name" '.[$prof]' <<< "$profiles_json")

    local parts=()

    # Iterate through profile keys
    while IFS= read -r key; do
        if [[ -z "$key" ]]; then continue; fi

        local value
        value=$(jq -r --arg k "$key" '.[$k]' <<< "$profile_data")

        case "$value" in
            null)
                parts+=("$key=null")
                ;;
            "true"|"false")
                parts+=("$key=$value")
                ;;
            \"*)
                parts+=("$key=$value")
                ;;
            *)
                # Check if it's a map/object
                if echo "$value" | grep -q '{'; then
                    local env_keys
                    env_keys=$(jq -r --arg k "$key" '.[$k] | keys[]' <<< "$profile_data" 2>/dev/null || echo "")
                    if [[ -n "$env_keys" ]]; then
                        local env_list
                        env_list=$(echo "$env_keys" | tr '\n' ',' | sed 's/,$//')
                        parts+=("$key=[$env_list]")
                    else
                        parts+=("$key={...}")
                    fi
                else
                    parts+=("$key=$value")
                fi
                ;;
        esac
    done < <(jq -r 'keys[]' <<< "$profile_data")

    # Sort parts and join
    IFS=$'\n' sorted_parts=($(sort <<<"${parts[*]}"))
    unset IFS
    echo "${sorted_parts[*]}" | tr ' ' ' '
}

# Function to interactive select
interactive_select() {
    local profiles_json="$1"

    echo "Available profiles:"
    echo

    local profile_names
    profile_names=$(jq -r 'keys[]' <<< "$profiles_json")

    # Find max name length for formatting
    local max_name_len=0
    while IFS= read -r name; do
        if [[ -z "$name" ]]; then continue; fi
        local name_len=${#name}
        if [[ $name_len -gt $max_name_len ]]; then
            max_name_len=$name_len
        fi
    done <<< "$profile_names"

    # Print each profile with index
    local i=1
    while IFS= read -r name; do
        if [[ -z "$name" ]]; then continue; fi

        local marker="  "
        if [[ "$name" == "$(detect_current_profile "$profiles_json")" ]]; then
            marker="* "
        fi

        local summary
        summary=$(profile_summary "$name" "$profiles_json")
        printf "%s[%*d] %-*s %s\n" "$marker" ${#profile_names} "$i" "$max_name_len" "$name" "$summary"
        ((i++))
    done <<< "$profile_names"

    echo
    echo -n "Select profile [1-$((i-1))] or name: "

    local input
    read -r input

    if [[ -z "$input" ]]; then
        return
    fi

    # Try numeric selection first
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local num_profiles
        num_profiles=$(jq -r 'length' <<< "$profiles_json")
        if [[ $input -ge 1 && $input -le $num_profiles ]]; then
            local profile_name
            profile_name=$(jq -r --argjson idx "$((input - 1))" 'keys[$idx]' <<< "$profiles_json")
            apply_profile "$profile_name" "$profiles_json"
            return
        else
            echo "error: invalid selection $input" >&2
            exit 1
        fi
    fi

    # Try named selection
    if jq -e --arg prof "$input" 'has($prof)' <<< "$profiles_json" >/dev/null 2>&1; then
        apply_profile "$input" "$profiles_json"
        return
    fi

    echo "error: unknown profile '$input'" >&2
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

    # Load config
    local profiles_json
    profiles_json=$(load_config)

    # Execute based on flags and arguments
    if [[ "$list_flag" == true ]]; then
        list_profiles "$profiles_json"
    elif [[ "$current_flag" == true ]]; then
        local current_profile
        current_profile=$(detect_current_profile "$profiles_json")
        if [[ -n "$current_profile" ]]; then
            echo "$current_profile"
        else
            local similar_profile
            similar_profile=$(detect_current_profile "$profiles_json")
            if [[ -n "$similar_profile" ]]; then
                echo "(no exact match, closest: $similar_profile)"
                echo ""
                echo "Note: Some providers modify settings (e.g., model names), causing drift from saved profiles."
            else
                echo "(no matching profile)"
            fi
        fi
    elif [[ -n "$profile_arg" ]]; then
        if jq -e --arg prof "$profile_arg" 'has($prof)' <<< "$profiles_json" >/dev/null 2>&1; then
            apply_profile "$profile_arg" "$profiles_json"
        else
            echo "error: unknown profile '$profile_arg'" >&2
            echo "Available profiles: $(jq -r 'keys[]' <<< "$profiles_json" | tr '\n' ', ' | sed 's/, $//')"
            exit 1
        fi
    else
        interactive_select "$profiles_json"
    fi
}

# Run main function with all arguments
main "$@"