package posture

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"isms-platform/agent/internal/canonicaljson"
)

// Snapshot is the privacy-bounded posture contract. It deliberately contains
// no file contents, paths, browsing data, keystrokes, clipboard, screenshots,
// location, or process/app usage telemetry.
type Snapshot struct {
	DeviceID                       string             `json:"device_id"`
	CollectedAt                    string             `json:"collected_at"`
	AgentVersion                   string             `json:"agent_version"`
	DefinitionVersion              int                `json:"definition_version"`
	DefinitionHash                 string             `json:"definition_hash"`
	ExternalID                     string             `json:"external_id"`
	Hostname                       string             `json:"hostname"`
	Model                          string             `json:"model"`
	OSFamily                       string             `json:"os_family"`
	OffPremise                     bool               `json:"off_premise"`
	DiskEncrypted                  *bool              `json:"disk_encrypted"`
	ScreenLockEnabled              *bool              `json:"screen_lock_enabled"`
	ScreenLockDelaySec             *int               `json:"screen_lock_delay_sec"`
	OSVersion                      string             `json:"os_version"`
	PatchCurrent                   *bool              `json:"patch_current"`
	AutoUpdateChecksEnabled        *bool              `json:"auto_update_checks_enabled"`
	FirewallEnabled                *bool              `json:"firewall_enabled"`
	EDRRunning                     *bool              `json:"edr_running"`
	EDRVendor                      string             `json:"edr_vendor"`
	BuiltinProtection              *BuiltinProtection `json:"builtin_protection"`
	AdminAccountCount              *int               `json:"admin_account_count"`
	PasswordManagerInstall         *bool              `json:"password_manager_installed"`
	UnapprovedApps                 []string           `json:"unapproved_apps"`
	ApplicationInventoryMismatches []string           `json:"application_inventory_mismatches"`
}

type BuiltinProtection struct {
	XProtectProcessCount      int      `json:"xprotect_process_count"`
	XProtectDefinitionVersion string   `json:"xprotect_definition_version"`
	XProtectRemediatorVersion string   `json:"xprotect_remediator_version"`
	SpctlAssessmentsEnabled   bool     `json:"spctl_assessments_enabled"`
	CSRUtilEnabled            bool     `json:"csrutil_enabled"`
	SystemExtensions          []string `json:"system_extensions"`
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
	if s.BuiltinProtection == nil {
		return fmt.Errorf("builtin_protection is required")
	}
	if s.BuiltinProtection.XProtectProcessCount < 0 {
		return fmt.Errorf("xprotect_process_count cannot be negative")
	}
	if strings.TrimSpace(s.BuiltinProtection.XProtectDefinitionVersion) == "" || strings.TrimSpace(s.BuiltinProtection.XProtectRemediatorVersion) == "" {
		return fmt.Errorf("XProtect versions are required")
	}
	if s.BuiltinProtection.SystemExtensions == nil {
		return fmt.Errorf("system_extensions must be present")
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

func (s *Snapshot) SortApps() {
	if s.UnapprovedApps != nil {
		sort.Strings(s.UnapprovedApps)
	}
	if s.ApplicationInventoryMismatches != nil {
		sort.Strings(s.ApplicationInventoryMismatches)
	}
}
