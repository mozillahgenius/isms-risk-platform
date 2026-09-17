package definition

import (
	"bytes"
	"encoding/hex"
	"runtime"
	"strings"
	"testing"
)

// macOSDefinitionSHA256 pins the macOS v2.json bytes. The posture
// definition_hash and the server's active definition depend on them, so
// adding Windows support must not change a single byte.
const macOSDefinitionSHA256 = "1c3e8ce01f123f0e558eabfb663828332369f715cc38bc40a0601afc3877aae1"

func TestMacOSDefinitionBytesAreUnchanged(t *testing.T) {
	raw, d, hash, err := LoadEmbeddedFor("macos")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, Embedded) || d.Platform != "macos" {
		t.Fatal("macOS embedded definition was not selected")
	}
	if got := hex.EncodeToString(hash[:]); got != macOSDefinitionSHA256 {
		t.Fatalf("macOS v2.json hash changed: %s", got)
	}
}

func TestEmbeddedWindowsDefinitionIsTheFixedAllowlist(t *testing.T) {
	raw, windows, _, err := LoadEmbeddedFor("windows")
	if err != nil {
		t.Fatal(err)
	}
	if windows.Version != 2 || windows.Platform != "windows" || !bytes.Equal(raw, EmbeddedWindows) {
		t.Fatalf("unexpected Windows definition: %d/%s", windows.Version, windows.Platform)
	}
	_, macos, _, err := LoadEmbeddedFor("macos")
	if err != nil {
		t.Fatal(err)
	}
	if len(windows.Items) != 14 || len(windows.Items) != len(macos.Items) {
		t.Fatalf("Windows definition has %d items", len(windows.Items))
	}
	for i := range macos.Items {
		if windows.Items[i].Name != macos.Items[i].Name || windows.Items[i].Kind != macos.Items[i].Kind {
			t.Fatalf("item %d differs in name/kind: macOS %s/%s, Windows %s/%s", i,
				macos.Items[i].Name, macos.Items[i].Kind, windows.Items[i].Name, windows.Items[i].Kind)
		}
	}
	for _, prohibited := range []string{
		"file_contents", "browser_history", "keystroke", "clipboard", "screenshot",
		"geolocation", "app_usage", "email_body", "chat_body",
	} {
		if strings.Contains(strings.ToLower(string(raw)), prohibited) {
			t.Fatalf("prohibited collection term appears in the Windows definition: %s", prohibited)
		}
	}
}

func TestWindowsDefinitionRejectsMutation(t *testing.T) {
	raw := EmbeddedWindows
	mutations := map[string][2]string{
		"Defender command":      {"Get-MpComputerStatus", "Get-MpPreference"},
		"PowerShell executable": {`C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`, `C:\\Windows\\System32\\cmd.exe`},
		"approved name":         {`"Bitwarden",`, `"Evil Vault",`},
		"EDR directory":         {`C:\\Program Files\\CrowdStrike\\`, `C:\\Users\\Public\\`},
		"admin exclusion":       {`"disabled:"`, `"_"`},
		"platform":              {`"platform": "windows"`, `"platform": "linux"`},
		"version":               {`"version": 2`, `"version": 3`},
		"output stream":         {`"output": "json"`, `"output": "stdout"`},
		"promotion":             {`"promotes_to": [`, `"promotes_to": ["firewall_enabled",`},
	}
	for name, mutation := range mutations {
		t.Run(name, func(t *testing.T) {
			mutated := bytes.Replace(raw, []byte(mutation[0]), []byte(mutation[1]), 1)
			if bytes.Equal(mutated, raw) {
				t.Fatalf("mutation %q did not apply", mutation[0])
			}
			if _, err := Parse(mutated); err == nil {
				t.Fatal("mutated Windows definition was accepted")
			}
		})
	}
	if _, err := Parse(append(append([]byte(nil), raw...), []byte("{}")...)); err == nil {
		t.Fatal("trailing JSON was accepted")
	}
}

func TestDefinitionPlatformsDoNotCross(t *testing.T) {
	macItemsAsWindows := bytes.Replace(Embedded, []byte(`"platform": "macos"`), []byte(`"platform": "windows"`), 1)
	if bytes.Equal(macItemsAsWindows, Embedded) {
		t.Fatal("platform mutation did not apply")
	}
	if _, err := Parse(macItemsAsWindows); err == nil {
		t.Fatal("macOS items were accepted under platform windows")
	}
	windowsItemsAsMac := bytes.Replace(EmbeddedWindows, []byte(`"platform": "windows"`), []byte(`"platform": "macos"`), 1)
	if _, err := Parse(windowsItemsAsMac); err == nil {
		t.Fatal("Windows items were accepted under platform macos")
	}
	if _, _, _, err := LoadEmbeddedFor("linux"); err == nil {
		t.Fatal("an embedded definition was returned for linux")
	}
}

func TestEmbeddedDefinitionFollowsRuntimeOS(t *testing.T) {
	if PlatformForGOOS("windows") != "windows" || PlatformForGOOS("darwin") != "macos" || PlatformForGOOS("linux") != "macos" {
		t.Fatal("unexpected GOOS to platform mapping")
	}
	_, d, _, err := LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	if d.Platform != PlatformForGOOS(runtime.GOOS) {
		t.Fatalf("LoadEmbedded selected %s on %s", d.Platform, runtime.GOOS)
	}
}

// Reverse test for the two review findings: the scripts must report read
// failures instead of silently producing "not configured" or an empty list.
func TestWindowsScriptsReportReadFailures(t *testing.T) {
	autoUpdate := expectedWindows["auto_update_checks_enabled"].Commands[0].Args[5]
	if !strings.Contains(autoUpdate, "policy_read=$r") || strings.Contains(autoUpdate, "-Name 'NoAutoUpdate'") {
		t.Fatal("auto update script does not separate an unreadable policy from an absent one")
	}
	for _, name := range []string{"password_manager_installed", "unapproved_apps"} {
		script := expectedWindows[name].Commands[0].Args[5]
		if !strings.Contains(script, "unreadable_keys=") || strings.Contains(script, "SilentlyContinue") {
			t.Fatalf("%s script can turn unreadable Uninstall keys into an empty list", name)
		}
	}
}
