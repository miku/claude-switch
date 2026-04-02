#!/bin/bash
# shellcheck disable=SC1090

# Test suite for claude-switch.sh
# Self-contained: uses temp directories, no external test framework needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-switch.sh"

PASS=0
FAIL=0
ERRORS=()

# --- test helpers ---

setup() {
    TEST_DIR=$(mktemp -d)
    export CLAUDE_SWITCH_CONFIG="$TEST_DIR/config/claude-switch.json"
    export CLAUDE_SWITCH_SETTINGS="$TEST_DIR/claude/settings.json"
    mkdir -p "$TEST_DIR/config" "$TEST_DIR/claude"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset CLAUDE_SWITCH_CONFIG CLAUDE_SWITCH_SETTINGS
}

write_config() {
    mkdir -p "$(dirname "$CLAUDE_SWITCH_CONFIG")"
    cat > "$CLAUDE_SWITCH_CONFIG"
}

write_settings() {
    mkdir -p "$(dirname "$CLAUDE_SWITCH_SETTINGS")"
    cat > "$CLAUDE_SWITCH_SETTINGS"
}

run_test() {
    local name="$1"
    shift
    setup
    if "$@" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf '  \033[32mPASS\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        ERRORS+=("$name")
        printf '  \033[31mFAIL\033[0m %s\n' "$name"
    fi
    teardown
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "  assert_eq failed${label:+ ($label)}" >&2
        echo "    expected: $expected" >&2
        echo "    actual:   $actual" >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  assert_contains failed${label:+ ($label)}" >&2
        echo "    looking for: $needle" >&2
        echo "    in:          $haystack" >&2
        return 1
    fi
}

assert_file_exists() {
    if [[ ! -f "$1" ]]; then
        echo "  assert_file_exists failed: $1" >&2
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    shift
    local actual=0
    "$@" || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        echo "  assert_exit_code failed: expected $expected, got $actual" >&2
        return 1
    fi
}

# --- unit tests (sourced functions) ---

test_calculate_similarity_identical() {
    source "$SCRIPT"
    local score
    score=$(calculate_similarity '{"a":1}' '{"a":1}')
    assert_eq "1000" "$score" "identical strings"
}

test_calculate_similarity_empty() {
    source "$SCRIPT"
    local score
    score=$(calculate_similarity "" "")
    assert_eq "1000" "$score" "both empty"
}

test_calculate_similarity_one_empty() {
    source "$SCRIPT"
    local score
    score=$(calculate_similarity "abc" "")
    assert_eq "0" "$score" "one empty"
}

test_calculate_similarity_partial() {
    source "$SCRIPT"
    local score
    score=$(calculate_similarity "abcd" "abxy")
    # 2 matches out of 4 = 500
    assert_eq "500" "$score" "partial match"
}

test_calculate_similarity_different_lengths() {
    source "$SCRIPT"
    local score
    score=$(calculate_similarity "abc" "abcdef")
    # 3 matches out of 6 (max_len) = 500
    assert_eq "500" "$score" "different lengths"
}

# --- integration tests (call script as subprocess) ---

test_init_creates_config() {
    local output
    output=$(bash "$SCRIPT" 2>&1)
    assert_file_exists "$CLAUDE_SWITCH_CONFIG"
    assert_contains "$output" "Created config at"

    # Config should be valid JSON with default and z profiles
    local keys
    keys=$(jq -r 'keys | join(",")' "$CLAUDE_SWITCH_CONFIG")
    assert_eq "default,z" "$keys" "profile names"
}

test_init_captures_existing_settings() {
    write_settings <<'EOF'
{"model":"sonnet","effortLevel":"low"}
EOF
    local output
    output=$(bash "$SCRIPT" 2>&1)

    local model
    model=$(jq -r '.default.model' "$CLAUDE_SWITCH_CONFIG")
    assert_eq "sonnet" "$model" "captured model"
}

test_list_profiles() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    local output
    output=$(bash "$SCRIPT" -l 2>&1)
    assert_contains "$output" "alpha"
    assert_contains "$output" "beta"
    assert_contains "$output" "model=opus"
    assert_contains "$output" "model=sonnet"
}

test_list_marks_current() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    write_settings <<'EOF'
{"model":"opus"}
EOF
    local output
    output=$(bash "$SCRIPT" -l 2>&1)
    # alpha should have * marker
    assert_contains "$output" "* alpha"
}

test_switch_by_name() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    local output
    output=$(bash "$SCRIPT" beta 2>&1)
    assert_eq "Switched to profile: beta" "$output"

    local model
    model=$(jq -r '.model' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "sonnet" "$model" "settings updated"
}

test_switch_by_number() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    # "2" selects beta (keys are sorted: alpha=1, beta=2)
    local output
    output=$(echo "2" | bash "$SCRIPT" 2>&1)
    assert_contains "$output" "Switched to profile: beta"

    local model
    model=$(jq -r '.model' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "sonnet" "$model" "settings updated"
}

test_switch_by_name_interactive() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    local output
    output=$(echo "alpha" | bash "$SCRIPT" 2>&1)
    assert_contains "$output" "Switched to profile: alpha"

    local model
    model=$(jq -r '.model' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "opus" "$model" "settings updated"
}

test_current_exact_match() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    write_settings <<'EOF'
{"model":"opus"}
EOF
    local output
    output=$(bash "$SCRIPT" -c 2>&1)
    assert_eq "alpha" "$output"
}

test_current_no_match() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    write_settings <<'EOF'
{"model":"haiku"}
EOF
    local output
    output=$(bash "$SCRIPT" -c 2>&1)
    assert_contains "$output" "no exact match, closest:"
}

test_current_no_settings() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    # No settings file at all
    local output
    output=$(bash "$SCRIPT" -c 2>&1)
    assert_eq "(no matching profile)" "$output"
}

test_unknown_profile_error() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    assert_exit_code 1 bash "$SCRIPT" nonexistent
}

test_invalid_number_error() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    assert_exit_code 1 bash -c "echo 99 | bash '$SCRIPT' >/dev/null"
}

test_help_flag() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    local output
    output=$(bash "$SCRIPT" -h 2>&1)
    assert_contains "$output" "Usage:"
    assert_contains "$output" "Switch between Claude Code"
}

test_unknown_flag_error() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    assert_exit_code 1 bash "$SCRIPT" --bogus
}

test_env_keys_in_summary() {
    write_config <<'EOF'
{"proxy":{"env":{"ANTHROPIC_BASE_URL":"http://localhost","API_KEY":"secret"}}}
EOF
    local output
    output=$(bash "$SCRIPT" -l 2>&1)
    assert_contains "$output" "env=[ANTHROPIC_BASE_URL,API_KEY]"
}

test_apply_preserves_json_structure() {
    write_config <<'EOF'
{"full":{"model":"opus","env":{"KEY":"val"},"permissions":{"allow":["Read"]}}}
EOF
    bash "$SCRIPT" full >/dev/null 2>&1
    # Verify nested structure survived the round-trip
    local key
    key=$(jq -r '.env.KEY' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "val" "$key" "env.KEY"

    local perm
    perm=$(jq -r '.permissions.allow[0]' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "Read" "$perm" "permissions.allow[0]"
}

test_empty_input_interactive_no_switch() {
    write_config <<'EOF'
{"alpha":{"model":"opus"}}
EOF
    # Empty input should do nothing (no settings file created)
    echo "" | bash "$SCRIPT" >/dev/null 2>&1 || true
    [[ ! -f "$CLAUDE_SWITCH_SETTINGS" ]]
}

test_switch_overwrites_existing_settings() {
    write_config <<'EOF'
{"alpha":{"model":"opus"},"beta":{"model":"sonnet"}}
EOF
    write_settings <<'EOF'
{"model":"opus"}
EOF
    bash "$SCRIPT" beta >/dev/null 2>&1

    local model
    model=$(jq -r '.model' "$CLAUDE_SWITCH_SETTINGS")
    assert_eq "sonnet" "$model" "overwritten to sonnet"
}

# --- run all tests ---

main() {
    echo "claude-switch.sh tests"
    echo

    echo "Unit tests:"
    run_test "similarity: identical"       test_calculate_similarity_identical
    run_test "similarity: both empty"      test_calculate_similarity_empty
    run_test "similarity: one empty"       test_calculate_similarity_one_empty
    run_test "similarity: partial match"   test_calculate_similarity_partial
    run_test "similarity: different lengths" test_calculate_similarity_different_lengths
    echo

    echo "Integration tests:"
    run_test "init creates config"         test_init_creates_config
    run_test "init captures settings"      test_init_captures_existing_settings
    run_test "list profiles"               test_list_profiles
    run_test "list marks current"          test_list_marks_current
    run_test "switch by name"              test_switch_by_name
    run_test "switch by number"            test_switch_by_number
    run_test "switch by name (interactive)" test_switch_by_name_interactive
    run_test "current: exact match"        test_current_exact_match
    run_test "current: no match"           test_current_no_match
    run_test "current: no settings file"   test_current_no_settings
    run_test "error: unknown profile"      test_unknown_profile_error
    run_test "error: invalid number"       test_invalid_number_error
    run_test "help flag"                   test_help_flag
    run_test "error: unknown flag"         test_unknown_flag_error
    run_test "env keys in summary"         test_env_keys_in_summary
    run_test "preserves JSON structure"    test_apply_preserves_json_structure
    run_test "empty input: no switch"      test_empty_input_interactive_no_switch
    run_test "switch overwrites settings"  test_switch_overwrites_existing_settings
    echo

    echo "---"
    echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo
        echo "Failed:"
        for e in "${ERRORS[@]}"; do
            echo "  - $e"
        done
        exit 1
    fi
}

main
