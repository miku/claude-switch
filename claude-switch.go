package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"text/tabwriter"
)

const (
	progName       = `claude-switch`
	configFilename = `claude-switch.json`
)

func configDir() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, progName)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot determine home directory: %v\n", err)
		os.Exit(1)
	}
	return filepath.Join(home, ".config", progName)
}

func configPath() string {
	return filepath.Join(configDir(), configFilename)
}

func settingsPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot determine home directory: %v\n", err)
		os.Exit(1)
	}
	return filepath.Join(home, ".claude", "settings.json")
}

type Profiles map[string]map[string]any

func loadConfig() (Profiles, error) {
	data, err := os.ReadFile(configPath())
	if err != nil {
		return nil, err
	}
	var profiles Profiles
	if err := json.Unmarshal(data, &profiles); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	return profiles, nil
}

func profileNames(profiles Profiles) []string {
	names := slices.Collect(maps.Keys(profiles))
	slices.Sort(names)
	return names
}

func currentSettings() (map[string]any, error) {
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, err
	}
	return settings, nil
}

func similarityScore(a, b map[string]any) float64 {
	aJSON, _ := json.Marshal(a)
	bJSON, _ := json.Marshal(b)
	aStr, bStr := string(aJSON), string(bJSON)

	if aStr == bStr {
		return 1.0
	}

	// Simple normalized similarity based on common prefix/suffix and length ratio
	la, lb := len(aStr), len(bStr)
	if la == 0 && lb == 0 {
		return 1.0
	}
	if la == 0 || lb == 0 {
		return 0.0
	}

	// Count matching runes
	maxLen := max(la, lb)
	matches := 0
	for i := 0; i < min(la, lb); i++ {
		if aStr[i] == bStr[i] {
			matches++
		}
	}
	return float64(matches) / float64(maxLen)
}

func detectCurrentProfile(profiles Profiles) (string, string) {
	current, err := currentSettings()
	if err != nil || current == nil {
		return "", ""
	}
	currentJSON, _ := json.Marshal(current)
	for name, profile := range profiles {
		profileJSON, _ := json.Marshal(profile)
		if string(currentJSON) == string(profileJSON) {
			return name, ""
		}
	}

	// No exact match - find closest
	var closestName string
	var closestScore float64
	for name, profile := range profiles {
		if score := similarityScore(current, profile); score > closestScore {
			closestScore = score
			closestName = name
		}
	}
	return "", closestName
}

func applyProfile(name string, profile map[string]any) error {
	data, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling settings: %w", err)
	}
	data = append(data, '\n')

	sp := settingsPath()
	if err := os.MkdirAll(filepath.Dir(sp), 0755); err != nil {
		return fmt.Errorf("creating settings directory: %w", err)
	}
	if err := os.WriteFile(sp, data, 0644); err != nil {
		return fmt.Errorf("writing settings: %w", err)
	}
	return nil
}

func buildInitialConfig() ([]byte, error) {
	profiles := Profiles{
		"z": {
			"env": map[string]any{
				"ANTHROPIC_AUTH_TOKEN": "your_zai_api_key",
				"ANTHROPIC_BASE_URL":   "https://api.z.ai/api/anthropic",
				"API_TIMEOUT_MS":       "3000000",
			},
		},
	}

	current, err := currentSettings()
	if err == nil && current != nil {
		profiles["default"] = current
	} else {
		profiles["default"] = map[string]any{
			"model":       "opus",
			"effortLevel": "high",
		}
	}

	data, err := json.MarshalIndent(profiles, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func initConfig() {
	cp := configPath()
	if err := os.MkdirAll(configDir(), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot create config directory: %v\n", err)
		os.Exit(1)
	}
	configData, err := buildInitialConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot build config: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(cp, configData, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot write config: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Created config at:\n\n")
	fmt.Printf("    \x1b[32m%s\x1b[0m\n\n", cp)
	fmt.Printf("Your current ~/.claude/settings.json has been saved as the \"default\" profile.\n")
	fmt.Printf("Edit the file to add more profiles, then run %s again. Each top-level key is a profile name.\nIts value becomes ~/.claude/settings.json when that profile is selected.\n", progName)
}

func profileSummary(profile map[string]any) string {
	parts := []string{}
	for k, v := range profile {
		switch val := v.(type) {
		case string:
			parts = append(parts, fmt.Sprintf("%s=%s", k, val))
		case map[string]any:
			if k == "env" {
				keys := slices.Collect(maps.Keys(val))
				slices.Sort(keys)
				parts = append(parts, fmt.Sprintf("env=[%s]", strings.Join(keys, ",")))
			} else {
				parts = append(parts, fmt.Sprintf("%s={...}", k))
			}
		default:
			parts = append(parts, fmt.Sprintf("%s=%v", k, v))
		}
	}
	slices.Sort(parts)
	return strings.Join(parts, " ")
}

func listProfiles(profiles Profiles) {
	current, similar := detectCurrentProfile(profiles)
	names := profileNames(profiles)
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 1, ' ', 0)
	for _, name := range names {
		marker := "  "
		if name == current {
			marker = "* "
		} else if name == similar && current == "" {
			marker = "~ "
		}
		summary := profileSummary(profiles[name])
		fmt.Fprintf(w, "%s%s\t %s\n", marker, name, summary)
	}
	w.Flush()

	if current == "" && similar != "" {
		fmt.Printf("\n\x1b[33m~\x1b[0m = closest match - current settings differ from all profiles. Some providers modify settings (e.g., model names).\n")
	}
}

func interactiveSelect(profiles Profiles) {
	current, _ := detectCurrentProfile(profiles)
	names := profileNames(profiles)

	fmt.Println("Available profiles:")
	fmt.Println()
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 1, ' ', 0)
	for i, name := range names {
		marker := "  "
		if name == current {
			marker = "* "
		}
		summary := profileSummary(profiles[name])
		fmt.Fprintf(w, "%s[%d] %s\t %s\n", marker, i+1, name, summary)
	}
	w.Flush()
	fmt.Println()
	fmt.Printf("Select profile [1-%d] or name: ", len(names))

	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		fmt.Println()
		return
	}
	input := strings.TrimSpace(scanner.Text())
	if input == "" {
		return
	}

	if n, err := strconv.Atoi(input); err == nil {
		if n < 1 || n > len(names) {
			fmt.Fprintf(os.Stderr, "error: invalid selection %d\n", n)
			os.Exit(1)
		}
		name := names[n-1]
		if err := applyProfile(name, profiles[name]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Switched to profile: %s\n", name)
		return
	}

	if profile, ok := profiles[input]; ok {
		if err := applyProfile(input, profile); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Switched to profile: %s\n", input)
		return
	}

	fmt.Fprintf(os.Stderr, "error: unknown profile %q\n", input)
	os.Exit(1)
}

func main() {
	listFlag := flag.Bool("l", false, "list available profiles")
	currentFlag := flag.Bool("c", false, "show current active profile")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [flags] [profile]\n\n", progName)
		fmt.Fprintf(os.Stderr, "Switch between Claude Code settings.json profiles.\n\n")
		fmt.Fprintf(os.Stderr, "With no arguments, shows an interactive selection menu.\n")
		fmt.Fprintf(os.Stderr, "With a profile name, switches to that profile directly.\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nConfig: %s\n", configPath())
		fmt.Fprintf(os.Stderr, "Target: %s\n", settingsPath())
	}
	flag.Parse()

	profiles, err := loadConfig()
	if os.IsNotExist(err) {
		initConfig()
		return
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	switch {
	case *listFlag:
		listProfiles(profiles)
	case *currentFlag:
		if name, similar := detectCurrentProfile(profiles); name != "" {
			fmt.Println(name)
		} else if similar != "" {
			fmt.Printf("(no exact match, closest: %s)\n", similar)
			fmt.Fprintln(os.Stderr, "\nNote: Some providers modify settings (e.g., model names), causing drift from saved profiles.")
		} else {
			fmt.Println("(no matching profile)")
		}
	case flag.NArg() > 0:
		name := flag.Arg(0)
		profile, ok := profiles[name]
		if !ok {
			fmt.Fprintf(os.Stderr, "error: unknown profile %q\n", name)
			fmt.Fprintf(os.Stderr, "Available profiles: %s\n", strings.Join(profileNames(profiles), ", "))
			os.Exit(1)
		}
		if err := applyProfile(name, profile); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Switched to profile: %s\n", name)
	default:
		interactiveSelect(profiles)
	}
}
