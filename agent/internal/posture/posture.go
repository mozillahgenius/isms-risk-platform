package posture

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"sort"
	"strings"
	"time"

	"isms-platform/agent/internal/canonicaljson"
)

// Snapshot is the privacy-bounded posture contract. It deliberately contains
// no file contents, paths, browsing data, keystrokes, clipboard, screenshots,
// location, or process/app usage telemetry.
type Snapshot struct {
	DeviceID                       string                    `json:"device_id"`
	CollectedAt                    string                    `json:"collected_at"`
	AgentVersion                   string                    `json:"agent_version"`
	DefinitionVersion              int                       `json:"definition_version"`
	DefinitionHash                 string                    `json:"definition_hash"`
	ExternalID                     string                    `json:"external_id"`
	Hostname                       string                    `json:"hostname"`
	Model                          string                    `json:"model"`
	OSFamily                       string                    `json:"os_family"`
	OffPremise                     bool                      `json:"off_premise"`
	DiskEncrypted                  *bool                     `json:"disk_encrypted"`
	ScreenLockEnabled              *bool                     `json:"screen_lock_enabled"`
	ScreenLockDelaySec             *int                      `json:"screen_lock_delay_sec"`
	OSVersion                      string                    `json:"os_version"`
	PatchCurrent                   *bool                     `json:"patch_current"`
	AutoUpdateChecksEnabled        *bool                     `json:"auto_update_checks_enabled"`
	FirewallEnabled                *bool                     `json:"firewall_enabled"`
	EDRRunning                     *bool                     `json:"edr_running"`
	EDRVendor                      string                    `json:"edr_vendor"`
	BuiltinProtection              BuiltinProtectionEvidence `json:"builtin_protection"`
	AdminAccountCount              *int                      `json:"admin_account_count"`
	PasswordManagerInstall         *bool                     `json:"password_manager_installed"`
	UnapprovedApps                 []string                  `json:"unapproved_apps"`
	ApplicationInventoryMismatches []string                  `json:"application_inventory_mismatches"`
}

// BuiltinProtectionEvidence is the OS-specific builtin_protection object. The
// top-level posture keys are shared across OSes; only this object's shape
// differs. The interface is sealed: only *BuiltinProtection (macOS) and
// *WindowsBuiltinProtection implement it.
type BuiltinProtectionEvidence interface {
	builtinProtectionOSFamily() string
}

// BuiltinProtection is the macOS builtin_protection shape (XProtect,
// Gatekeeper, SIP, system extensions).
type BuiltinProtection struct {
	XProtectProcessCount      int      `json:"xprotect_process_count"`
	XProtectDefinitionVersion string   `json:"xprotect_definition_version"`
	XProtectRemediatorVersion string   `json:"xprotect_remediator_version"`
	SpctlAssessmentsEnabled   bool     `json:"spctl_assessments_enabled"`
	CSRUtilEnabled            bool     `json:"csrutil_enabled"`
	SystemExtensions          []string `json:"system_extensions"`
}

func (*BuiltinProtection) builtinProtectionOSFamily() string { return "macos" }

// WindowsBuiltinProtection is the Windows builtin_protection shape (Microsoft
// Defender Antivirus and SmartScreen). SmartScreenEnabled is null when the
// setting could not be determined.
type WindowsBuiltinProtection struct {
	DefenderAntivirusEnabled bool   `json:"defender_antivirus_enabled"`
	DefenderRealtimeEnabled  bool   `json:"defender_realtime_enabled"`
	DefenderSignatureVersion string `json:"defender_signature_version"`
	TamperProtectionEnabled  bool   `json:"tamper_protection_enabled"`
	SmartScreenEnabled       *bool  `json:"smartscreen_enabled"`
}

func (*WindowsBuiltinProtection) builtinProtectionOSFamily() string { return "windows" }

// builtinProtectionKeys is the exact key set allowed in builtin_protection per
// os_family. Extra or missing keys are rejected.
var builtinProtectionKeys = map[string][]string{
	"macos": {
		"csrutil_enabled", "spctl_assessments_enabled", "system_extensions",
		"xprotect_definition_version", "xprotect_process_count", "xprotect_remediator_version",
	},
	"windows": {
		"defender_antivirus_enabled", "defender_realtime_enabled", "defender_signature_version",
		"smartscreen_enabled", "tamper_protection_enabled",
	},
}

func (s Snapshot) Validate() error {
	if strings.TrimSpace(s.DeviceID) == "" {
		return fmt.Errorf("device_id is required")
	}
	if _, err := time.Parse(time.RFC3339, s.CollectedAt); err != nil {
		return fmt.Errorf("collected_at must be RFC3339: %w", err)
	}
	if strings.TrimSpace(s.AgentVersion) == "" {
		return fmt.Errorf("agent_version is required")
	}
	if strings.TrimSpace(s.EDRVendor) == "" {
		return fmt.Errorf("edr_vendor is required")
	}
	if err := s.validateBuiltinProtection(); err != nil {
		return err
	}
	if s.DefinitionVersion != 2 {
		return fmt.Errorf("unsupported definition_version: %d", s.DefinitionVersion)
	}
	definitionHash, err := hex.DecodeString(s.DefinitionHash)
	if err != nil || len(definitionHash) != 32 {
		return fmt.Errorf("definition_hash must be 64 hexadecimal characters")
	}
	if strings.TrimSpace(s.OSVersion) == "" {
		return fmt.Errorf("os_version is required")
	}
	if s.ScreenLockDelaySec != nil && *s.ScreenLockDelaySec < 0 {
		return fmt.Errorf("screen_lock_delay_sec cannot be negative")
	}
	if s.AdminAccountCount != nil && *s.AdminAccountCount < 0 {
		return fmt.Errorf("admin_account_count cannot be negative")
	}
	if s.UnapprovedApps == nil {
		return fmt.Errorf("unapproved_apps must be present")
	}
	if s.DefinitionVersion == 2 && s.ApplicationInventoryMismatches == nil {
		return fmt.Errorf("application_inventory_mismatches must be present for v2")
	}
	seen := make(map[string]struct{}, len(s.UnapprovedApps))
	for _, app := range s.UnapprovedApps {
		if strings.TrimSpace(app) == "" || strings.ContainsAny(app, `/\\`) || len(app) > 255 {
			return fmt.Errorf("unapproved_apps must contain application names only")
		}
		if _, ok := seen[app]; ok {
			return fmt.Errorf("unapproved_apps contains duplicate: %q", app)
		}
		seen[app] = struct{}{}
	}
	seenMismatches := make(map[string]struct{}, len(s.ApplicationInventoryMismatches))
	for _, mismatch := range s.ApplicationInventoryMismatches {
		if strings.TrimSpace(mismatch) == "" || strings.ContainsAny(mismatch, `/\\`) || len(mismatch) > 255 {
			return fmt.Errorf("application_inventory_mismatches must contain names only")
		}
		if _, ok := seenMismatches[mismatch]; ok {
			return fmt.Errorf("application_inventory_mismatches contains duplicate: %q", mismatch)
		}
		seenMismatches[mismatch] = struct{}{}
	}
	return nil
}

// validateBuiltinProtection branches on os_family and checks the exact shape
// of builtin_protection for that OS.
func (s Snapshot) validateBuiltinProtection() error {
	if s.BuiltinProtection == nil {
		return fmt.Errorf("builtin_protection is required")
	}
	switch s.OSFamily {
	case "macos":
		protection, ok := s.BuiltinProtection.(*BuiltinProtection)
		if !ok {
			return fmt.Errorf("builtin_protection for macos must use the macOS shape")
		}
		if protection == nil {
			return fmt.Errorf("builtin_protection is required")
		}
		if protection.XProtectProcessCount < 0 {
			return fmt.Errorf("xprotect_process_count cannot be negative")
		}
		if strings.TrimSpace(protection.XProtectDefinitionVersion) == "" || strings.TrimSpace(protection.XProtectRemediatorVersion) == "" {
			return fmt.Errorf("XProtect versions are required")
		}
		if protection.SystemExtensions == nil {
			return fmt.Errorf("system_extensions must be present")
		}
	case "windows":
		protection, ok := s.BuiltinProtection.(*WindowsBuiltinProtection)
		if !ok {
			return fmt.Errorf("builtin_protection for windows must use the Windows shape")
		}
		if protection == nil {
			return fmt.Errorf("builtin_protection is required")
		}
		if strings.TrimSpace(protection.DefenderSignatureVersion) == "" {
			return fmt.Errorf("defender_signature_version is required")
		}
	default:
		return fmt.Errorf("os_family must be macos or windows: %q", s.OSFamily)
	}
	// Check the emitted key set too, so the signed canonical object can only
	// carry the fixed keys for this OS.
	raw, err := json.Marshal(s.BuiltinProtection)
	if err != nil {
		return fmt.Errorf("marshal builtin_protection: %w", err)
	}
	return checkBuiltinProtectionKeys(s.OSFamily, raw)
}

func checkBuiltinProtectionKeys(osFamily string, raw []byte) error {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil || object == nil {
		return fmt.Errorf("builtin_protection must be an object")
	}
	want := builtinProtectionKeys[osFamily]
	if len(object) != len(want) {
		return fmt.Errorf("builtin_protection fields do not match the fixed %s contract", osFamily)
	}
	for _, key := range want {
		if _, ok := object[key]; !ok {
			return fmt.Errorf("builtin_protection fields do not match the fixed %s contract", osFamily)
		}
	}
	return nil
}

func (s Snapshot) Canonical() ([]byte, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return nil, fmt.Errorf("marshal posture: %w", err)
	}
	return canonicaljson.Canonicalize(raw)
}

// ParseSnapshot strictly decodes a posture JSON object: the top-level keys
// must be exactly the Snapshot keys, and builtin_protection must be exactly
// the shape for the payload's os_family. The result is then validated.
func ParseSnapshot(raw []byte) (Snapshot, error) {
	var object map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(raw))
	if err := dec.Decode(&object); err != nil || object == nil {
		return Snapshot{}, fmt.Errorf("posture must be a JSON object")
	}
	if _, err := dec.Token(); err != io.EOF {
		return Snapshot{}, errors.New("posture JSON contains trailing data")
	}
	fields := snapshotKeys()
	if len(object) != len(fields) {
		return Snapshot{}, errors.New("posture fields do not match the fixed contract")
	}
	for _, key := range fields {
		if _, ok := object[key]; !ok {
			return Snapshot{}, errors.New("posture fields do not match the fixed contract")
		}
	}
	protectionRaw := object["builtin_protection"]
	delete(object, "builtin_protection")
	rest, err := json.Marshal(object)
	if err != nil {
		return Snapshot{}, err
	}
	var snapshot Snapshot
	restDecoder := json.NewDecoder(bytes.NewReader(rest))
	restDecoder.DisallowUnknownFields()
	if err := restDecoder.Decode(&snapshot); err != nil {
		return Snapshot{}, fmt.Errorf("decode posture: %w", err)
	}
	if bytes.Equal(bytes.TrimSpace(protectionRaw), []byte("null")) {
		return Snapshot{}, errors.New("builtin_protection is required")
	}
	if _, ok := builtinProtectionKeys[snapshot.OSFamily]; !ok {
		return Snapshot{}, fmt.Errorf("os_family must be macos or windows: %q", snapshot.OSFamily)
	}
	if err := checkBuiltinProtectionKeys(snapshot.OSFamily, protectionRaw); err != nil {
		return Snapshot{}, err
	}
	var protection BuiltinProtectionEvidence
	if snapshot.OSFamily == "windows" {
		protection = &WindowsBuiltinProtection{}
	} else {
		protection = &BuiltinProtection{}
	}
	protectionDecoder := json.NewDecoder(bytes.NewReader(protectionRaw))
	protectionDecoder.DisallowUnknownFields()
	if err := protectionDecoder.Decode(protection); err != nil {
		return Snapshot{}, fmt.Errorf("decode builtin_protection: %w", err)
	}
	snapshot.BuiltinProtection = protection
	if err := snapshot.Validate(); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

func snapshotKeys() []string {
	t := reflect.TypeOf(Snapshot{})
	keys := make([]string, 0, t.NumField())
	for i := 0; i < t.NumField(); i++ {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		keys = append(keys, name)
	}
	return keys
}

func (s *Snapshot) SortApps() {
	if s.UnapprovedApps != nil {
		sort.Strings(s.UnapprovedApps)
	}
	if s.ApplicationInventoryMismatches != nil {
		sort.Strings(s.ApplicationInventoryMismatches)
	}
}
