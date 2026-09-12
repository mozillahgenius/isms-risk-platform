package collector

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"isms-platform/agent/internal/definition"
)

func TestCollectUsesOnlyDefinitionItemsAndMapsFixture(t *testing.T) {
	_, d, _, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	previous := nowUTC
	nowUTC = func() string { return "2026-08-14T00:00:00Z" }
	defer func() { nowUTC = previous }()
	runner := FixtureRunner{Rows: map[string][]map[string]any{
		"disk_encrypted":             {{"encrypted": true}},
		"screen_lock":                {{"enabled": true, "delay_seconds": 300}},
		"os_version":                 {{"major": 14, "minor": 6, "patch": 1}},
		"patch_current":              {{"current": true}},
		"auto_update_checks_enabled": {{"enabled": true}},
		"firewall_enabled":           {{"enabled": true}},
		"edr_running":                {{"name": "sentinelone"}},
		"edr_vendor":                 {{"vendor": "sentinelone"}},
		"builtin_protection": []map[string]any{{
			"xprotect_process_count": 5, "xprotect_definition_version": "5355", "xprotect_remediator_version": "157",
			"spctl_assessments_enabled": true, "csrutil_enabled": true, "system_extensions": []string{},
		}},
		"admin_account_count":        {{"username": "operator"}},
		"password_manager_installed": {{"name": "1Password"}},
		"unapproved_apps":            {},
		"device_identity":            {{"hostname": "fixture", "model": "Mac mini", "os_family": "macos"}},
		"off_premise":                {{"source": "enrollment"}},
	}}
	snapshot, err := Collect(context.Background(), d, runner, Metadata{
		DeviceID: "d0000000-0000-4000-8000-000000000001", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.OSVersion != "14.6.1" || snapshot.Hostname != "fixture" || snapshot.AdminAccountCount == nil || *snapshot.AdminAccountCount != 1 {
		t.Fatalf("unexpected fixture mapping: %+v", snapshot)
	}
}

func TestCollectTreatsCompleteBuiltinProtectionAsEDRRunning(t *testing.T) {
	_, d, _, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	runner, err := LoadFixture(filepath.Join("..", "..", "testdata", "fixture-good.json"))
	if err != nil {
		t.Fatal(err)
	}
	runner.Rows["edr_running"] = []map[string]any{}
	runner.Rows["edr_vendor"] = []map[string]any{{"vendor": "none"}}
	snapshot, err := Collect(context.Background(), d, runner, Metadata{
		DeviceID: "d0000000-0000-4000-8000-000000000001", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.EDRRunning == nil || !*snapshot.EDRRunning || snapshot.EDRVendor != "none" {
		t.Fatalf("builtin protection was not promoted to aggregate EDR evidence: %+v", snapshot)
	}
}

func TestCollectPromotionIsOrderIndependent(t *testing.T) {
	_, d, _, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	runner, err := LoadFixture(filepath.Join("..", "..", "testdata", "fixture-good.json"))
	if err != nil {
		t.Fatal(err)
	}
	runner.Rows["edr_running"] = []map[string]any{}
	runner.Rows["edr_vendor"] = []map[string]any{{"vendor": "none"}}

	var builtin definition.Item
	for _, item := range d.Items {
		if item.Name == "builtin_protection" {
			builtin = item
			break
		}
	}
	ordered := make([]definition.Item, 0, len(d.Items))
	for _, item := range d.Items {
		if item.Name == "builtin_protection" {
			continue
		}
		if item.Name == "edr_running" {
			ordered = append(ordered, builtin)
		}
		ordered = append(ordered, item)
	}
	d.Items = ordered

	snapshot, err := Collect(context.Background(), d, runner, Metadata{
		DeviceID: "d0000000-0000-4000-8000-000000000001", ExternalID: "serial", AgentVer: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.EDRRunning == nil || !*snapshot.EDRRunning {
		t.Fatalf("builtin promotion depended on definition item order: %+v", snapshot)
	}
}

func TestCollectFailsClosedForStoppedOrIncompleteBuiltinProtection(t *testing.T) {
	cases := []struct {
		name string
		row  map[string]any
	}{
		{name: "stopped", row: map[string]any{
			"xprotect_process_count": 0, "xprotect_definition_version": "5355", "xprotect_remediator_version": "157",
			"spctl_assessments_enabled": true, "csrutil_enabled": true, "system_extensions": []string{},
		}},
		{name: "missing definition version", row: map[string]any{
			"xprotect_process_count": 5, "xprotect_definition_version": "", "xprotect_remediator_version": "157",
			"spctl_assessments_enabled": true, "csrutil_enabled": true, "system_extensions": []string{},
		}},
		{name: "missing remediator version", row: map[string]any{
			"xprotect_process_count": 5, "xprotect_definition_version": "5355", "xprotect_remediator_version": "",
			"spctl_assessments_enabled": true, "csrutil_enabled": true, "system_extensions": []string{},
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			_, d, _, err := definition.LoadEmbedded()
			if err != nil {
				t.Fatal(err)
			}
			runner, err := LoadFixture(filepath.Join("..", "..", "testdata", "fixture-good.json"))
			if err != nil {
				t.Fatal(err)
			}
			runner.Rows["edr_running"] = []map[string]any{}
			runner.Rows["edr_vendor"] = []map[string]any{{"vendor": "none"}}
			runner.Rows["builtin_protection"] = []map[string]any{test.row}
			snapshot, err := Collect(context.Background(), d, runner, Metadata{
				DeviceID: "d0000000-0000-4000-8000-000000000001", ExternalID: "serial", AgentVer: "test",
			})
			if err != nil {
				t.Fatal(err)
			}
			if snapshot.EDRRunning == nil || *snapshot.EDRRunning {
				t.Fatalf("incomplete builtin protection was promoted: %+v", snapshot)
			}
		})
	}
}

func TestNativeParsersMapMeasuredOutputs(t *testing.T) {
	tests := []struct {
		name string
		item definition.Item
		text string
		want map[string]any
	}{
		{name: "filevault", item: definition.Item{Name: "disk_encrypted"}, text: "FileVault is On.", want: map[string]any{"encrypted": true}},
		{name: "screen lock immediate", item: definition.Item{Name: "screen_lock"}, text: "2026-08-16 21:12:16.784 sysadminctl[37814:83599939] screenLock delay is immediate", want: map[string]any{"enabled": true, "delay_seconds": 0}},
		{name: "screen lock seconds", item: definition.Item{Name: "screen_lock"}, text: "sysadminctl[1] screenLock delay is 30 seconds", want: map[string]any{"enabled": true, "delay_seconds": 30}},
		{name: "screen lock minutes", item: definition.Item{Name: "screen_lock"}, text: "sysadminctl[1] screenLock delay is 5 minutes", want: map[string]any{"enabled": true, "delay_seconds": 300}},
		{name: "screen lock off", item: definition.Item{Name: "screen_lock"}, text: "sysadminctl[1] screenLock is off", want: map[string]any{"enabled": false, "delay_seconds": 0}},
		{name: "version", item: definition.Item{Name: "os_version"}, text: "26.5.1", want: map[string]any{"major": "26", "minor": "5", "patch": "1"}},
		{name: "patch", item: definition.Item{Name: "patch_current"}, text: "No new software available.", want: map[string]any{"current": true}},
		{name: "update checks", item: definition.Item{Name: "auto_update_checks_enabled"}, text: "Automatic checking for updates is turned on", want: map[string]any{"enabled": true}},
		{name: "firewall", item: definition.Item{Name: "firewall_enabled"}, text: "Firewall is disabled. (State = 0)", want: map[string]any{"enabled": false}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			rows, err := parseNative(test.item, []string{test.text})
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 1 {
				t.Fatalf("got %d rows", len(rows))
			}
			for key, want := range test.want {
				if rows[0][key] != want {
					t.Fatalf("%s: got %v, want %v", key, rows[0][key], want)
				}
			}
		})
	}
}

func TestNativeRunnerReadsStderrForScreenLockAndRejectsStdoutOnlyRegression(t *testing.T) {
	scriptPath := filepath.Join(t.TempDir(), "screen-lock")
	script := "#!/bin/sh\nprintf '%s\\n' '2026-08-16 21:12:16.784 sysadminctl[37814:83599939] screenLock delay is immediate' >&2\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	item := definition.Item{
		Name: "screen_lock", Collector: "native", Output: "combined",
		Commands: []definition.Command{{Executable: scriptPath}},
	}
	rows, err := (NativeRunner{}).Query(context.Background(), item)
	if err != nil {
		t.Fatalf("stderr-only screen lock output was not collected: %v", err)
	}
	if rows[0]["enabled"] != true || rows[0]["delay_seconds"] != 0 {
		t.Fatalf("unexpected stderr-only screen lock row: %+v", rows[0])
	}

	item.Output = "stdout"
	if _, err := (NativeRunner{}).Query(context.Background(), item); err == nil {
		t.Fatal("stdout-only regression was accepted for stderr-only screen lock output")
	}
}

func TestAdminAccountDefinitionExclusions(t *testing.T) {
	item := definition.Item{
		Name: "admin_account_count",
		AdminExclude: definition.AdminExclusions{
			Names: []string{"root"}, Prefixes: []string{"_"},
		},
	}
	rows, err := parseNative(item, []string{"GroupMembership: root alice remoteaccess _mbsetupuser"})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0]["username"] != "alice" || rows[1]["username"] != "remoteaccess" {
		t.Fatalf("definition exclusions were not applied: %+v", rows)
	}
}

func TestApplicationScopeExcludesSystemAndUserApplications(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	item := definition.Item{
		Name:                     "unapproved_apps",
		LocationPrefixes:         []string{"/Applications"},
		ExcludedLocationPrefixes: []string{"/System/Applications", "~/Applications"},
		LocationDepth:            1,
	}
	text := "Applications:\n" +
		"    Approved:\n      Location: /Applications/Approved.app\n" +
		"    System:\n      Location: /System/Applications/Calculator.app\n" +
		"    Nested:\n      Location: /Applications/Utilities/Tool.app\n" +
		"    User:\n      Location: " + filepath.Join(home, "Applications", "Private.app") + "\n"
	rows := parseUnapprovedApps(text, []string{"Approved"}, item)
	if len(rows) != 0 {
		t.Fatalf("out-of-scope applications were included: %+v", rows)
	}

	text += "    Unapproved:\n      Location: /Applications/Slack.app\n"
	rows = parseUnapprovedApps(text, []string{"Approved"}, item)
	if len(rows) != 1 || rows[0]["name"] != "Unapproved" {
		t.Fatalf("direct /Applications application was not included: %+v", rows)
	}

	text += "    Hidden:\n      Location: /Applications/.hidden.app\n"
	rows = parseUnapprovedApps(text, []string{"Approved"}, item)
	if len(rows) != 1 {
		t.Fatalf("hidden application was included while definition excluded it: %+v", rows)
	}
	item.IncludeHiddenBundles = true
	rows = parseUnapprovedApps(text, []string{"Approved"}, item)
	if len(rows) != 2 {
		t.Fatalf("hidden application was not included after definition enabled it: %+v", rows)
	}
}

func TestApplicationInventoryMismatchIsRecordedAndDirectoryIsIncluded(t *testing.T) {
	item := definition.Item{
		Name: "unapproved_apps", ApplicationInventory: "system_profiler_and_directory",
		LocationPrefixes: []string{"/Applications"}, LocationDepth: 1,
		IncludeHiddenBundles: true, ApprovedNames: []string{"Safari"},
	}
	profiler := "Applications:\n    Safari:\n      Location: /Applications/Safari.app\n"
	directory := "/Applications/Safari.app\n/Applications/xsbug.app\n"
	rows, err := parseNative(item, []string{profiler, directory})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0]["name"] != "xsbug" || rows[1]["inventory_mismatch"] != "directory_only:xsbug" {
		t.Fatalf("directory gap was not included and recorded: %+v", rows)
	}
}

func TestNativeApplicationScopeRejectsWideningOnMeasuredMac(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("system_profiler scope measurement requires macOS")
	}
	base := definition.Item{
		Name: "unapproved_apps", Collector: "native", Output: "stdout",
		Commands:         []definition.Command{{Executable: "/usr/sbin/system_profiler", Args: []string{"SPApplicationsDataType", "-detailLevel", "mini"}}},
		LocationPrefixes: []string{"/Applications"}, LocationDepth: 1,
	}
	narrow, err := (NativeRunner{}).Query(context.Background(), base)
	if err != nil {
		t.Fatal(err)
	}
	wide := base
	wide.LocationPrefixes = []string{"/Applications", "/System/Applications"}
	wide.LocationDepth = 0
	wideRows, err := (NativeRunner{}).Query(context.Background(), wide)
	if err != nil {
		t.Fatal(err)
	}
	if len(narrow) == 0 || len(wideRows) <= len(narrow) {
		t.Fatalf("widening application scope did not increase violations: narrow=%d wide=%d", len(narrow), len(wideRows))
	}
	t.Logf("measured application-scope rows: /Applications direct=%d, widened system scope=%d", len(narrow), len(wideRows))
}

func TestNativeApplicationInventoryDetectsMeasuredMacGap(t *testing.T) {
	item := definition.Item{
		Name: "unapproved_apps", ApplicationInventory: "system_profiler_and_directory",
		LocationPrefixes: []string{"/Applications"}, LocationDepth: 1,
		IncludeHiddenBundles: true, ApprovedNames: []string{"Safari"},
	}
	profiler := "Applications:\n    Safari:\n      Location: /Applications/Safari.app\n"
	directory := "/Applications/Safari.app\n/Applications/xsbug.app\n"
	rows, err := parseNative(item, []string{profiler, directory})
	if err != nil || len(rows) != 2 || rows[1]["inventory_mismatch"] != "directory_only:xsbug" {
		t.Fatalf("application inventory gap was not recorded specifically: %v rows=%+v", err, rows)
	}
}

func TestBuiltinProtectionParserRecordsXProtectEvidence(t *testing.T) {
	rows, err := parseBuiltinProtection([]string{
		"32684\n32686\n",
		"5355\n",
		"157\n",
		"assessments enabled\n",
		"System Integrity Protection status: enabled.\n",
		"2 extension(s)\n*\t*\tTEAM\tcom.example.vpn.network-extension (1.0.0)\tExample VPN Network Extension\t[activated enabled]\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	if rows[0]["xprotect_process_count"] != 2 || rows[0]["xprotect_definition_version"] != "5355" || rows[0]["xprotect_remediator_version"] != "157" {
		t.Fatalf("XProtect versions/processes were not recorded: %+v", rows)
	}
	if rows[0]["spctl_assessments_enabled"] != true || rows[0]["csrutil_enabled"] != true {
		t.Fatalf("security status was not recorded: %+v", rows)
	}
	if len(rows[0]["system_extensions"].([]string)) != 1 {
		t.Fatalf("system extensions were not recorded: %+v", rows)
	}
}

func TestBuiltinProtectionParserKeepsStoppedStateAsNegativeEvidence(t *testing.T) {
	rows, err := parseBuiltinProtection([]string{
		"",
		"5355\n",
		"157\n",
		"assessments enabled\n",
		"System Integrity Protection status: enabled.\n",
		"No System Extensions found\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	if rows[0]["xprotect_process_count"] != 0 {
		t.Fatalf("stopped XProtect was not represented as zero: %+v", rows)
	}
}

func TestBuiltinProtectionDefinitionMatchesLowercaseXProtectDaemon(t *testing.T) {
	_, definition, _, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range definition.Items {
		if item.Name != "builtin_protection" {
			continue
		}
		if len(item.Commands) == 0 || len(item.Commands[0].Args) != 2 {
			t.Fatalf("XProtect process command is incomplete: %+v", item.Commands)
		}
		if item.Commands[0].Args[0] != "-fi" || item.Commands[0].Args[1] != "xprotect" {
			t.Fatalf("XProtect process command is not case-insensitive: %+v", item.Commands[0])
		}
		return
	}
	t.Fatal("builtin_protection definition item was not found")
}

func TestEDRVendorUsesExecutableNameNotCommandLine(t *testing.T) {
	prefixes := map[string][]string{
		"sentinelone": {"/Library/SentinelOne/"},
		"crowdstrike": {"/Library/CS/"},
	}
	previous := lookupProcessPath
	lookupProcessPath = func(pid int) (string, error) {
		paths := map[int]string{123: "/Library/CS/falcond", 124: "/tmp/crowdstrike", 125: "/Library/SentinelOne/sentinel-agent"}
		path, ok := paths[pid]
		if !ok {
			return "", os.ErrNotExist
		}
		return path, nil
	}
	defer func() { lookupProcessPath = previous }()
	rows, err := collectEDRProcessRows("123\n124\n125\n", prefixes, true)
	if err != nil || len(rows) != 2 || rows[0]["vendor"] != "crowdstrike" || rows[1]["vendor"] != "sentinelone" {
		t.Fatalf("unexpected EDR vendor parsing: %v %+v", err, rows)
	}
	rows, err = collectEDRProcessRows("124\n", prefixes, false)
	if err != nil || len(rows) != 0 {
		t.Fatalf("process-title spoof was accepted as executable evidence: %v %+v", err, rows)
	}
	_, definition, _, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range definition.Items {
		if item.Name == "edr_vendor" {
			if len(item.Commands) != 1 || item.Commands[0].Executable != "/bin/ps" || len(item.Commands[0].Args) != 2 || item.Commands[0].Args[0] != "-axo" || item.Commands[0].Args[1] != "pid=" || item.ProcessPathLookup != "kernel_proc_pidpath" {
				t.Fatalf("EDR vendor command is not executable-name based: %+v", item.Commands)
			}
			return
		}
	}
	t.Fatal("edr_vendor definition item was not found")
}

func TestBuiltinProtectionParserRejectsMissingVersion(t *testing.T) {
	_, err := parseBuiltinProtection([]string{"1\n", "", "157\n", "assessments enabled", "status: enabled", ""})
	if err == nil {
		t.Fatal("missing XProtect version was accepted")
	}
}
