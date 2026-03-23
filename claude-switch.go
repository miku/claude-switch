package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	exampleConfig = `{
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
`
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

type Profiles map[string]map[string]interface{}

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
	names := make([]string, 0, len(profiles))
	for name := range profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func currentSettings() (map[string]interface{}, error) {
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var settings map[string]interface{}
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, err
	}
	return settings, nil
}

func detectCurrentProfile(profiles Profiles) string {
	current, err := currentSettings()
	if err != nil || current == nil {
		return ""
	}
	currentJSON, _ := json.Marshal(current)
	for name, profile := range profiles {
		profileJSON, _ := json.Marshal(profile)
		if string(currentJSON) == string(profileJSON) {
			return name
		}
	}
	return ""
}

func applyProfile(name string, profile map[string]interface{}) error {
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

func initConfig() {
	cp := configPath()
	if err := os.MkdirAll(configDir(), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot create config directory: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(cp, []byte(exampleConfig), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "error: cannot write config: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Created example config at:\n\n")
	fmt.Printf("    \x1b[32m%s\x1b[0m\n\n", cp)
	fmt.Printf("Edit the file to add your API profiles, then run %s again. Each top-level key is a profile name.\nIts value becomes ~/.claude/settings.json when that profile is selected.\n", progName)
}

func profileSummary(profile map[string]interface{}) string {
	parts := []string{}
	for k, v := range profile {
		switch val := v.(type) {
		case string:
			parts = append(parts, fmt.Sprintf("%s=%s", k, val))
		case map[string]interface{}:
			if k == "env" {
				keys := make([]string, 0, len(val))
				for ek := range val {
					keys = append(keys, ek)
				}
				sort.Strings(keys)
				parts = append(parts, fmt.Sprintf("env=[%s]", strings.Join(keys, ",")))
			} else {
				parts = append(parts, fmt.Sprintf("%s={...}", k))
			}
		default:
			parts = append(parts, fmt.Sprintf("%s=%v", k, v))
		}
	}
	sort.Strings(parts)
	return strings.Join(parts, " ")
}

func listProfiles(profiles Profiles) {
	current := detectCurrentProfile(profiles)
	names := profileNames(profiles)
	for _, name := range names {
		marker := "  "
		if name == current {
			marker = "* "
		}
		summary := profileSummary(profiles[name])
		fmt.Printf("%s%-12s %s\n", marker, name, summary)
	}
}

func interactiveSelect(profiles Profiles) {
	current := detectCurrentProfile(profiles)
	names := profileNames(profiles)

	fmt.Println("Available profiles:")
	fmt.Println()
	for i, name := range names {
		marker := "  "
		if name == current {
			marker = "* "
		}
		summary := profileSummary(profiles[name])
		fmt.Printf("%s[%d] %-12s %s\n", marker, i+1, name, summary)
	}
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
		if name := detectCurrentProfile(profiles); name != "" {
			fmt.Println(name)
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
