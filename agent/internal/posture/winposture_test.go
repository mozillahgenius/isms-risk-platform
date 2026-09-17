package posture

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

const zeroHash = "0000000000000000000000000000000000000000000000000000000000000000"

// macOSGoldenCanonical was captured from the macOS Snapshot before Windows
// support was added. The macOS canonical (signed) bytes must not change.
const macOSGoldenCanonical = `{"admin_account_count":1,"agent_version":"test","application_inventory_mismatches":[],"auto_update_checks_enabled":true,"builtin_protection":{"csrutil_enabled":true,"spctl_assessments_enabled":true,"system_extensions":[],"xprotect_definition_version":"5355","xprotect_process_count":5,"xprotect_remediator_version":"157"},"collected_at":"2026-08-14T00:00:00Z","definition_hash":"0000000000000000000000000000000000000000000000000000000000000000","definition_version":2,"device_id":"00000000-0000-4000-8000-000000000007","disk_encrypted":true,"edr_running":true,"edr_vendor":"sentinelone","external_id":"serial","firewall_enabled":true,"hostname":"mac","model":"Mac mini","off_premise":false,"os_family":"macos","os_version":"14.6.1","password_manager_installed":true,"patch_current":true,"screen_lock_delay_sec":300,"screen_lock_enabled":true,"unapproved_apps":[]}`

func macOSSnapshot() Snapshot {
	good := true
	delay := 300
	admins := 1
	return Snapshot{
		DeviceID: "00000000-0000-4000-8000-000000000007", CollectedAt: "2026-08-14T00:00:00Z",
		AgentVersion: "test", DefinitionVersion: 2, DefinitionHash: zeroHash,
		ExternalID: "serial", Hostname: "mac", Model: "Mac mini", OSFamily: "macos", OSVersion: "14.6.1",
		OffPremise: false, DiskEncrypted: &good, ScreenLockEnabled: &good, ScreenLockDelaySec: &delay,
		PatchCurrent: &good, AutoUpdateChecksEnabled: &good, FirewallEnabled: &good, EDRRunning: &good,
		EDRVendor: "sentinelone", BuiltinProtection: &BuiltinProtection{
			XProtectProcessCount: 5, XProtectDefinitionVersion: "5355", XProtectRemediatorVersion: "157",
			SpctlAssessmentsEnabled: true, CSRUtilEnabled: true, SystemExtensions: []string{},
		},
		AdminAccountCount: &admins, PasswordManagerInstall: &good, UnapprovedApps: []string{}, ApplicationInventoryMismatches: []string{},
	}
}

func windowsSnapshot() Snapshot {
	snapshot := macOSSnapshot()
	snapshot.Hostname = "WIN-01"
	snapshot.Model = "Surface Laptop 5"
	snapshot.OSFamily = "windows"
	snapshot.OSVersion = "10.0.22631"
	snapshot.BuiltinProtection = &WindowsBuiltinProtection{
		DefenderAntivirusEnabled: true, DefenderRealtimeEnabled: true,
		DefenderSignatureVersion: "1.417.123.0", TamperProtectionEnabled: true,
	}
	return snapshot
}

func TestMacOSCanonicalIsUnchanged(t *testing.T) {
	canonical, err := macOSSnapshot().Canonical()
	if err != nil {
		t.Fatal(err)
	}
	if string(canonical) != macOSGoldenCanonical {
		t.Fatalf("macOS canonical posture changed:\n got %s\nwant %s", canonical, macOSGoldenCanonical)
	}
	parsed, err := ParseSnapshot(canonical)
	if err != nil {
		t.Fatal(err)
	}
	again, err := parsed.Canonical()
	if err != nil || string(again) != macOSGoldenCanonical {
		t.Fatalf("macOS canonical posture did not round-trip: %v %s", err, again)
	}
}

func TestWindowsCanonicalHasExactlyTheWindowsProtectionKeys(t *testing.T) {
	canonical, err := windowsSnapshot().Canonical()
	if err != nil {
		t.Fatal(err)
	}
	want := `"builtin_protection":{"defender_antivirus_enabled":true,"defender_realtime_enabled":true,"defender_signature_version":"1.417.123.0","smartscreen_enabled":null,"tamper_protection_enabled":true}`
	if !bytes.Contains(canonical, []byte(want)) {
		t.Fatalf("unexpected Windows builtin_protection: %s", canonical)
	}
	if bytes.Contains(canonical, []byte("xprotect")) {
		t.Fatalf("Windows posture carries XProtect keys: %s", canonical)
	}
	var macKeys, windowsKeys map[string]any
	macCanonical, _ := macOSSnapshot().Canonical()
	if err := json.Unmarshal(macCanonical, &macKeys); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(canonical, &windowsKeys); err != nil {
		t.Fatal(err)
	}
	if len(macKeys) != len(windowsKeys) {
		t.Fatalf("top-level key sets differ: macOS %d, Windows %d", len(macKeys), len(windowsKeys))
	}
	for key := range macKeys {
		if _, ok := windowsKeys[key]; !ok {
			t.Fatalf("Windows posture is missing top-level key %s", key)
		}
	}
	off := false
	snapshot := windowsSnapshot()
	snapshot.BuiltinProtection.(*WindowsBuiltinProtection).SmartScreenEnabled = &off
	canonical, err = snapshot.Canonical()
	if err != nil || !bytes.Contains(canonical, []byte(`"smartscreen_enabled":false`)) {
		t.Fatalf("smartscreen false was not emitted: %v %s", err, canonical)
	}
}

func TestValidateBranchesOnOSFamily(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Snapshot)
	}{
		{"macOS posture with Windows protection", func(s *Snapshot) {
			s.BuiltinProtection = windowsSnapshot().BuiltinProtection
		}},
		{"Windows posture with macOS protection", func(s *Snapshot) {
			s.OSFamily = "windows"
		}},
		{"Windows posture without signature version", func(s *Snapshot) {
			*s = windowsSnapshot()
			s.BuiltinProtection.(*WindowsBuiltinProtection).DefenderSignatureVersion = " "
		}},
		{"unsupported os_family", func(s *Snapshot) { s.OSFamily = "linux" }},
		{"empty os_family", func(s *Snapshot) { s.OSFamily = "" }},
		{"typed nil macOS protection", func(s *Snapshot) {
			var protection *BuiltinProtection
			s.BuiltinProtection = protection
		}},
		{"typed nil Windows protection", func(s *Snapshot) {
			*s = windowsSnapshot()
			var protection *WindowsBuiltinProtection
			s.BuiltinProtection = protection
		}},
		{"missing protection", func(s *Snapshot) { s.BuiltinProtection = nil }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			snapshot := macOSSnapshot()
			test.mutate(&snapshot)
			if err := snapshot.Validate(); err == nil {
				t.Fatal("invalid posture was accepted")
			}
		})
	}
	if err := windowsSnapshot().Validate(); err != nil {
		t.Fatalf("valid Windows posture was rejected: %v", err)
	}
}

func TestParseSnapshotRejectsMixedOrIncompleteProtection(t *testing.T) {
	windowsCanonical, err := windowsSnapshot().Canonical()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseSnapshot(windowsCanonical); err != nil {
		t.Fatalf("valid Windows posture was rejected: %v", err)
	}
	macCanonical, err := macOSSnapshot().Canonical()
	if err != nil {
		t.Fatal(err)
	}
	windowsProtection := `{"defender_antivirus_enabled":true,"defender_realtime_enabled":true,"defender_signature_version":"1.417.123.0","smartscreen_enabled":null,"tamper_protection_enabled":true}`
	macProtection := `{"csrutil_enabled":true,"spctl_assessments_enabled":true,"system_extensions":[],"xprotect_definition_version":"5355","xprotect_process_count":5,"xprotect_remediator_version":"157"}`
	cases := map[string]string{
		"XProtect key mixed into Windows protection": strings.Replace(string(windowsCanonical), `"builtin_protection":{`, `"builtin_protection":{"xprotect_process_count":5,`, 1),
		"Windows protection missing smartscreen":     strings.Replace(string(windowsCanonical), `,"smartscreen_enabled":null`, ``, 1),
		"Windows posture with macOS protection":      strings.Replace(string(windowsCanonical), windowsProtection, macProtection, 1),
		"macOS posture with Windows protection":      strings.Replace(string(macCanonical), macProtection, windowsProtection, 1),
		"Windows key mixed into macOS protection":    strings.Replace(string(macCanonical), `"builtin_protection":{`, `"builtin_protection":{"tamper_protection_enabled":true,`, 1),
		"Windows protection with string boolean":     strings.Replace(string(windowsCanonical), `"tamper_protection_enabled":true`, `"tamper_protection_enabled":"true"`, 1),
		"extra top-level key":                        strings.Replace(string(windowsCanonical), `{"admin_account_count"`, `{"defender_extra":1,"admin_account_count"`, 1),
		"missing top-level key":                      strings.Replace(string(windowsCanonical), `"admin_account_count":1,`, ``, 1),
		"null protection":                            strings.Replace(string(windowsCanonical), windowsProtection, `null`, 1),
		"trailing data":                              string(windowsCanonical) + `{}`,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if raw == string(windowsCanonical) || raw == string(macCanonical) {
				t.Fatal("test mutation did not apply")
			}
			if _, err := ParseSnapshot([]byte(raw)); err == nil {
				t.Fatal("invalid posture JSON was accepted")
			}
		})
	}
}
