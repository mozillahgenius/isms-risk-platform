package collector

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/posture"
)

func windowsItem(t *testing.T, name string) definition.Item {
	t.Helper()
	_, d, _, err := definition.LoadEmbeddedFor("windows")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range d.Items {
		if item.Name == name {
			return item
		}
	}
	t.Fatalf("windows definition has no item %s", name)
	return definition.Item{}
}

func parseWindowsFor(t *testing.T, name, output string) ([]map[string]any, error) {
	t.Helper()
	return parseNative(windowsItem(t, name), []string{output})
}

func mustParseWindows(t *testing.T, name, output string) []map[string]any {
	t.Helper()
	rows, err := parseWindowsFor(t, name, output)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return rows
}

func TestWindowsParsersRejectBrokenJSON(t *testing.T) {
	names := []string{
		"disk_encrypted", "screen_lock", "os_version", "patch_current", "auto_update_checks_enabled",
		"firewall_enabled", "edr_running", "edr_vendor", "builtin_protection", "admin_account_count",
		"password_manager_installed", "unapproved_apps", "device_identity",
	}
	for _, name := range names {
		for _, broken := range []string{"", "{\"a\":", "[1,2]", "null", "Name  Enabled\n----  -------", "{} {}"} {
			if _, err := parseWindowsFor(t, name, broken); err == nil {
				t.Fatalf("%s accepted broken output %q", name, broken)
			}
		}
	}
}

func TestWindowsBitLockerParser(t *testing.T) {
	cases := []struct {
		output string
		want   any
	}{
		{`{"shell_protection":1,"cim_protection_status":null}`, true},
		{"\ufeff{\"shell_protection\":1,\"cim_protection_status\":null}\r\n", true},
		{`{"shell_protection":6,"cim_protection_status":null}`, true},
		{`{"shell_protection":2,"cim_protection_status":null}`, false},
		{`{"shell_protection":5,"cim_protection_status":1}`, false},
		{`{"shell_protection":null,"cim_protection_status":1}`, true},
		{`{"shell_protection":null,"cim_protection_status":0}`, false},
		{`{"shell_protection":null,"cim_protection_status":2}`, nil},
		{`{"shell_protection":null,"cim_protection_status":null}`, nil},
		{`{}`, nil},
	}
	for _, test := range cases {
		rows := mustParseWindows(t, "disk_encrypted", test.output)
		if len(rows) != 1 || rows[0]["encrypted"] != test.want {
			t.Fatalf("%s: got %+v, want %v", test.output, rows, test.want)
		}
	}
}

func TestWindowsScreenLockParser(t *testing.T) {
	const saver = `"C:\\Windows\\system32\\scrnsave.scr"`
	cases := []struct {
		name    string
		output  string
		enabled bool
		delay   int
	}{
		{"user secure screen saver", `{"user_active":"1","user_secure":"1","user_timeout":"600","user_saver":` + saver + `,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":null}`, true, 600},
		{"policy timeout wins", `{"user_active":"1","user_secure":"1","user_timeout":"600","user_saver":` + saver + `,"policy_active":"1","policy_secure":"1","policy_timeout":"300","policy_saver":null,"inactivity_timeout_secs":null}`, true, 300},
		{"policy turns password off", `{"user_active":"1","user_secure":"1","user_timeout":"600","user_saver":` + saver + `,"policy_active":null,"policy_secure":"0","policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":null}`, false, 0},
		{"no screen saver selected", `{"user_active":"1","user_secure":"1","user_timeout":"600","user_saver":null,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":null}`, false, 0},
		{"machine inactivity limit", `{"user_active":"1","user_secure":"0","user_timeout":"600","user_saver":null,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":900}`, true, 900},
		{"shortest delay", `{"user_active":"1","user_secure":"1","user_timeout":"600","user_saver":` + saver + `,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":120}`, true, 120},
		{"nothing configured", `{"user_active":null,"user_secure":null,"user_timeout":null,"user_saver":null,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":null}`, false, 0},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			rows := mustParseWindows(t, "screen_lock", test.output)
			if rows[0]["enabled"] != test.enabled || rows[0]["delay_seconds"] != test.delay {
				t.Fatalf("got %+v, want enabled=%v delay=%d", rows[0], test.enabled, test.delay)
			}
		})
	}
}

func TestWindowsOSVersionParser(t *testing.T) {
	rows := mustParseWindows(t, "os_version", `{"version":"10.0.22631"}`)
	if rows[0]["major"] != "10" || rows[0]["minor"] != "0" || rows[0]["patch"] != "22631" {
		t.Fatalf("unexpected os version row: %+v", rows[0])
	}
	for _, missing := range []string{`{"version":null}`, `{}`, `{"version":"Windows 11"}`, `{"version":"10.0.22631.1.2"}`} {
		if _, err := parseWindowsFor(t, "os_version", missing); err == nil {
			t.Fatalf("invalid os version accepted: %s", missing)
		}
	}
}

func TestWindowsPatchCurrentParser(t *testing.T) {
	cases := map[string]bool{
		`{"pending_count":0}`:    true,
		`{"pending_count":3}`:    false,
		`{"pending_count":null}`: false, // unreadable is not current (fail closed)
		`{}`:                     false,
	}
	for output, want := range cases {
		rows := mustParseWindows(t, "patch_current", output)
		if rows[0]["current"] != want {
			t.Fatalf("%s: got %+v, want %v", output, rows[0], want)
		}
	}
}

func TestWindowsAutoUpdateParser(t *testing.T) {
	cases := []struct {
		output string
		want   any
	}{
		{`{"policy_read":true,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Manual"}`, true},
		{`{"policy_read":true,"no_auto_update":0,"au_options":4,"wuauserv_start_mode":"Auto"}`, true},
		{`{"policy_read":true,"no_auto_update":1,"au_options":null,"wuauserv_start_mode":"Manual"}`, false},
		{`{"policy_read":true,"no_auto_update":null,"au_options":1,"wuauserv_start_mode":"Manual"}`, false},
		{`{"policy_read":true,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Disabled"}`, false},
		{`{"policy_read":true,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":null}`, nil},
		{`{"policy_read":true,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":""}`, nil},
		// Reverse cases: the AU policy could not be read, so NoAutoUpdate=1 may
		// be hidden behind the failure. A running service must not make it true.
		{`{"policy_read":false,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"policy_read":false,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Manual"}`, nil},
		{`{"policy_read":null,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"policy_read":false,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Disabled"}`, false},
		// Reverse cases: the policy value exists but cannot be interpreted. It is
		// not "not configured", so a running service must not make it true.
		{`{"policy_read":true,"no_auto_update":"invalid","au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"policy_read":true,"no_auto_update":null,"au_options":"x","wuauserv_start_mode":"Manual"}`, nil},
		{`{"policy_read":true,"no_auto_update":[1,0,0,0],"au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"policy_read":true,"no_auto_update":0.5,"au_options":null,"wuauserv_start_mode":"Auto"}`, nil},
		{`{"policy_read":true,"no_auto_update":"invalid","au_options":1,"wuauserv_start_mode":"Auto"}`, false},
		{`{"policy_read":true,"no_auto_update":"0","au_options":null,"wuauserv_start_mode":"Auto"}`, true},
	}
	for _, test := range cases {
		rows := mustParseWindows(t, "auto_update_checks_enabled", test.output)
		if rows[0]["enabled"] != test.want {
			t.Fatalf("%s: got %+v, want %v", test.output, rows[0], test.want)
		}
	}
}

func TestWindowsFirewallParser(t *testing.T) {
	cases := []struct {
		output string
		want   any
	}{
		{`{"profile_count":3,"enabled_profiles":["Domain","Private","Public"],"disabled_profiles":[]}`, true},
		{`{"profile_count":3,"enabled_profiles":["Domain","Private"],"disabled_profiles":"Public"}`, false},
		{`{"profile_count":1,"enabled_profiles":"Domain","disabled_profiles":[]}`, true},
		{`{"profile_count":3,"enabled_profiles":{"value":["Domain","Private","Public"],"Count":3},"disabled_profiles":{"value":[],"Count":0}}`, true},
		{`{"profile_count":0,"enabled_profiles":[],"disabled_profiles":[]}`, false},
		{`{"profile_count":null,"enabled_profiles":null,"disabled_profiles":null}`, nil},
	}
	for _, test := range cases {
		rows := mustParseWindows(t, "firewall_enabled", test.output)
		if rows[0]["enabled"] != test.want {
			t.Fatalf("%s: got %+v, want %v", test.output, rows[0], test.want)
		}
	}
}

func TestWindowsEDRParser(t *testing.T) {
	output := `{"process_paths":["C:\\Windows\\explorer.exe","c:\\program files\\sentinelone\\Sentinel Agent 23.4.2.14\\SentinelAgent.exe","C:\\Temp\\SentinelOne\\fake.exe"],` +
		`"service_paths":["\"C:\\Program Files\\CrowdStrike\\CSFalconService.exe\" -k","C:\\Windows\\system32\\svchost.exe -k netsvcs","C:\\Program Files\\SentinelOne\\Sentinel Agent 23.4.2.14\\SentinelServiceHost.exe"]}`
	rows := mustParseWindows(t, "edr_running", output)
	if len(rows) != 3 {
		t.Fatalf("unexpected EDR rows: %+v", rows)
	}
	vendors := mustParseWindows(t, "edr_vendor", output)
	if len(vendors) != 2 || vendors[0]["vendor"] != "crowdstrike" || vendors[1]["vendor"] != "sentinelone" {
		t.Fatalf("unexpected EDR vendors: %+v", vendors)
	}
	none := `{"process_paths":["C:\\Temp\\SentinelOne\\fake.exe"],"service_paths":[]}`
	if rows := mustParseWindows(t, "edr_running", none); len(rows) != 0 {
		t.Fatalf("path outside the vendor directory was accepted: %+v", rows)
	}
	if rows := mustParseWindows(t, "edr_vendor", none); len(rows) != 1 || rows[0]["vendor"] != "none" {
		t.Fatalf("expected vendor none: %+v", rows)
	}
	single := `{"process_paths":"C:\\Program Files\\CrowdStrike\\CSFalconContainer.exe","service_paths":null}`
	if rows := mustParseWindows(t, "edr_running", single); len(rows) != 1 {
		t.Fatalf("single-string process list was not accepted: %+v", rows)
	}
	for _, name := range []string{"edr_running", "edr_vendor"} {
		rows := mustParseWindows(t, name, `{"process_paths":null,"service_paths":null}`)
		if !rowsUnavailable(rows) {
			t.Fatalf("%s: unreadable process lists were not marked unavailable: %+v", name, rows)
		}
	}
}

func TestWindowsServiceExecutable(t *testing.T) {
	cases := map[string]string{
		`"C:\Program Files\CrowdStrike\CSFalconService.exe" -k`: `C:\Program Files\CrowdStrike\CSFalconService.exe`,
		`C:\Windows\system32\svchost.exe -k netsvcs -p`:         `C:\Windows\system32\svchost.exe`,
		`C:\Program Files\SentinelOne\Agent\SentinelAgent.EXE`:  `C:\Program Files\SentinelOne\Agent\SentinelAgent.EXE`,
		`"C:\unterminated`: ``,
		`\SystemRoot\System32\drivers\CrowdStrike\csagent.sys`: `\SystemRoot\System32\drivers\CrowdStrike\csagent.sys`,
	}
	for input, want := range cases {
		if got := windowsServiceExecutable(input); got != want {
			t.Fatalf("%q: got %q, want %q", input, got, want)
		}
	}
}

func TestWindowsBuiltinProtectionParser(t *testing.T) {
	rows := mustParseWindows(t, "builtin_protection", `{"antivirus_enabled":true,"realtime_protection_enabled":true,"antivirus_signature_version":"1.417.123.0","is_tamper_protected":true,"smartscreen_policy":null,"smartscreen_explorer":"Warn"}`)
	want := map[string]any{
		"defender_antivirus_enabled": true, "defender_realtime_enabled": true,
		"defender_signature_version": "1.417.123.0", "tamper_protection_enabled": true, "smartscreen_enabled": true,
	}
	if !reflect.DeepEqual(rows[0], want) {
		t.Fatalf("got %+v, want %+v", rows[0], want)
	}
	rows = mustParseWindows(t, "builtin_protection", `{"antivirus_enabled":null,"realtime_protection_enabled":null,"antivirus_signature_version":null,"is_tamper_protected":null,"smartscreen_policy":null,"smartscreen_explorer":null}`)
	want = map[string]any{
		"defender_antivirus_enabled": false, "defender_realtime_enabled": false,
		"defender_signature_version": "unavailable", "tamper_protection_enabled": false, "smartscreen_enabled": nil,
	}
	if !reflect.DeepEqual(rows[0], want) {
		t.Fatalf("unreadable Defender status: got %+v, want %+v", rows[0], want)
	}
	smartScreen := []struct {
		policy, explorer string
		want             any
	}{
		{"0", `"Warn"`, false},
		{"1", `"Off"`, true},
		{"null", `"Off"`, false},
		{"null", `"RequireAdmin"`, true},
		{"null", `"Prompt"`, true},
		{"null", `"Something"`, nil},
		{"null", "null", nil},
	}
	for _, test := range smartScreen {
		output := `{"antivirus_enabled":true,"realtime_protection_enabled":true,"antivirus_signature_version":"1.1","is_tamper_protected":true,"smartscreen_policy":` + test.policy + `,"smartscreen_explorer":` + test.explorer + `}`
		rows := mustParseWindows(t, "builtin_protection", output)
		if rows[0]["smartscreen_enabled"] != test.want {
			t.Fatalf("policy=%s explorer=%s: got %v, want %v", test.policy, test.explorer, rows[0]["smartscreen_enabled"], test.want)
		}
	}
}

func TestWindowsAdminParser(t *testing.T) {
	rows := mustParseWindows(t, "admin_account_count", `{"members":["disabled:Administrator","operator","Domain Admins"]}`)
	if len(rows) != 2 || rows[0]["username"] != "operator" || rows[1]["username"] != "Domain Admins" {
		t.Fatalf("disabled built-in Administrator was not excluded by the definition: %+v", rows)
	}
	if rows := mustParseWindows(t, "admin_account_count", `{"members":"operator"}`); len(rows) != 1 {
		t.Fatalf("single-member output was not accepted: %+v", rows)
	}
	if rows := mustParseWindows(t, "admin_account_count", `{"members":[]}`); len(rows) != 0 {
		t.Fatalf("empty group was not zero: %+v", rows)
	}
	if rows := mustParseWindows(t, "admin_account_count", `{"members":null}`); !rowsUnavailable(rows) {
		t.Fatalf("unreadable group was not marked unavailable: %+v", rows)
	}
}

func TestWindowsApplicationParsers(t *testing.T) {
	output := `{"display_names":["1Password","Bitwarden 2024.6.0","Google Chrome","Microsoft Edge",` +
		`"Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.38.33130","Slack","7-Zip 23.01 (x64)","AC/DC Tool",` +
		`"Mozilla Firefox (x64 ja)","KeePassXC"],"unreadable_keys":0}`
	managers := mustParseWindows(t, "password_manager_installed", output)
	if len(managers) != 3 || managers[0]["name"] != "1Password" || managers[1]["name"] != "Bitwarden" || managers[2]["name"] != "KeePassXC" {
		t.Fatalf("unexpected password managers: %+v", managers)
	}
	unapproved := mustParseWindows(t, "unapproved_apps", output)
	got := make([]string, 0, len(unapproved))
	for _, row := range unapproved {
		got = append(got, row["name"].(string))
	}
	// "Mozilla Firefox" is the real DisplayName of Firefox on Windows and does
	// not equal the approved name "Firefox": it is reported as unapproved until
	// the approved list says otherwise. The test pins that behaviour.
	want := []string{"7-Zip", "AC_DC Tool", "Microsoft Visual C++ 2015-2022 Redistributable", "Mozilla Firefox", "Slack"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unapproved apps: got %v, want %v", got, want)
	}
	// Reverse cases: some Uninstall keys could not be read. The inventory is
	// reported as unverifiable (fixed mismatch entry, password manager null
	// unless one was seen) instead of failing the whole posture or passing as
	// an empty clean list.
	partial := []struct {
		output     string
		unapproved []any
		managers   string
	}{
		{`{"display_names":[],"unreadable_keys":1}`, []any{windowsInventoryUnreadable}, "unavailable"},
		{`{"display_names":["Slack","Bitwarden 2024.6.0"],"unreadable_keys":2}`, []any{"Slack", windowsInventoryUnreadable}, "Bitwarden"},
	}
	for _, test := range partial {
		rows := mustParseWindows(t, "unapproved_apps", test.output)
		got := make([]any, 0, len(rows))
		for _, row := range rows {
			if name, ok := row["name"]; ok {
				got = append(got, name)
			} else {
				got = append(got, row["inventory_mismatch"])
			}
		}
		if !reflect.DeepEqual(got, test.unapproved) {
			t.Fatalf("%s: unapproved rows %v, want %v", test.output, got, test.unapproved)
		}
		managers := mustParseWindows(t, "password_manager_installed", test.output)
		if test.managers == "unavailable" {
			if !rowsUnavailable(managers) {
				t.Fatalf("%s: password manager was not unverified: %+v", test.output, managers)
			}
		} else if len(managers) != 1 || managers[0]["name"] != test.managers {
			t.Fatalf("%s: observed password manager was dropped: %+v", test.output, managers)
		}
	}
	// An inventory that could not be walked at all still fails collection, as
	// on macOS when system_profiler or find fails.
	for _, name := range []string{"password_manager_installed", "unapproved_apps"} {
		for _, unreadable := range []string{
			`{"display_names":null,"unreadable_keys":null}`,
			`{"display_names":null}`,
			`{"display_names":[]}`,
			`{"display_names":[],"unreadable_keys":"x"}`,
		} {
			if rows, err := parseWindowsFor(t, name, unreadable); err == nil {
				t.Fatalf("%s: unreadable inventory %s became a result: %+v", name, unreadable, rows)
			}
		}
	}
	if rows := mustParseWindows(t, "password_manager_installed", `{"display_names":"Bitwarden","unreadable_keys":0}`); len(rows) != 1 {
		t.Fatalf("single-name output was not accepted: %+v", rows)
	}
	if rows := mustParseWindows(t, "unapproved_apps", `{"display_names":[],"unreadable_keys":0}`); len(rows) != 0 {
		t.Fatalf("readable empty inventory was not empty: %+v", rows)
	}
}

func TestWindowsDeviceIdentityParser(t *testing.T) {
	rows := mustParseWindows(t, "device_identity", `{"model":"Surface Laptop 5","serial":"0F1234","hostname":"WIN-01"}`)
	if rows[0]["os_family"] != "windows" || rows[0]["model"] != "Surface Laptop 5" || rows[0]["hostname"] != "WIN-01" || rows[0]["serial"] != "0F1234" {
		t.Fatalf("unexpected identity: %+v", rows[0])
	}
	if rows := mustParseWindows(t, "device_identity", `{"model":"Virtual Machine","serial":null,"hostname":"WIN-02"}`); rows[0]["serial"] != "" {
		t.Fatalf("missing serial was not empty: %+v", rows[0])
	}
	for _, missing := range []string{`{"model":null,"serial":"1","hostname":"WIN-01"}`, `{"model":"X","serial":"1","hostname":""}`} {
		if _, err := parseWindowsFor(t, "device_identity", missing); err == nil {
			t.Fatalf("incomplete identity accepted: %s", missing)
		}
	}
}

func loadWindowsFixture(t *testing.T) (definition.Definition, [32]byte, FixtureRunner) {
	t.Helper()
	_, d, hash, err := definition.LoadEmbeddedFor("windows")
	if err != nil {
		t.Fatal(err)
	}
	runner, err := LoadFixture(filepath.Join("..", "..", "testdata", "fixture-good-windows.json"))
	if err != nil {
		t.Fatal(err)
	}
	return d, hash, runner
}

func collectWindows(t *testing.T, d definition.Definition, runner FixtureRunner) (posture.Snapshot, error) {
	t.Helper()
	previous := nowUTC
	nowUTC = func() string { return "2026-09-13T00:00:00Z" }
	defer func() { nowUTC = previous }()
	return Collect(context.Background(), d, runner, Metadata{
		DeviceID: "00000000-0000-4000-8000-000000000007", ExternalID: "serial", AgentVer: "test",
	})
}

func TestCollectWindowsFixtureValidatesAndCanonicalizes(t *testing.T) {
	d, hash, runner := loadWindowsFixture(t)
	snapshot, err := collectWindows(t, d, runner)
	if err != nil {
		t.Fatal(err)
	}
	snapshot.DefinitionHash = hex.EncodeToString(hash[:])
	snapshot.SortApps()
	if err := snapshot.Validate(); err != nil {
		t.Fatal(err)
	}
	canonical, err := snapshot.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(canonical, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["os_family"] != "windows" || payload["os_version"] != "10.0.22631" || payload["model"] != "Surface Laptop 5" {
		t.Fatalf("unexpected windows payload: %s", canonical)
	}
	if len(payload) != 24 {
		t.Fatalf("top-level key count changed: %d", len(payload))
	}
	protection, ok := payload["builtin_protection"].(map[string]any)
	if !ok || len(protection) != 5 {
		t.Fatalf("builtin_protection is not the 5-key Windows shape: %s", canonical)
	}
	if value, present := protection["smartscreen_enabled"]; !present || value != nil {
		t.Fatalf("smartscreen_enabled must be present as null: %s", canonical)
	}
	if mismatches, ok := payload["application_inventory_mismatches"].([]any); !ok || len(mismatches) != 0 {
		t.Fatalf("application_inventory_mismatches must be empty on Windows: %s", canonical)
	}
	parsed, err := posture.ParseSnapshot(canonical)
	if err != nil {
		t.Fatalf("canonical Windows posture did not parse strictly: %v", err)
	}
	again, err := parsed.Canonical()
	if err != nil || string(again) != string(canonical) {
		t.Fatalf("canonical Windows posture did not round-trip: %v\n%s\n%s", err, canonical, again)
	}
}

func TestCollectWindowsPromotesActiveDefenderToEDRRunning(t *testing.T) {
	cases := []struct {
		name     string
		mutate   func(map[string]any)
		promoted bool
	}{
		{"active", func(map[string]any) {}, true},
		{"tamper protection off", func(row map[string]any) { row["tamper_protection_enabled"] = false }, false},
		{"realtime off", func(row map[string]any) { row["defender_realtime_enabled"] = false }, false},
		{"antivirus off", func(row map[string]any) { row["defender_antivirus_enabled"] = false }, false},
		{"signature unavailable", func(row map[string]any) { row["defender_signature_version"] = "unavailable" }, false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			d, _, runner := loadWindowsFixture(t)
			runner.Rows["edr_running"] = []map[string]any{}
			runner.Rows["edr_vendor"] = []map[string]any{{"vendor": "none"}}
			row := map[string]any{}
			for key, value := range runner.Rows["builtin_protection"][0] {
				row[key] = value
			}
			test.mutate(row)
			runner.Rows["builtin_protection"] = []map[string]any{row}
			snapshot, err := collectWindows(t, d, runner)
			if err != nil {
				t.Fatal(err)
			}
			if snapshot.EDRRunning == nil || *snapshot.EDRRunning != test.promoted || snapshot.EDRVendor != "none" {
				t.Fatalf("promotion mismatch (want %v): %+v", test.promoted, snapshot)
			}
		})
	}
}

func TestCollectWindowsRejectsXProtectKeysInBuiltinProtection(t *testing.T) {
	d, _, runner := loadWindowsFixture(t)
	mixed := map[string]any{"xprotect_process_count": 5}
	for key, value := range runner.Rows["builtin_protection"][0] {
		mixed[key] = value
	}
	runner.Rows["builtin_protection"] = []map[string]any{mixed}
	if _, err := collectWindows(t, d, runner); err == nil {
		t.Fatal("Windows builtin_protection with an XProtect key was accepted")
	}
	runner.Rows["builtin_protection"] = []map[string]any{{
		"xprotect_process_count": 5, "xprotect_definition_version": "5355", "xprotect_remediator_version": "157",
		"spctl_assessments_enabled": true, "csrutil_enabled": true, "system_extensions": []string{},
	}}
	if _, err := collectWindows(t, d, runner); err == nil {
		t.Fatal("macOS builtin_protection row was accepted by the Windows definition")
	}
}

func TestCollectWindowsKeepsUnavailableValuesNull(t *testing.T) {
	d, hash, runner := loadWindowsFixture(t)
	unavailable := []map[string]any{{"unavailable": true}}
	runner.Rows["disk_encrypted"] = []map[string]any{{"encrypted": nil}}
	runner.Rows["auto_update_checks_enabled"] = []map[string]any{{"enabled": nil}}
	runner.Rows["firewall_enabled"] = []map[string]any{{"enabled": nil}}
	runner.Rows["edr_running"] = unavailable
	runner.Rows["edr_vendor"] = unavailable
	runner.Rows["admin_account_count"] = unavailable
	runner.Rows["builtin_protection"] = []map[string]any{{
		"defender_antivirus_enabled": false, "defender_realtime_enabled": false,
		"defender_signature_version": "unavailable", "tamper_protection_enabled": false, "smartscreen_enabled": nil,
	}}
	snapshot, err := collectWindows(t, d, runner)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.DiskEncrypted != nil || snapshot.AutoUpdateChecksEnabled != nil || snapshot.FirewallEnabled != nil ||
		snapshot.EDRRunning != nil || snapshot.AdminAccountCount != nil {
		t.Fatalf("unavailable values were filled in: %+v", snapshot)
	}
	if snapshot.EDRVendor != "unknown" {
		t.Fatalf("unexpected unavailable EDR vendor: %+v", snapshot)
	}
	snapshot.DefinitionHash = hex.EncodeToString(hash[:])
	if _, err := snapshot.Canonical(); err != nil {
		t.Fatalf("posture with unavailable values did not validate: %v", err)
	}
}

// A fully unavailable unapproved list must not become unapproved_apps=[].
func TestCollectWindowsFailsOnUnavailableApplicationList(t *testing.T) {
	d, _, runner := loadWindowsFixture(t)
	runner.Rows["unapproved_apps"] = []map[string]any{{"unavailable": true}}
	if snapshot, err := collectWindows(t, d, runner); err == nil {
		t.Fatalf("unavailable application list was collected: apps=%v", snapshot.UnapprovedApps)
	}
}

// cannedWindowsRunner feeds fixed PowerShell JSON outputs through the real
// Windows parsers, so the test covers JSON -> rows -> snapshot.
type cannedWindowsRunner map[string]string

func (r cannedWindowsRunner) Query(_ context.Context, item definition.Item) ([]map[string]any, error) {
	return parseNative(item, []string{r[item.Name]})
}

func cannedWindowsOutputs() cannedWindowsRunner {
	return cannedWindowsRunner{
		"disk_encrypted":             `{"shell_protection":1,"cim_protection_status":null}`,
		"screen_lock":                `{"user_active":null,"user_secure":null,"user_timeout":null,"user_saver":null,"policy_active":null,"policy_secure":null,"policy_timeout":null,"policy_saver":null,"inactivity_timeout_secs":300}`,
		"os_version":                 `{"version":"10.0.22631"}`,
		"patch_current":              `{"pending_count":0}`,
		"auto_update_checks_enabled": `{"policy_read":true,"no_auto_update":null,"au_options":null,"wuauserv_start_mode":"Manual"}`,
		"firewall_enabled":           `{"profile_count":3,"enabled_profiles":["Domain","Private","Public"],"disabled_profiles":[]}`,
		"edr_running":                `{"process_paths":[],"service_paths":[]}`,
		"edr_vendor":                 `{"process_paths":[],"service_paths":[]}`,
		"builtin_protection":         `{"antivirus_enabled":true,"realtime_protection_enabled":true,"antivirus_signature_version":"1.417.123.0","is_tamper_protected":true,"smartscreen_policy":null,"smartscreen_explorer":"Warn"}`,
		"admin_account_count":        `{"members":["disabled:Administrator","operator"]}`,
		"password_manager_installed": `{"display_names":["Google Chrome"],"unreadable_keys":0}`,
		"unapproved_apps":            `{"display_names":["Google Chrome"],"unreadable_keys":0}`,
		"device_identity":            `{"model":"Surface Laptop 5","serial":"0F1234","hostname":"WIN-01"}`,
	}
}

// Reverse test for review finding (3): before the fix one unreadable
// Uninstall key failed the whole collection, so Defender, firewall, and every
// other value never reached the server. Now the other values are kept and the
// application inventory alone is marked unverifiable (not clean).
func TestCollectWindowsKeepsPostureWhenSomeUninstallKeysAreUnreadable(t *testing.T) {
	_, d, hash, err := definition.LoadEmbeddedFor("windows")
	if err != nil {
		t.Fatal(err)
	}
	runner := cannedWindowsOutputs()
	runner["password_manager_installed"] = `{"display_names":["Google Chrome","Slack"],"unreadable_keys":1}`
	runner["unapproved_apps"] = runner["password_manager_installed"]
	previous := nowUTC
	nowUTC = func() string { return "2026-09-13T00:00:00Z" }
	defer func() { nowUTC = previous }()
	snapshot, err := Collect(context.Background(), d, runner, Metadata{
		DeviceID: "00000000-0000-4000-8000-000000000007", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil {
		t.Fatalf("one unreadable Uninstall key failed the whole posture: %v", err)
	}
	if snapshot.FirewallEnabled == nil || !*snapshot.FirewallEnabled || snapshot.EDRRunning == nil || !*snapshot.EDRRunning ||
		snapshot.DiskEncrypted == nil || !*snapshot.DiskEncrypted {
		t.Fatalf("other posture values were not kept: %+v", snapshot)
	}
	if !reflect.DeepEqual(snapshot.ApplicationInventoryMismatches, []string{windowsInventoryUnreadable}) ||
		!reflect.DeepEqual(snapshot.UnapprovedApps, []string{"Slack"}) || snapshot.PasswordManagerInstall != nil {
		t.Fatalf("application inventory was not marked unverifiable: apps=%v mismatches=%v pm=%v",
			snapshot.UnapprovedApps, snapshot.ApplicationInventoryMismatches, snapshot.PasswordManagerInstall)
	}
	snapshot.DefinitionHash = hex.EncodeToString(hash[:])
	canonical, err := snapshot.Canonical()
	if err != nil {
		t.Fatalf("posture with an unverifiable inventory did not validate: %v", err)
	}
	if !strings.Contains(string(canonical), `"application_inventory_mismatches":["unreadable:uninstall_keys"]`) {
		t.Fatalf("canonical posture does not carry the unverifiable marker: %s", canonical)
	}

	// Even with no readable unapproved application, the list is not clean.
	runner["password_manager_installed"] = `{"display_names":[],"unreadable_keys":3}`
	runner["unapproved_apps"] = runner["password_manager_installed"]
	snapshot, err = Collect(context.Background(), d, runner, Metadata{
		DeviceID: "00000000-0000-4000-8000-000000000007", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.UnapprovedApps) != 0 || len(snapshot.ApplicationInventoryMismatches) != 1 {
		t.Fatalf("empty readable inventory passed as clean: apps=%v mismatches=%v", snapshot.UnapprovedApps, snapshot.ApplicationInventoryMismatches)
	}

	// A fully readable inventory has no mismatch entry.
	clean := cannedWindowsOutputs()
	snapshot, err = Collect(context.Background(), d, clean, Metadata{
		DeviceID: "00000000-0000-4000-8000-000000000007", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil || len(snapshot.ApplicationInventoryMismatches) != 0 || snapshot.PasswordManagerInstall == nil || *snapshot.PasswordManagerInstall {
		t.Fatalf("readable inventory was mapped wrongly: %v %+v", err, snapshot)
	}
}

func TestCollectWindowsRejectsForeignOSFamilyAndInventoryMismatch(t *testing.T) {
	d, _, runner := loadWindowsFixture(t)
	runner.Rows["device_identity"] = []map[string]any{{"hostname": "x", "model": "y", "os_family": "macos"}}
	if _, err := collectWindows(t, d, runner); err == nil {
		t.Fatal("Windows definition accepted os_family macos")
	}
	d, _, runner = loadWindowsFixture(t)
	runner.Rows["unapproved_apps"] = []map[string]any{{"inventory_mismatch": "directory_only:x"}}
	if _, err := collectWindows(t, d, runner); err == nil {
		t.Fatal("Windows unapproved_apps accepted an inventory mismatch row")
	}
	d, _, runner = loadWindowsFixture(t)
	runner.Rows["disk_encrypted"] = []map[string]any{{"encrypted": "yes"}}
	if _, err := collectWindows(t, d, runner); err == nil {
		t.Fatal("Windows row with a non-boolean value was accepted")
	}
}

func TestExecutablePathRulePerOS(t *testing.T) {
	previous := executableGOOS
	defer func() { executableGOOS = previous }()
	executableGOOS = "windows"
	for path, want := range map[string]bool{
		`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`: true,
		`c:\tools\x.exe`:       true,
		`powershell.exe`:       false,
		`/bin/ps`:              false,
		`C:powershell`:         false,
		`\\server\share\x.exe`: false,
		``:                     false,
	} {
		if got := isAbsoluteExecutable(path); got != want {
			t.Fatalf("windows %q: got %v, want %v", path, got, want)
		}
	}
	executableGOOS = "darwin"
	for path, want := range map[string]bool{
		`/usr/bin/fdesetup`: true,
		`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`: false,
		`fdesetup`: false,
		``:         false,
	} {
		if got := isAbsoluteExecutable(path); got != want {
			t.Fatalf("darwin %q: got %v, want %v", path, got, want)
		}
	}
}

func TestWindowsDefinitionCommandsAreFixedPowerShellJSON(t *testing.T) {
	_, d, _, err := definition.LoadEmbeddedFor("windows")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range d.Items {
		if item.Collector == "metadata" {
			continue
		}
		if item.Output != "json" || len(item.Commands) != 1 {
			t.Fatalf("%s is not a single JSON command", item.Name)
		}
		command := item.Commands[0]
		if command.Executable != `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` {
			t.Fatalf("%s runs an unexpected executable: %s", item.Name, command.Executable)
		}
		wantPrefix := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"}
		if len(command.Args) != 6 || !reflect.DeepEqual(command.Args[:5], wantPrefix) {
			t.Fatalf("%s has unexpected arguments: %v", item.Name, command.Args)
		}
		script := command.Args[5]
		if strings.Contains(script, `"`) {
			t.Fatalf("%s script contains a double quote", item.Name)
		}
		if !strings.HasSuffix(script, " | ConvertTo-Json -Compress") {
			t.Fatalf("%s script does not end with ConvertTo-Json -Compress", item.Name)
		}
	}
}
