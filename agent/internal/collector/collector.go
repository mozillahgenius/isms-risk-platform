package collector

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/posture"
)

// QueryRunner receives only a reviewed definition item. There is no public
// API that accepts arbitrary query or command text.
type QueryRunner interface {
	Query(context.Context, definition.Item) ([]map[string]any, error)
}

type Metadata struct {
	DeviceID   string
	ExternalID string
	OffPremise bool
	AgentVer   string
}

// NativeRunner executes only the absolute executable/argv pairs from a v2
// definition. It never invokes a shell and never accepts a caller-provided
// command line.
type NativeRunner struct{}

const nativeCommandTimeout = 30 * time.Second

func (NativeRunner) Query(ctx context.Context, item definition.Item) ([]map[string]any, error) {
	if item.Collector != "native" || len(item.Commands) == 0 {
		return nil, fmt.Errorf("item %s is not a native collector", item.Name)
	}
	outputs := make([]string, len(item.Commands))
	for i, command := range item.Commands {
		if command.Executable == "" || !strings.HasPrefix(command.Executable, "/") {
			return nil, fmt.Errorf("item %s has an invalid native executable", item.Name)
		}
		commandCtx, cancel := context.WithTimeout(ctx, nativeCommandTimeout)
		raw, err := runNativeCommand(commandCtx, command, item.Output)
		cancel()
		if err != nil {
			if (item.Name == "edr_running" || item.Name == "edr_vendor") && exitStatus(err) == 1 {
				outputs[i] = string(raw)
				continue
			}
			if item.Name == "builtin_protection" && i == 0 && exitStatus(err) == 1 {
				outputs[i] = string(raw)
				continue
			}
			return nil, fmt.Errorf("native item %s: %w", item.Name, err)
		}
		outputs[i] = string(raw)
	}
	if item.Name == "edr_running" || item.Name == "edr_vendor" {
		return collectEDRProcessRows(outputs[0], item.ExecutablePathPrefixes, item.Name == "edr_vendor")
	}
	return parseNative(item, outputs)
}

func runNativeCommand(ctx context.Context, command definition.Command, output string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, command.Executable, command.Args...)
	switch output {
	case "stdout":
		return cmd.Output()
	case "stderr":
		var stderr bytes.Buffer
		cmd.Stdout = io.Discard
		cmd.Stderr = &stderr
		err := cmd.Run()
		return stderr.Bytes(), err
	case "combined":
		return cmd.CombinedOutput()
	default:
		return nil, fmt.Errorf("unsupported native output stream %q", output)
	}
}

func exitStatus(err error) int {
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return -1
	}
	return exitErr.ExitCode()
}

func parseNative(item definition.Item, outputs []string) ([]map[string]any, error) {
	text := strings.Join(outputs, "\n")
	switch item.Name {
	case "disk_encrypted":
		value, err := parseFileVault(text)
		if err != nil {
			return nil, err
		}
		return []map[string]any{{"encrypted": value}}, nil
	case "screen_lock":
		return parseScreenLock(text)
	case "os_version":
		return parseOSVersion(text)
	case "patch_current":
		value, err := parsePatchCurrent(text)
		if err != nil {
			return nil, err
		}
		return []map[string]any{{"current": value}}, nil
	case "auto_update_checks_enabled":
		value, err := parseAutoUpdate(text)
		if err != nil {
			return nil, err
		}
		return []map[string]any{{"enabled": value}}, nil
	case "firewall_enabled":
		value, err := parseFirewall(text)
		if err != nil {
			return nil, err
		}
		return []map[string]any{{"enabled": value}}, nil
	case "edr_running":
		return parseEDRProcesses(text, item.ExecutablePathPrefixes), nil
	case "edr_vendor":
		return parseEDRVendor(text, item.ExecutablePathPrefixes), nil
	case "builtin_protection":
		return parseBuiltinProtection(outputs)
	case "admin_account_count":
		return parseAdminAccounts(text, item.AdminExclude)
	case "password_manager_installed":
		return parsePasswordManagers(text, item.ApprovedNames), nil
	case "unapproved_apps":
		if item.ApplicationInventory == "system_profiler_and_directory" {
			return parseCrossCheckedUnapprovedApps(outputs, item.ApprovedNames, item)
		}
		return parseUnapprovedApps(text, item.ApprovedNames, item), nil
	case "device_identity":
		return parseDeviceIdentity(outputs)
	default:
		return nil, fmt.Errorf("native item %s has no parser", item.Name)
	}
}

func parseFileVault(text string) (bool, error) {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "filevault is on"):
		return true, nil
	case strings.Contains(lower, "filevault is off"):
		return false, nil
	default:
		return false, errors.New("fdesetup status was not recognized")
	}
}

func parseScreenLock(text string) ([]map[string]any, error) {
	lower := strings.ToLower(strings.TrimSpace(text))
	if strings.Contains(lower, "screenlock is off") {
		return []map[string]any{{"enabled": false, "delay_seconds": 0}}, nil
	}
	marker := "screenlock delay is"
	index := strings.Index(lower, marker)
	if index < 0 {
		return nil, errors.New("sysadminctl screen lock status was not recognized")
	}
	rest := strings.TrimSpace(lower[index+len(marker):])
	if strings.HasPrefix(rest, "immediate") {
		return []map[string]any{{"enabled": true, "delay_seconds": 0}}, nil
	}
	fields := strings.Fields(rest)
	if len(fields) < 2 {
		return nil, errors.New("screen lock delay was not recognized")
	}
	delay, err := strconv.Atoi(fields[0])
	if err != nil || delay < 0 {
		return nil, errors.New("screen lock delay is invalid")
	}
	if fields[1] == "minute" || fields[1] == "minutes" {
		delay *= 60
	} else if fields[1] != "second" && fields[1] != "seconds" {
		return nil, errors.New("screen lock delay unit is invalid")
	}
	return []map[string]any{{"enabled": true, "delay_seconds": delay}}, nil
}

func parseOSVersion(text string) ([]map[string]any, error) {
	version := strings.TrimSpace(text)
	parts := strings.Split(version, ".")
	if len(parts) < 2 || len(parts) > 3 {
		return nil, fmt.Errorf("os version is invalid: %q", version)
	}
	for _, part := range parts {
		if _, err := strconv.Atoi(part); err != nil {
			return nil, fmt.Errorf("os version is invalid: %q", version)
		}
	}
	row := map[string]any{"major": parts[0], "minor": parts[1]}
	if len(parts) == 3 {
		row["patch"] = parts[2]
	}
	return []map[string]any{row}, nil
}

func parsePatchCurrent(text string) (bool, error) {
	lower := strings.ToLower(text)
	if strings.Contains(lower, "no new software available") {
		return true, nil
	}
	if strings.Contains(lower, "software update found") || strings.Contains(lower, "* label:") {
		return false, nil
	}
	return false, errors.New("softwareupdate list was not recognized")
}

func parseAutoUpdate(text string) (bool, error) {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "turned on"):
		return true, nil
	case strings.Contains(lower, "turned off"):
		return false, nil
	default:
		return false, errors.New("softwareupdate schedule was not recognized")
	}
}

func parseFirewall(text string) (bool, error) {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "state = 1"), strings.Contains(lower, "firewall is enabled"):
		return true, nil
	case strings.Contains(lower, "state = 0"), strings.Contains(lower, "firewall is disabled"):
		return false, nil
	default:
		return false, errors.New("socketfilterfw state was not recognized")
	}
}

func parseAdminAccounts(text string, exclusions definition.AdminExclusions) ([]map[string]any, error) {
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "GroupMembership:") {
			continue
		}
		members := strings.Fields(strings.TrimSpace(strings.TrimPrefix(trimmed, "GroupMembership:")))
		rows := make([]map[string]any, 0, len(members))
		for _, member := range members {
			if excludedAdmin(member, exclusions) {
				continue
			}
			rows = append(rows, map[string]any{"username": member})
		}
		return rows, nil
	}
	return nil, errors.New("admin group membership was not recognized")
}

func excludedAdmin(username string, exclusions definition.AdminExclusions) bool {
	for _, name := range exclusions.Names {
		if username == name {
			return true
		}
	}
	for _, prefix := range exclusions.Prefixes {
		if strings.HasPrefix(username, prefix) {
			return true
		}
	}
	return false
}

func parseEDRProcesses(text string, prefixes map[string][]string) []map[string]any {
	rows := make([]map[string]any, 0)
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || !matchesEDRExecutablePath(fields[1], prefixes) {
			continue
		}
		rows = append(rows, map[string]any{"name": fields[1]})
	}
	return rows
}

var errProcessPathUnsupported = errors.New("kernel process path lookup is unsupported")

var lookupProcessPath = processPath

func collectEDRProcessRows(text string, prefixes map[string][]string, vendorOnly bool) ([]map[string]any, error) {
	seen := make(map[string]struct{})
	rows := make([]map[string]any, 0)
	for _, line := range strings.Split(text, "\n") {
		pid, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			continue
		}
		path, err := lookupProcessPath(pid)
		if err != nil {
			if errors.Is(err, errProcessPathUnsupported) {
				return nil, err
			}
			continue
		}
		vendor := edrVendorForPath(path, prefixes)
		if vendor == "" {
			continue
		}
		if vendorOnly {
			seen[vendor] = struct{}{}
		} else {
			rows = append(rows, map[string]any{"name": path})
		}
	}
	if !vendorOnly {
		return rows, nil
	}
	vendors := make([]string, 0, len(seen))
	for vendor := range seen {
		vendors = append(vendors, vendor)
	}
	sort.Strings(vendors)
	if len(vendors) == 0 {
		return []map[string]any{{"vendor": "none"}}, nil
	}
	for _, vendor := range vendors {
		rows = append(rows, map[string]any{"vendor": vendor})
	}
	return rows, nil
}

func parseEDRVendor(text string, prefixes map[string][]string) []map[string]any {
	seen := make(map[string]struct{})
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		vendor := edrVendorForPath(fields[1], prefixes)
		if vendor != "" {
			seen[vendor] = struct{}{}
		}
	}
	vendors := make([]string, 0, len(seen))
	for vendor := range seen {
		vendors = append(vendors, vendor)
	}
	sort.Strings(vendors)
	if len(vendors) == 0 {
		return []map[string]any{{"vendor": "none"}}
	}
	rows := make([]map[string]any, 0, len(vendors))
	for _, vendor := range vendors {
		rows = append(rows, map[string]any{"vendor": vendor})
	}
	return rows
}

func matchesEDRExecutablePath(path string, prefixes map[string][]string) bool {
	return edrVendorForPath(path, prefixes) != ""
}

func edrVendorForPath(path string, prefixes map[string][]string) string {
	for _, vendor := range []string{"sentinelone", "crowdstrike"} {
		for _, prefix := range prefixes[vendor] {
			if strings.HasPrefix(path, prefix) {
				return vendor
			}
		}
	}
	return ""
}

func parseBuiltinProtection(outputs []string) ([]map[string]any, error) {
	if len(outputs) != 6 {
		return nil, errors.New("builtin protection command output is incomplete")
	}
	processCount := 0
	for _, line := range strings.Split(strings.TrimSpace(outputs[0]), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if _, err := strconv.Atoi(line); err != nil {
			return nil, fmt.Errorf("XProtect process output is invalid: %q", line)
		}
		processCount++
	}
	bundleVersion := strings.TrimSpace(outputs[1])
	if bundleVersion == "" {
		return nil, errors.New("XProtect definition version is missing")
	}
	remediatorVersion := strings.TrimSpace(outputs[2])
	if remediatorVersion == "" {
		return nil, errors.New("XProtect Remediator version is missing")
	}
	spctlEnabled, err := parseAssessmentStatus(outputs[3])
	if err != nil {
		return nil, err
	}
	csrutilEnabled, err := parseCSRStatus(outputs[4])
	if err != nil {
		return nil, err
	}
	return []map[string]any{{
		"xprotect_process_count":      processCount,
		"xprotect_definition_version": bundleVersion,
		"xprotect_remediator_version": remediatorVersion,
		"spctl_assessments_enabled":   spctlEnabled,
		"csrutil_enabled":             csrutilEnabled,
		"system_extensions":           parseSystemExtensions(outputs[5]),
	}}, nil
}

func parseAssessmentStatus(text string) (bool, error) {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "assessments enabled"):
		return true, nil
	case strings.Contains(lower, "assessments disabled"):
		return false, nil
	default:
		return false, errors.New("spctl assessment status was not recognized")
	}
}

func parseCSRStatus(text string) (bool, error) {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "status: enabled"):
		return true, nil
	case strings.Contains(lower, "status: disabled"):
		return false, nil
	default:
		return false, errors.New("csrutil status was not recognized")
	}
}

func parseSystemExtensions(text string) []string {
	rows := make([]string, 0)
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "---") || strings.Contains(trimmed, "bundleID") || strings.HasPrefix(trimmed, "No System Extensions") || strings.Contains(trimmed, "extension(s)") {
			continue
		}
		if strings.Contains(trimmed, "[") && strings.Contains(trimmed, "]") {
			rows = append(rows, trimmed)
		}
	}
	sort.Strings(rows)
	return rows
}

func parsePasswordManagers(text string, approved []string) []map[string]any {
	installed := make(map[string]struct{})
	for _, application := range applicationRecords(text) {
		installed[application.Name] = struct{}{}
	}
	rows := make([]map[string]any, 0)
	for _, name := range approved {
		if _, ok := installed[name]; ok {
			rows = append(rows, map[string]any{"name": name})
		}
	}
	return rows
}

func parseUnapprovedApps(text string, approved []string, item definition.Item) []map[string]any {
	return parseUnapprovedApplicationRecords(applicationRecords(text), approved, item)
}

func parseUnapprovedApplicationRecords(applications []applicationRecord, approved []string, item definition.Item) []map[string]any {
	allow := make(map[string]struct{}, len(approved))
	for _, name := range approved {
		allow[name] = struct{}{}
	}
	seen := make(map[string]struct{})
	rows := make([]map[string]any, 0)
	for _, application := range applications {
		if !applicationInScope(application.Location, item) {
			continue
		}
		name := application.Name
		if _, ok := allow[name]; ok {
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		rows = append(rows, map[string]any{"name": name})
	}
	return rows
}

func parseCrossCheckedUnapprovedApps(outputs []string, approved []string, item definition.Item) ([]map[string]any, error) {
	if len(outputs) != 2 {
		return nil, errors.New("application inventory requires system_profiler and directory outputs")
	}
	profiler := applicationRecords(outputs[0])
	profilerPaths := make(map[string]applicationRecord)
	for _, application := range profiler {
		if applicationInScope(application.Location, item) {
			profilerPaths[filepath.Clean(application.Location)] = application
		}
	}
	directoryPaths := make(map[string]struct{})
	for _, line := range strings.Split(outputs[1], "\n") {
		path := filepath.Clean(strings.TrimSpace(line))
		if path != "." && applicationInScope(path, item) {
			directoryPaths[path] = struct{}{}
		}
	}

	allPaths := make(map[string]applicationRecord, len(profilerPaths)+len(directoryPaths))
	for path, application := range profilerPaths {
		allPaths[path] = application
	}
	mismatches := make([]string, 0)
	for path := range directoryPaths {
		if _, ok := allPaths[path]; ok {
			continue
		}
		name := strings.TrimSuffix(filepath.Base(path), ".app")
		allPaths[path] = applicationRecord{Name: name, Location: path}
		mismatches = append(mismatches, "directory_only:"+name)
	}
	for path, application := range profilerPaths {
		if _, ok := directoryPaths[path]; !ok {
			mismatches = append(mismatches, "profiler_only:"+application.Name)
		}
	}
	paths := make([]string, 0, len(allPaths))
	for path := range allPaths {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	applications := make([]applicationRecord, 0, len(paths))
	for _, path := range paths {
		applications = append(applications, allPaths[path])
	}
	rows := parseUnapprovedApplicationRecords(applications, approved, item)
	sort.Strings(mismatches)
	for _, mismatch := range mismatches {
		rows = append(rows, map[string]any{"inventory_mismatch": mismatch})
	}
	return rows, nil
}

type applicationRecord struct {
	Name     string
	Location string
}

func applicationRecords(text string) []applicationRecord {
	records := make([]applicationRecord, 0)
	var current *applicationRecord
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "    ") && !strings.HasPrefix(line, "      ") {
			trimmed := strings.TrimSpace(line)
			if strings.HasSuffix(trimmed, ":") && trimmed != "Applications:" {
				name := strings.TrimSuffix(trimmed, ":")
				current = &applicationRecord{Name: name}
			}
		}
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Name:") {
			if current == nil {
				current = &applicationRecord{}
			}
			current.Name = strings.TrimSpace(strings.TrimPrefix(trimmed, "Name:"))
		}
		if strings.HasPrefix(trimmed, "Location:") && current != nil {
			current.Location = strings.TrimSpace(strings.TrimPrefix(trimmed, "Location:"))
			if current.Name != "" {
				records = append(records, *current)
			}
			current = nil
		}
	}
	return records
}

func applicationInScope(location string, item definition.Item) bool {
	location = filepath.Clean(strings.TrimSpace(location))
	if location == "." || len(item.LocationPrefixes) == 0 {
		return false
	}
	if !item.IncludeHiddenBundles && isHiddenApplication(location) {
		return false
	}
	for _, prefix := range item.ExcludedLocationPrefixes {
		if locationPrefixMatches(location, expandLocationPrefix(prefix)) {
			return false
		}
	}
	for _, prefix := range item.LocationPrefixes {
		base := expandLocationPrefix(prefix)
		if !locationPrefixMatches(location, base) {
			continue
		}
		if item.LocationDepth == 0 || relativeDepth(location, base) == item.LocationDepth {
			return true
		}
	}
	return false
}

func isHiddenApplication(location string) bool {
	base := filepath.Base(location)
	return strings.HasPrefix(base, ".") && strings.HasSuffix(base, ".app")
}

func expandLocationPrefix(prefix string) string {
	if strings.HasPrefix(prefix, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(prefix, "~/"))
		}
	}
	return prefix
}

func locationPrefixMatches(location, prefix string) bool {
	base := filepath.Clean(prefix)
	return location == base || strings.HasPrefix(location, base+string(os.PathSeparator))
}

func relativeDepth(location, base string) int {
	relative, err := filepath.Rel(filepath.Clean(base), filepath.Clean(location))
	if err != nil || relative == "." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) || relative == ".." {
		return -1
	}
	return strings.Count(relative, string(os.PathSeparator)) + 1
}

func parseDeviceIdentity(outputs []string) ([]map[string]any, error) {
	if len(outputs) != 2 {
		return nil, errors.New("device identity command output is incomplete")
	}
	row := map[string]any{"os_family": "macos"}
	for _, line := range strings.Split(outputs[0], "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trimmed, "Model Name:"):
			row["model"] = strings.TrimSpace(strings.TrimPrefix(trimmed, "Model Name:"))
		case strings.HasPrefix(trimmed, "Serial Number (system):"):
			row["serial"] = strings.TrimSpace(strings.TrimPrefix(trimmed, "Serial Number (system):"))
		}
	}
	row["hostname"] = strings.TrimSpace(outputs[1])
	model, _ := row["model"].(string)
	serial, _ := row["serial"].(string)
	hostname, _ := row["hostname"].(string)
	if model == "" || serial == "" || hostname == "" {
		return nil, errors.New("device identity output is incomplete")
	}
	return []map[string]any{row}, nil
}

type FixtureRunner struct {
	Rows map[string][]map[string]any
}

func LoadFixture(path string) (FixtureRunner, error) {
	raw, err := osReadFile(path)
	if err != nil {
		return FixtureRunner{}, fmt.Errorf("read fixture: %w", err)
	}
	var rows map[string][]map[string]any
	if err := json.Unmarshal(raw, &rows); err != nil {
		return FixtureRunner{}, fmt.Errorf("decode fixture: %w", err)
	}
	return FixtureRunner{Rows: rows}, nil
}

func (r FixtureRunner) Query(_ context.Context, item definition.Item) ([]map[string]any, error) {
	rows, ok := r.Rows[item.Name]
	if !ok {
		return nil, fmt.Errorf("fixture has no rows for allowlisted item %s", item.Name)
	}
	return rows, nil
}

// osReadFile is a variable so tests can replace filesystem access without
// weakening the production runner's fixed-query boundary.
var osReadFile = readFile

func readFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func Collect(ctx context.Context, d definition.Definition, runner QueryRunner, metadata Metadata) (posture.Snapshot, error) {
	snapshot := posture.Snapshot{
		DeviceID:          metadata.DeviceID,
		ExternalID:        metadata.ExternalID,
		OffPremise:        metadata.OffPremise,
		AgentVersion:      metadata.AgentVer,
		CollectedAt:       nowUTC(),
		DefinitionVersion: d.Version,
	}
	for _, item := range d.Items {
		var rows []map[string]any
		if item.Collector != "metadata" {
			var err error
			rows, err = runner.Query(ctx, item)
			if err != nil {
				return posture.Snapshot{}, err
			}
		}
		switch item.Name {
		case "disk_encrypted":
			snapshot.DiskEncrypted = boolPointer(firstBool(rows, "encrypted"))
		case "screen_lock":
			if len(rows) > 0 {
				snapshot.ScreenLockEnabled = boolPointer(rowBool(rows[0], "enabled"))
				snapshot.ScreenLockDelaySec = intPointer(rowInt(rows[0], "delay_seconds"))
			}
		case "os_version":
			if len(rows) > 0 {
				row := rows[0]
				version := []string{rowString(row, "major"), rowString(row, "minor"), rowString(row, "patch")}
				for i := range version {
					if version[i] == "" {
						version[i] = "0"
					}
				}
				snapshot.OSVersion = strings.Join(version, ".")
			}
		case "patch_current":
			snapshot.PatchCurrent = boolPointer(firstBool(rows, "current"))
		case "auto_update_checks_enabled":
			snapshot.AutoUpdateChecksEnabled = boolPointer(firstBool(rows, "enabled"))
		case "firewall_enabled":
			snapshot.FirewallEnabled = boolPointer(firstBool(rows, "enabled"))
		case "edr_running":
			if len(rows) > 0 {
				snapshot.EDRRunning = boolPointer(true)
			} else if snapshot.EDRRunning == nil {
				// A later empty explicit EDR result must not erase a positive
				// promotion from builtin_protection.
				snapshot.EDRRunning = boolPointer(false)
			}
		case "edr_vendor":
			vendors := make([]string, 0, len(rows))
			for _, row := range rows {
				vendor := strings.TrimSpace(rowString(row, "vendor"))
				if vendor != "" {
					vendors = append(vendors, vendor)
				}
			}
			if len(vendors) == 0 {
				snapshot.EDRVendor = "none"
			} else {
				sort.Strings(vendors)
				snapshot.EDRVendor = strings.Join(vendors, ",")
			}
		case "builtin_protection":
			if len(rows) > 0 {
				row := rows[0]
				protection := &posture.BuiltinProtection{
					XProtectProcessCount:      rowInt(row, "xprotect_process_count"),
					XProtectDefinitionVersion: rowString(row, "xprotect_definition_version"),
					XProtectRemediatorVersion: rowString(row, "xprotect_remediator_version"),
					SpctlAssessmentsEnabled:   rowBool(row, "spctl_assessments_enabled"),
					CSRUtilEnabled:            rowBool(row, "csrutil_enabled"),
					SystemExtensions:          rowStrings(row, "system_extensions"),
				}
				snapshot.BuiltinProtection = protection
				if definitionPromotesTo(item, "edr_running") && builtinProtectionActive(protection) {
					snapshot.EDRRunning = boolPointer(true)
				}
			}
		case "admin_account_count":
			count := len(rows)
			snapshot.AdminAccountCount = &count
		case "password_manager_installed":
			snapshot.PasswordManagerInstall = boolPointer(len(rows) > 0)
		case "unapproved_apps":
			for _, row := range rows {
				if mismatch := strings.TrimSpace(rowString(row, "inventory_mismatch")); mismatch != "" {
					snapshot.ApplicationInventoryMismatches = append(snapshot.ApplicationInventoryMismatches, mismatch)
					continue
				}
				name := strings.TrimSpace(rowString(row, "name"))
				if name != "" {
					snapshot.UnapprovedApps = append(snapshot.UnapprovedApps, name)
				}
			}
			sort.Strings(snapshot.UnapprovedApps)
		case "device_identity":
			if len(rows) > 0 {
				row := rows[0]
				snapshot.Hostname = rowString(row, "hostname")
				snapshot.Model = rowString(row, "model")
				snapshot.OSFamily = rowString(row, "os_family")
			}
		case "off_premise":
			// The value is an explicit enrollment attribute, not a location signal.
		}
	}
	if snapshot.UnapprovedApps == nil {
		snapshot.UnapprovedApps = []string{}
	}
	if snapshot.ApplicationInventoryMismatches == nil {
		snapshot.ApplicationInventoryMismatches = []string{}
	}
	sort.Strings(snapshot.ApplicationInventoryMismatches)
	return snapshot, nil
}

func builtinProtectionActive(protection *posture.BuiltinProtection) bool {
	return protection != nil && protection.XProtectProcessCount > 0 &&
		strings.TrimSpace(protection.XProtectDefinitionVersion) != "" &&
		strings.TrimSpace(protection.XProtectRemediatorVersion) != "" &&
		protection.SpctlAssessmentsEnabled && protection.CSRUtilEnabled &&
		protection.SystemExtensions != nil
}

func definitionPromotesTo(item definition.Item, target string) bool {
	for _, candidate := range item.PromotesTo {
		if candidate == target {
			return true
		}
	}
	return false
}

func firstBool(rows []map[string]any, key string) bool {
	if len(rows) == 0 {
		return false
	}
	return rowBool(rows[0], key)
}

func rowBool(row map[string]any, key string) bool {
	switch value := row[key].(type) {
	case bool:
		return value
	case string:
		parsed, _ := strconv.ParseBool(value)
		if value == "1" {
			return true
		}
		return parsed
	case float64:
		return value != 0
	default:
		return false
	}
}

func rowInt(row map[string]any, key string) int {
	switch value := row[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	case string:
		parsed, _ := strconv.Atoi(value)
		return parsed
	default:
		return 0
	}
}

func rowString(row map[string]any, key string) string {
	value, ok := row[key]
	if !ok || value == nil {
		return ""
	}
	return fmt.Sprint(value)
}

func rowStrings(row map[string]any, key string) []string {
	value, ok := row[key]
	if !ok || value == nil {
		return nil
	}
	switch values := value.(type) {
	case []string:
		return append([]string(nil), values...)
	case []any:
		rows := make([]string, 0, len(values))
		for _, item := range values {
			rows = append(rows, fmt.Sprint(item))
		}
		return rows
	default:
		return nil
	}
}

func boolPointer(value bool) *bool { return &value }
func intPointer(value int) *int    { return &value }

var nowUTC = func() string { return time.Now().UTC().Format(time.RFC3339) }
