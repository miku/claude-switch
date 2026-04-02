package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- pure functions ---

func TestProfileNames(t *testing.T) {
	profiles := Profiles{
		"charlie": {"model": "opus"},
		"alpha":   {"model": "sonnet"},
		"bravo":   {"model": "haiku"},
	}
	got := profileNames(profiles)
	want := []string{"alpha", "bravo", "charlie"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("index %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

func TestProfileNamesEmpty(t *testing.T) {
	got := profileNames(Profiles{})
	if len(got) != 0 {
		t.Errorf("got %v, want empty", got)
	}
}

func TestSimilarityScore(t *testing.T) {
	t.Run("identical", func(t *testing.T) {
		got := similarityScore(map[string]any{"k": "v"}, map[string]any{"k": "v"})
		if got != 1.0 {
			t.Errorf("got %f, want 1.0", got)
		}
	})
	t.Run("both nil", func(t *testing.T) {
		got := similarityScore(nil, nil)
		if got != 1.0 {
			t.Errorf("got %f, want 1.0", got)
		}
	})
	t.Run("both empty", func(t *testing.T) {
		got := similarityScore(map[string]any{}, map[string]any{})
		if got != 1.0 {
			t.Errorf("got %f, want 1.0", got)
		}
	})
	// Note: similarity is char-by-char on serialized JSON, so even
	// structurally different maps share JSON syntax characters ({, ", :, }).
	t.Run("one empty has low score", func(t *testing.T) {
		got := similarityScore(map[string]any{"k": "v"}, map[string]any{})
		if got >= 0.5 {
			t.Errorf("expected low similarity, got %f", got)
		}
	})
	t.Run("more different means lower score", func(t *testing.T) {
		base := map[string]any{"model": "opus", "effort": "high"}
		similar := map[string]any{"model": "opus", "effort": "low"}
		different := map[string]any{"x": "1", "y": "2"}
		scoreSimilar := similarityScore(base, similar)
		scoreDifferent := similarityScore(base, different)
		if scoreSimilar <= scoreDifferent {
			t.Errorf("similar (%f) should score higher than different (%f)", scoreSimilar, scoreDifferent)
		}
	})
}

func TestSimilarityScorePartial(t *testing.T) {
	a := map[string]any{"model": "opus"}
	b := map[string]any{"model": "sonnet"}
	score := similarityScore(a, b)
	if score <= 0.0 || score >= 1.0 {
		t.Errorf("expected partial similarity, got %f", score)
	}
}

func TestSimilarityScoreSymmetric(t *testing.T) {
	a := map[string]any{"model": "opus", "effort": "high"}
	b := map[string]any{"model": "sonnet"}
	if similarityScore(a, b) != similarityScore(b, a) {
		t.Error("similarity should be symmetric")
	}
}

func TestProfileSummary(t *testing.T) {
	tests := []struct {
		name     string
		profile  map[string]any
		contains []string
	}{
		{
			"string fields",
			map[string]any{"model": "opus", "effortLevel": "high"},
			[]string{"model=opus", "effortLevel=high"},
		},
		{
			"env keys",
			map[string]any{"env": map[string]any{"KEY_B": "b", "KEY_A": "a"}},
			[]string{"env=[KEY_A,KEY_B]"},
		},
		{
			"nested object",
			map[string]any{"permissions": map[string]any{"allow": []any{"Read"}}},
			[]string{"permissions={...}"},
		},
		{
			"mixed",
			map[string]any{"model": "opus", "env": map[string]any{"URL": "http://x"}},
			[]string{"env=[URL]", "model=opus"},
		},
		{
			"empty profile",
			map[string]any{},
			[]string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := profileSummary(tt.profile)
			for _, want := range tt.contains {
				if !strings.Contains(got, want) {
					t.Errorf("summary %q does not contain %q", got, want)
				}
			}
		})
	}
}

func TestProfileSummarySorted(t *testing.T) {
	profile := map[string]any{"z": "last", "a": "first", "m": "middle"}
	got := profileSummary(profile)
	// parts should be sorted: a=first m=middle z=last
	if !strings.HasPrefix(got, "a=first") {
		t.Errorf("expected sorted output, got %q", got)
	}
}

// --- filesystem-dependent functions ---

func setupTestDirs(t *testing.T) (configFile, settingsFile string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))

	configFile = configPath()
	settingsFile = settingsPath()
	if err := os.MkdirAll(filepath.Dir(configFile), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(settingsFile), 0755); err != nil {
		t.Fatal(err)
	}
	return configFile, settingsFile
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestConfigDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	t.Run("default", func(t *testing.T) {
		t.Setenv("XDG_CONFIG_HOME", "")
		got := configDir()
		want := filepath.Join(home, ".config", progName)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})

	t.Run("xdg override", func(t *testing.T) {
		xdg := filepath.Join(home, "custom-config")
		t.Setenv("XDG_CONFIG_HOME", xdg)
		got := configDir()
		want := filepath.Join(xdg, progName)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})
}

func TestSettingsPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	got := settingsPath()
	want := filepath.Join(home, ".claude", "settings.json")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLoadConfig(t *testing.T) {
	t.Run("valid config", func(t *testing.T) {
		cf, _ := setupTestDirs(t)
		writeJSON(t, cf, Profiles{
			"alpha": {"model": "opus"},
			"beta":  {"model": "sonnet"},
		})
		profiles, err := loadConfig()
		if err != nil {
			t.Fatal(err)
		}
		if len(profiles) != 2 {
			t.Errorf("got %d profiles, want 2", len(profiles))
		}
		if profiles["alpha"]["model"] != "opus" {
			t.Errorf("alpha.model = %v, want opus", profiles["alpha"]["model"])
		}
	})

	t.Run("missing file", func(t *testing.T) {
		setupTestDirs(t)
		_, err := loadConfig()
		if !os.IsNotExist(err) {
			t.Errorf("expected not-exist error, got %v", err)
		}
	})

	t.Run("invalid JSON", func(t *testing.T) {
		cf, _ := setupTestDirs(t)
		os.WriteFile(cf, []byte("{not json"), 0644)
		_, err := loadConfig()
		if err == nil {
			t.Error("expected error for invalid JSON")
		}
	})
}

func TestCurrentSettings(t *testing.T) {
	t.Run("existing file", func(t *testing.T) {
		_, sf := setupTestDirs(t)
		writeJSON(t, sf, map[string]any{"model": "opus"})
		settings, err := currentSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings["model"] != "opus" {
			t.Errorf("model = %v, want opus", settings["model"])
		}
	})

	t.Run("missing file", func(t *testing.T) {
		setupTestDirs(t)
		settings, err := currentSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings != nil {
			t.Errorf("expected nil, got %v", settings)
		}
	})
}

func TestDetectCurrentProfile(t *testing.T) {
	profiles := Profiles{
		"alpha": {"model": "opus"},
		"beta":  {"model": "sonnet"},
	}

	t.Run("exact match", func(t *testing.T) {
		_, sf := setupTestDirs(t)
		writeJSON(t, sf, map[string]any{"model": "opus"})
		exact, similar := detectCurrentProfile(profiles)
		if exact != "alpha" {
			t.Errorf("exact = %q, want alpha", exact)
		}
		if similar != "" {
			t.Errorf("similar = %q, want empty", similar)
		}
	})

	t.Run("no match finds closest", func(t *testing.T) {
		_, sf := setupTestDirs(t)
		writeJSON(t, sf, map[string]any{"model": "haiku"})
		exact, similar := detectCurrentProfile(profiles)
		if exact != "" {
			t.Errorf("exact = %q, want empty", exact)
		}
		if similar == "" {
			t.Error("expected a similar profile")
		}
	})

	t.Run("no settings file", func(t *testing.T) {
		setupTestDirs(t)
		exact, similar := detectCurrentProfile(profiles)
		if exact != "" || similar != "" {
			t.Errorf("expected both empty, got exact=%q similar=%q", exact, similar)
		}
	})
}

func TestApplyProfile(t *testing.T) {
	t.Run("writes settings", func(t *testing.T) {
		setupTestDirs(t)
		profile := map[string]any{
			"model": "opus",
			"env":   map[string]any{"KEY": "val"},
		}
		if err := applyProfile("test", profile); err != nil {
			t.Fatal(err)
		}
		settings, err := currentSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings["model"] != "opus" {
			t.Errorf("model = %v, want opus", settings["model"])
		}
		env, ok := settings["env"].(map[string]any)
		if !ok {
			t.Fatal("env is not a map")
		}
		if env["KEY"] != "val" {
			t.Errorf("env.KEY = %v, want val", env["KEY"])
		}
	})

	t.Run("creates directory", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
		// Don't create .claude dir — applyProfile should create it
		profile := map[string]any{"model": "opus"}
		if err := applyProfile("test", profile); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(settingsPath()); err != nil {
			t.Errorf("settings file not created: %v", err)
		}
	})

	t.Run("overwrites existing", func(t *testing.T) {
		_, sf := setupTestDirs(t)
		writeJSON(t, sf, map[string]any{"model": "opus"})
		if err := applyProfile("test", map[string]any{"model": "sonnet"}); err != nil {
			t.Fatal(err)
		}
		settings, err := currentSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings["model"] != "sonnet" {
			t.Errorf("model = %v, want sonnet", settings["model"])
		}
	})
}

func TestApplyProfileOutputFormat(t *testing.T) {
	setupTestDirs(t)
	profile := map[string]any{"model": "opus"}
	if err := applyProfile("test", profile); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		t.Fatal(err)
	}
	s := string(data)
	// Should be pretty-printed with 2-space indent and trailing newline
	if !strings.Contains(s, "  ") {
		t.Error("expected 2-space indentation")
	}
	if !strings.HasSuffix(s, "\n") {
		t.Error("expected trailing newline")
	}
}

func TestBuildInitialConfig(t *testing.T) {
	t.Run("with existing settings", func(t *testing.T) {
		_, sf := setupTestDirs(t)
		writeJSON(t, sf, map[string]any{"model": "sonnet", "effortLevel": "low"})
		data, err := buildInitialConfig()
		if err != nil {
			t.Fatal(err)
		}
		var profiles Profiles
		if err := json.Unmarshal(data, &profiles); err != nil {
			t.Fatal(err)
		}
		if profiles["default"]["model"] != "sonnet" {
			t.Errorf("default.model = %v, want sonnet", profiles["default"]["model"])
		}
		if _, ok := profiles["z"]; !ok {
			t.Error("expected z profile")
		}
	})

	t.Run("without settings", func(t *testing.T) {
		setupTestDirs(t)
		data, err := buildInitialConfig()
		if err != nil {
			t.Fatal(err)
		}
		var profiles Profiles
		if err := json.Unmarshal(data, &profiles); err != nil {
			t.Fatal(err)
		}
		if profiles["default"]["model"] != "opus" {
			t.Errorf("default.model = %v, want opus", profiles["default"]["model"])
		}
		if profiles["default"]["effortLevel"] != "high" {
			t.Errorf("default.effortLevel = %v, want high", profiles["default"]["effortLevel"])
		}
	})

	t.Run("valid JSON with trailing newline", func(t *testing.T) {
		setupTestDirs(t)
		data, err := buildInitialConfig()
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasSuffix(string(data), "\n") {
			t.Error("expected trailing newline")
		}
		var v any
		if err := json.Unmarshal(data, &v); err != nil {
			t.Errorf("output is not valid JSON: %v", err)
		}
	})
}

func TestDetectCurrentProfileExactOverSimilar(t *testing.T) {
	// When there's an exact match, it should be returned even if
	// another profile has high similarity.
	_, sf := setupTestDirs(t)
	profiles := Profiles{
		"alpha": {"model": "opus", "effortLevel": "high"},
		"beta":  {"model": "opus", "effortLevel": "high"},
	}
	writeJSON(t, sf, map[string]any{"model": "opus", "effortLevel": "high"})
	exact, _ := detectCurrentProfile(profiles)
	if exact == "" {
		t.Error("expected an exact match")
	}
}

func TestRoundTrip(t *testing.T) {
	// Apply a profile, then detect it — should get exact match.
	setupTestDirs(t)
	profiles := Profiles{
		"alpha": {"model": "opus", "effortLevel": "high"},
		"beta":  {"model": "sonnet"},
	}
	if err := applyProfile("beta", profiles["beta"]); err != nil {
		t.Fatal(err)
	}
	exact, _ := detectCurrentProfile(profiles)
	if exact != "beta" {
		t.Errorf("round-trip: got %q, want beta", exact)
	}
}
