package collector

// Windows parsers. Every Windows definition item runs one fixed powershell.exe
// command whose stdout is a single JSON object (Output "json"). The parsers
// never split table-formatted console output.
//
// Missing values: when a source cannot be read the item is represented as
// null (or empty) instead of a guess, and collection continues. The
// exceptions are spelled out per parser (patch_current and the required
// builtin_protection booleans fall back to false; an application inventory
// that cannot be walked at all fails collection, as on macOS, while a walk
// with some unreadable keys is reported as unverifiable, never as clean).
//
// This file has no build tag on purpose so the parsers are unit-tested on any
// host. (A "_windows.go" suffix would restrict it to GOOS=windows builds.)

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/posture"
)

// windowsUnavailableRow marks an item whose source could not be read. Collect
// maps it to null (or an empty list) for Windows snapshots.
func windowsUnavailableRow() []map[string]any {
	return []map[string]any{{"unavailable": true}}
}

func rowsUnavailable(rows []map[string]any) bool {
	return len(rows) == 1 && rows[0]["unavailable"] == true
}

// windowsSignatureUnavailable is written when Get-MpComputerStatus returns no
// signature version. The posture contract requires a non-empty string, so an
// explicit marker is used instead of an invented version; it never counts as
// active protection.
const windowsSignatureUnavailable = "unavailable"

// windowsInventoryUnreadable is the fixed application_inventory_mismatches
// entry written when some Uninstall keys exist but could not be read. It uses
// the same "<kind>:<name>" form as the macOS cross-check entries and passes
// the posture contract (names only, no path separators). The server's
// application check treats any non-empty application_inventory_mismatches as
// a violation, so the device is never reported as clean.
const windowsInventoryUnreadable = "unreadable:uninstall_keys"

func parseWindowsNative(item definition.Item, outputs []string) ([]map[string]any, error) {
	if len(outputs) != 1 {
		return nil, fmt.Errorf("windows item %s expects exactly one JSON output", item.Name)
	}
	doc, err := decodeWindowsJSON(outputs[0])
	if err != nil {
		return nil, fmt.Errorf("windows item %s: %w", item.Name, err)
	}
	switch item.Name {
	case "disk_encrypted":
		return parseWindowsBitLocker(doc), nil
	case "screen_lock":
		return parseWindowsScreenLock(doc), nil
	case "os_version":
		return parseWindowsOSVersion(doc)
	case "patch_current":
		return parseWindowsPatchCurrent(doc), nil
	case "auto_update_checks_enabled":
		return parseWindowsAutoUpdate(doc), nil
	case "firewall_enabled":
		return parseWindowsFirewall(doc), nil
	case "edr_running":
		return parseWindowsEDR(doc, item.ExecutablePathPrefixes, false), nil
	case "edr_vendor":
		return parseWindowsEDR(doc, item.ExecutablePathPrefixes, true), nil
	case "builtin_protection":
		return parseWindowsBuiltinProtection(doc), nil
	case "admin_account_count":
		return parseWindowsAdmins(doc, item.AdminExclude), nil
	case "password_manager_installed":
		return parseWindowsPasswordManagers(doc, item.ApprovedNames)
	case "unapproved_apps":
		return parseWindowsUnapprovedApps(doc, item.ApprovedNames)
	case "device_identity":
		return parseWindowsDeviceIdentity(doc)
	default:
		return nil, fmt.Errorf("windows item %s has no parser", item.Name)
	}
}

// decodeWindowsJSON accepts exactly one JSON object. A UTF-8 byte order mark
// and surrounding whitespace are tolerated because powershell.exe may emit
// them depending on the console encoding.
func decodeWindowsJSON(text string) (map[string]any, error) {
	trimmed := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(text), "\ufeff"))
	if trimmed == "" {
		return nil, errors.New("powershell output is empty")
	}
	dec := json.NewDecoder(bytes.NewReader([]byte(trimmed)))
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("powershell output is not a JSON object: %w", err)
	}
	if doc == nil {
		return nil, errors.New("powershell output is not a JSON object")
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("powershell output contains trailing data")
	}
	return doc, nil
}

// jsonBool returns a boolean value or false,false when the value is null,
// missing, or not a JSON boolean.
func jsonBool(doc map[string]any, key string) (bool, bool) {
	value, ok := doc[key].(bool)
	return value, ok
}

// jsonInt accepts a JSON number or a decimal string (REG_SZ values such as
// ScreenSaveTimeOut are strings; REG_DWORD values are numbers).
func jsonInt(doc map[string]any, key string) (int, bool) {
	switch value := doc[key].(type) {
	case float64:
		if value != float64(int(value)) {
			return 0, false
		}
		return int(value), true
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return 0, false
		}
		return parsed, true
	default:
		return 0, false
	}
}

// jsonOptionalInt distinguishes an absent value (missing or null: present is
// false) from a present value that is not an integer (valid is false), for
// example a REG_SZ "invalid" or a REG_BINARY array where a DWORD is expected.
func jsonOptionalInt(doc map[string]any, key string) (value int, present bool, valid bool) {
	if raw, ok := doc[key]; !ok || raw == nil {
		return 0, false, false
	}
	value, valid = jsonInt(doc, key)
	return value, true, valid
}

func jsonString(doc map[string]any, key string) (string, bool) {
	value, ok := doc[key].(string)
	if !ok {
		return "", false
	}
	return strings.TrimSpace(value), true
}

// jsonStrings reads a string list. Windows PowerShell 5.1 ConvertTo-Json may
// emit a one-element list as a bare string, or wrap an array as
// {"value":[...],"Count":n}; all three shapes are accepted. ok is false when
// the value is null or missing (the source could not be read).
func jsonStrings(doc map[string]any, key string) ([]string, bool) {
	return jsonStringList(doc[key])
}

func jsonStringList(value any) ([]string, bool) {
	switch typed := value.(type) {
	case []any:
		rows := make([]string, 0, len(typed))
		for _, element := range typed {
			if text, ok := element.(string); ok && strings.TrimSpace(text) != "" {
				rows = append(rows, strings.TrimSpace(text))
			}
		}
		return rows, true
	case string:
		if strings.TrimSpace(typed) == "" {
			return []string{}, true
		}
		return []string{strings.TrimSpace(typed)}, true
	case map[string]any:
		if inner, ok := typed["value"]; ok {
			return jsonStringList(inner)
		}
		return nil, false
	default:
		return nil, false
	}
}

// parseWindowsBitLocker maps the system drive's BitLocker state.
//
// Source priority: the Shell property System.Volume.BitLockerProtection needs
// no administrator rights, so it is used first. Win32_EncryptableVolume
// (ProtectionStatus) needs elevation and is only a fallback. When neither is
// readable the value is null (not guessed).
//
// Shell values as commonly documented (not verified on a real device here):
// 1 = on, 6 = on (locked) -> true; 0 = not encryptable, 2 = off,
// 3 = encrypting, 4 = decrypting, 5 = suspended, 8 = waiting for activation
// -> false (the disk is not protected at rest right now); others -> null.
// ProtectionStatus: 1 = protected -> true, 0 = unprotected -> false,
// 2 = unknown -> null.
func parseWindowsBitLocker(doc map[string]any) []map[string]any {
	if shell, ok := jsonInt(doc, "shell_protection"); ok {
		switch shell {
		case 1, 6:
			return []map[string]any{{"encrypted": true}}
		case 0, 2, 3, 4, 5, 8:
			return []map[string]any{{"encrypted": false}}
		}
	}
	if status, ok := jsonInt(doc, "cim_protection_status"); ok {
		switch status {
		case 1:
			return []map[string]any{{"encrypted": true}}
		case 0:
			return []map[string]any{{"encrypted": false}}
		}
	}
	return []map[string]any{{"encrypted": nil}}
}

// parseWindowsScreenLock combines the screen saver lock (policy values take
// precedence over the user's Control Panel values, name by name) and the
// machine inactivity limit (InactivityTimeoutSecs). The lock is enabled when
// either one requires a password after a positive timeout; the delay is the
// shortest one. Absent registry values mean "not configured", so an
// unconfigured device reports enabled=false, delay 0 (like macOS "screenLock
// is off"). Locking through power/sleep settings is not covered.
func parseWindowsScreenLock(doc map[string]any) []map[string]any {
	effective := func(name string) any {
		if value, ok := doc["policy_"+name]; ok && value != nil {
			return value
		}
		return doc["user_"+name]
	}
	values := map[string]any{
		"active":  effective("active"),
		"secure":  effective("secure"),
		"timeout": effective("timeout"),
		"saver":   effective("saver"),
	}
	delays := make([]int, 0, 2)
	active, activeOK := jsonInt(values, "active")
	secure, secureOK := jsonInt(values, "secure")
	timeout, timeoutOK := jsonInt(values, "timeout")
	saver, _ := jsonString(values, "saver")
	if activeOK && active == 1 && secureOK && secure == 1 && timeoutOK && timeout > 0 && saver != "" {
		delays = append(delays, timeout)
	}
	if inactivity, ok := jsonInt(doc, "inactivity_timeout_secs"); ok && inactivity > 0 {
		delays = append(delays, inactivity)
	}
	if len(delays) == 0 {
		return []map[string]any{{"enabled": false, "delay_seconds": 0}}
	}
	sort.Ints(delays)
	return []map[string]any{{"enabled": true, "delay_seconds": delays[0]}}
}

// parseWindowsOSVersion reads major.minor.build (for example 10.0.22631).
// os_version is required by the posture contract, so an unreadable version is
// an error, as it is on macOS.
func parseWindowsOSVersion(doc map[string]any) ([]map[string]any, error) {
	version, ok := jsonString(doc, "version")
	if !ok || version == "" {
		return nil, errors.New("windows os version is missing")
	}
	return parseOSVersion(version)
}

// parseWindowsPatchCurrent reports whether Windows Update knows of no pending
// software updates (IsInstalled=0, not hidden, not optional). The search runs
// offline against the last scan so it fits the command timeout.
//
// When the count is unreadable the value is false, not null: Snapshot keeps
// patch_current as the same boolean it is on macOS, and an unverified patch
// state is treated as not current (fail closed).
func parseWindowsPatchCurrent(doc map[string]any) []map[string]any {
	count, ok := jsonInt(doc, "pending_count")
	return []map[string]any{{"current": ok && count == 0}}
}

// parseWindowsAutoUpdate reports whether automatic updates are not disabled:
// policy NoAutoUpdate=1 or AUOptions=1 (never check) or a Disabled wuauserv
// service means false. Absent policy values mean "not configured", which is
// Windows' default of automatic updates.
//
// An absent policy and an unreadable policy are different: the script sets
// policy_read=false only when reading the AU policy key failed (ACL, provider
// failure, Constrained Language Mode). A read failure never yields true,
// because NoAutoUpdate=1 may be hiding behind it. It yields null ("not
// verified"), the same as every other Windows item whose source is unreadable
// (disk_encrypted, firewall_enabled, and the unreadable service start mode
// here); the posture field is a nullable boolean and null is never counted as
// enabled. false is not used because it would claim a disabled state that was
// not observed (patch_current is the one item the contract fixes to false).
// A Disabled service is observed evidence and still yields false.
//
// A policy value that exists but cannot be interpreted as an integer (a
// REG_SZ "invalid", a REG_BINARY, a fraction) is neither "not configured" nor
// a known setting, so it is handled like a read failure: never true, null.
// Windows might act on such a value in a way this parser cannot tell.
func parseWindowsAutoUpdate(doc map[string]any) []map[string]any {
	policyRead, _ := jsonBool(doc, "policy_read")
	policyKnown := policyRead
	if policyRead {
		for _, key := range []string{"no_auto_update", "au_options"} {
			value, present, valid := jsonOptionalInt(doc, key)
			if !present {
				continue
			}
			if !valid {
				policyKnown = false
				continue
			}
			if value == 1 {
				return []map[string]any{{"enabled": false}}
			}
		}
	}
	mode, ok := jsonString(doc, "wuauserv_start_mode")
	if ok && strings.EqualFold(mode, "Disabled") {
		return []map[string]any{{"enabled": false}}
	}
	if !policyKnown || !ok || mode == "" {
		return []map[string]any{{"enabled": nil}}
	}
	return []map[string]any{{"enabled": true}}
}

// parseWindowsFirewall is true only when every profile returned by
// Get-NetFirewallProfile (ActiveStore first) is Enabled. Unreadable -> null.
func parseWindowsFirewall(doc map[string]any) []map[string]any {
	count, ok := jsonInt(doc, "profile_count")
	if !ok {
		return []map[string]any{{"enabled": nil}}
	}
	enabled, enabledOK := jsonStrings(doc, "enabled_profiles")
	disabled, disabledOK := jsonStrings(doc, "disabled_profiles")
	if !enabledOK || !disabledOK {
		return []map[string]any{{"enabled": nil}}
	}
	return []map[string]any{{"enabled": count > 0 && len(disabled) == 0 && len(enabled) == count}}
}

// parseWindowsEDR matches executable paths against the definition's vendor
// directories (case-insensitive, as Windows paths are). Evidence is the Path
// of running processes plus the image path of running services: services run
// as SYSTEM and their process Path is usually hidden from a non-elevated
// caller, while the service image path is readable. When neither list could
// be read the item is unavailable (null) instead of "not running".
func parseWindowsEDR(doc map[string]any, prefixes map[string][]string, vendorOnly bool) []map[string]any {
	processPaths, processOK := jsonStrings(doc, "process_paths")
	servicePaths, serviceOK := jsonStrings(doc, "service_paths")
	if !processOK && !serviceOK {
		return windowsUnavailableRow()
	}
	paths := make([]string, 0, len(processPaths)+len(servicePaths))
	paths = append(paths, processPaths...)
	for _, commandLine := range servicePaths {
		if path := windowsServiceExecutable(commandLine); path != "" {
			paths = append(paths, path)
		}
	}
	seenPaths := make(map[string]struct{})
	seenVendors := make(map[string]struct{})
	rows := make([]map[string]any, 0)
	for _, path := range paths {
		vendor := windowsEDRVendorForPath(path, prefixes)
		if vendor == "" {
			continue
		}
		seenVendors[vendor] = struct{}{}
		key := strings.ToLower(path)
		if _, ok := seenPaths[key]; ok {
			continue
		}
		seenPaths[key] = struct{}{}
		rows = append(rows, map[string]any{"name": path})
	}
	if !vendorOnly {
		return rows
	}
	vendors := make([]string, 0, len(seenVendors))
	for vendor := range seenVendors {
		vendors = append(vendors, vendor)
	}
	sort.Strings(vendors)
	if len(vendors) == 0 {
		return []map[string]any{{"vendor": "none"}}
	}
	vendorRows := make([]map[string]any, 0, len(vendors))
	for _, vendor := range vendors {
		vendorRows = append(vendorRows, map[string]any{"vendor": vendor})
	}
	return vendorRows
}

// windowsServiceExecutable extracts the executable from a Win32_Service
// PathName such as `"C:\Program Files\X\svc.exe" -k arg` or
// `C:\Windows\system32\svchost.exe -k netsvcs`.
func windowsServiceExecutable(commandLine string) string {
	text := strings.TrimSpace(commandLine)
	if strings.HasPrefix(text, `"`) {
		end := strings.Index(text[1:], `"`)
		if end < 0 {
			return ""
		}
		return text[1 : end+1]
	}
	lower := strings.ToLower(text)
	if index := strings.Index(lower, ".exe"); index >= 0 {
		return text[:index+len(".exe")]
	}
	return text
}

func windowsEDRVendorForPath(path string, prefixes map[string][]string) string {
	lower := strings.ToLower(path)
	for _, vendor := range []string{"sentinelone", "crowdstrike"} {
		for _, prefix := range prefixes[vendor] {
			if strings.HasPrefix(lower, strings.ToLower(prefix)) {
				return vendor
			}
		}
	}
	return ""
}

// parseWindowsBuiltinProtection maps Get-MpComputerStatus and SmartScreen.
// The required booleans fall back to false when unreadable; the signature
// version falls back to the explicit "unavailable" marker (never treated as
// active). smartscreen_enabled is null when neither the policy
// (EnableSmartScreen) nor the Explorer setting (SmartScreenEnabled) is set.
func parseWindowsBuiltinProtection(doc map[string]any) []map[string]any {
	antivirus, _ := jsonBool(doc, "antivirus_enabled")
	realtime, _ := jsonBool(doc, "realtime_protection_enabled")
	tamper, _ := jsonBool(doc, "is_tamper_protected")
	signature, _ := jsonString(doc, "antivirus_signature_version")
	if signature == "" {
		signature = windowsSignatureUnavailable
	}
	var smartScreen any
	if policy, ok := jsonInt(doc, "smartscreen_policy"); ok && (policy == 0 || policy == 1) {
		smartScreen = policy == 1
	} else if explorer, ok := jsonString(doc, "smartscreen_explorer"); ok && explorer != "" {
		switch strings.ToLower(explorer) {
		case "off":
			smartScreen = false
		case "on", "warn", "prompt", "requireadmin":
			smartScreen = true
		}
	}
	return []map[string]any{{
		"defender_antivirus_enabled": antivirus,
		"defender_realtime_enabled":  realtime,
		"defender_signature_version": signature,
		"tamper_protection_enabled":  tamper,
		"smartscreen_enabled":        smartScreen,
	}}
}

// parseWindowsAdmins lists the members of the local Administrators group
// (resolved by SID S-1-5-32-544, so it works on localized Windows) after the
// definition's exclusions. A member is one entry even when it is a domain
// group. Unreadable -> unavailable (null count).
func parseWindowsAdmins(doc map[string]any, exclusions definition.AdminExclusions) []map[string]any {
	members, ok := jsonStrings(doc, "members")
	if !ok {
		return windowsUnavailableRow()
	}
	rows := make([]map[string]any, 0, len(members))
	for _, member := range members {
		if excludedAdmin(member, exclusions) {
			continue
		}
		rows = append(rows, map[string]any{"username": member})
	}
	return rows
}

// windowsApplicationNames reads Uninstall DisplayName values (HKLM 64/32-bit
// and HKCU) and normalizes them to an application name: trailing
// "(x64 ...)"-style groups, " - <version>" and dotted version tokens are
// removed so that, for example, "Bitwarden 2024.6.0" matches "Bitwarden".
// Path separators are replaced because the posture contract carries names
// only.
//
// Failures are never an empty success:
//   - The walk could not run at all (null fields): an error, so collection
//     fails, as on macOS when system_profiler or find exits non-zero.
//   - Some Uninstall keys exist but could not be read (unreadable_keys > 0,
//     for example a third-party product protecting its subkey with an ACL):
//     the readable names are returned together with the count. The callers
//     keep every other posture value and mark only the application inventory
//     as unverifiable (see parseWindowsUnapprovedApps and
//     parseWindowsPasswordManagers), so one protected key cannot make the
//     whole device stale.
//
// Scope: MSIX/AppX packages and Microsoft Store apps are not registered under
// the Uninstall keys and are not part of this inventory.
func windowsApplicationNames(doc map[string]any) ([]string, int, error) {
	displayNames, ok := jsonStrings(doc, "display_names")
	if !ok {
		return nil, 0, errors.New("windows application inventory could not be read")
	}
	unreadable, ok := jsonInt(doc, "unreadable_keys")
	if !ok || unreadable < 0 {
		return nil, 0, errors.New("windows application inventory did not report unreadable keys")
	}
	seen := make(map[string]struct{})
	names := make([]string, 0, len(displayNames))
	for _, displayName := range displayNames {
		name := normalizeWindowsApplicationName(displayName)
		if name == "" {
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}
	sort.Strings(names)
	return names, unreadable, nil
}

var (
	windowsTrailingGroup   = regexp.MustCompile(`\s*\([^()]*\)\s*$`)
	windowsTrailingDash    = regexp.MustCompile(`\s+-\s+v?\d+(\.\d+)+\s*$`)
	windowsTrailingVersion = regexp.MustCompile(`\s+v?\d+(\.\d+)+\s*$`)
)

func normalizeWindowsApplicationName(displayName string) string {
	name := strings.TrimSpace(displayName)
	for {
		next := windowsTrailingGroup.ReplaceAllString(name, "")
		next = windowsTrailingDash.ReplaceAllString(next, "")
		next = windowsTrailingVersion.ReplaceAllString(next, "")
		next = strings.TrimSpace(next)
		if next == name || next == "" {
			break
		}
		name = next
	}
	name = strings.NewReplacer("/", "_", `\`, "_").Replace(name)
	if len(name) > 255 {
		name = strings.ToValidUTF8(name[:255], "")
	}
	return strings.TrimSpace(name)
}

// parseWindowsPasswordManagers reports approved password managers found in the
// Uninstall keys. When some keys could not be read, a manager seen in the
// readable keys is still observed evidence (true), but "none installed" cannot
// be claimed: the item becomes unavailable, which Collect maps to null.
func parseWindowsPasswordManagers(doc map[string]any, approved []string) ([]map[string]any, error) {
	names, unreadable, err := windowsApplicationNames(doc)
	if err != nil {
		return nil, err
	}
	installed := make(map[string]struct{}, len(names))
	for _, name := range names {
		installed[name] = struct{}{}
	}
	rows := make([]map[string]any, 0)
	for _, name := range approved {
		if _, ok := installed[name]; ok {
			rows = append(rows, map[string]any{"name": name})
		}
	}
	if len(rows) == 0 && unreadable > 0 {
		return windowsUnavailableRow(), nil
	}
	return rows, nil
}

// parseWindowsUnapprovedApps returns installed application names outside the
// approved list. Windows has a single inventory source (the Uninstall keys),
// so there is no cross-check between two sources. When some keys could not be
// read, the unapproved names seen in the readable keys are still returned and
// one fixed inventory_mismatch row (windowsInventoryUnreadable) marks the list
// as incomplete, so unapproved_apps=[] can never pass as a clean device.
func parseWindowsUnapprovedApps(doc map[string]any, approved []string) ([]map[string]any, error) {
	names, unreadable, err := windowsApplicationNames(doc)
	if err != nil {
		return nil, err
	}
	if unreadable > 0 {
		rows := unapprovedWindowsRows(names, approved)
		return append(rows, map[string]any{"inventory_mismatch": windowsInventoryUnreadable}), nil
	}
	return unapprovedWindowsRows(names, approved), nil
}

func unapprovedWindowsRows(names []string, approved []string) []map[string]any {
	allow := make(map[string]struct{}, len(approved))
	for _, name := range approved {
		allow[name] = struct{}{}
	}
	rows := make([]map[string]any, 0)
	for _, name := range names {
		if _, ok := allow[name]; ok {
			continue
		}
		rows = append(rows, map[string]any{"name": name})
	}
	return rows
}

// parseWindowsDeviceIdentity reads Win32_ComputerSystem.Model,
// Win32_BIOS.SerialNumber, and the host name. Model and host name are
// required by the posture contract (the server rejects empty strings), so
// their absence is an error as on macOS; the serial is not part of the
// posture and may be empty (virtual machines and self-built PCs often have
// none).
func parseWindowsDeviceIdentity(doc map[string]any) ([]map[string]any, error) {
	model, _ := jsonString(doc, "model")
	serial, _ := jsonString(doc, "serial")
	hostname, _ := jsonString(doc, "hostname")
	if model == "" || hostname == "" {
		return nil, errors.New("windows device identity output is incomplete")
	}
	return []map[string]any{{"os_family": "windows", "model": model, "serial": serial, "hostname": hostname}}, nil
}

// applyWindowsRows maps Windows rows (from the parsers above or a fixture)
// onto the snapshot. Unlike the macOS mapping, explicit nulls and
// unavailable markers stay null.
func applyWindowsRows(snapshot *posture.Snapshot, item definition.Item, rows []map[string]any) error {
	switch item.Name {
	case "disk_encrypted":
		value, err := nullableRowBool(rows, "encrypted")
		if err != nil {
			return err
		}
		snapshot.DiskEncrypted = value
	case "screen_lock":
		enabled, err := nullableRowBool(rows, "enabled")
		if err != nil {
			return err
		}
		snapshot.ScreenLockEnabled = enabled
		if len(rows) > 0 && rows[0]["delay_seconds"] != nil {
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
		// Same boolean as macOS; an unreadable state is false (fail closed).
		snapshot.PatchCurrent = boolPointer(firstBool(rows, "current"))
	case "auto_update_checks_enabled":
		value, err := nullableRowBool(rows, "enabled")
		if err != nil {
			return err
		}
		snapshot.AutoUpdateChecksEnabled = value
	case "firewall_enabled":
		value, err := nullableRowBool(rows, "enabled")
		if err != nil {
			return err
		}
		snapshot.FirewallEnabled = value
	case "edr_running":
		switch {
		case rowsUnavailable(rows):
			// Unknown: leave null unless builtin_protection promotes it.
		case len(rows) > 0:
			snapshot.EDRRunning = boolPointer(true)
		case snapshot.EDRRunning == nil:
			snapshot.EDRRunning = boolPointer(false)
		}
	case "edr_vendor":
		if rowsUnavailable(rows) {
			// edr_vendor must be a non-empty string; "unknown" states that the
			// process list could not be read, rather than claiming "none".
			snapshot.EDRVendor = "unknown"
			return nil
		}
		vendors := make([]string, 0, len(rows))
		for _, row := range rows {
			vendor := strings.TrimSpace(rowString(row, "vendor"))
			if vendor != "" && vendor != "none" {
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
		if len(rows) == 0 {
			return nil
		}
		protection, err := windowsBuiltinProtectionFromRow(rows[0])
		if err != nil {
			return err
		}
		snapshot.BuiltinProtection = protection
		if definitionPromotesTo(item, "edr_running") && windowsBuiltinProtectionActive(protection) {
			snapshot.EDRRunning = boolPointer(true)
		}
	case "admin_account_count":
		if rowsUnavailable(rows) {
			snapshot.AdminAccountCount = nil
			return nil
		}
		count := len(rows)
		snapshot.AdminAccountCount = &count
	case "password_manager_installed":
		// Partly unreadable inventory with no manager seen: unverified (null),
		// never "not installed".
		if rowsUnavailable(rows) {
			snapshot.PasswordManagerInstall = nil
			return nil
		}
		snapshot.PasswordManagerInstall = boolPointer(len(rows) > 0)
	case "unapproved_apps":
		// A fully unavailable list must not become unapproved_apps=[]; the native
		// parser fails collection in that case, and so does this mapping.
		if rowsUnavailable(rows) {
			return errors.New("windows application inventory is unavailable")
		}
		for _, row := range rows {
			if mismatch, ok := row["inventory_mismatch"]; ok {
				// Windows has no cross-check between two sources; the only
				// accepted entry is the fixed "some keys unreadable" marker.
				if mismatch != windowsInventoryUnreadable {
					return errors.New("windows unapproved_apps has no inventory cross-check rows")
				}
				if len(snapshot.ApplicationInventoryMismatches) == 0 {
					snapshot.ApplicationInventoryMismatches = append(snapshot.ApplicationInventoryMismatches, windowsInventoryUnreadable)
				}
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
	return nil
}

var windowsBuiltinProtectionRowKeys = []string{
	"defender_antivirus_enabled", "defender_realtime_enabled", "defender_signature_version",
	"smartscreen_enabled", "tamper_protection_enabled",
}

// windowsBuiltinProtectionFromRow requires exactly the five Windows keys; a
// row carrying macOS XProtect keys (or any other key) is rejected.
func windowsBuiltinProtectionFromRow(row map[string]any) (*posture.WindowsBuiltinProtection, error) {
	if len(row) != len(windowsBuiltinProtectionRowKeys) {
		return nil, errors.New("windows builtin_protection row does not match the fixed contract")
	}
	for _, key := range windowsBuiltinProtectionRowKeys {
		if _, ok := row[key]; !ok {
			return nil, errors.New("windows builtin_protection row does not match the fixed contract")
		}
	}
	requiredBool := func(key string) (bool, error) {
		switch value := row[key].(type) {
		case nil:
			return false, nil
		case bool:
			return value, nil
		default:
			return false, fmt.Errorf("windows builtin_protection %s must be boolean", key)
		}
	}
	antivirus, err := requiredBool("defender_antivirus_enabled")
	if err != nil {
		return nil, err
	}
	realtime, err := requiredBool("defender_realtime_enabled")
	if err != nil {
		return nil, err
	}
	tamper, err := requiredBool("tamper_protection_enabled")
	if err != nil {
		return nil, err
	}
	signature, ok := row["defender_signature_version"].(string)
	if !ok {
		return nil, errors.New("windows builtin_protection defender_signature_version must be a string")
	}
	protection := &posture.WindowsBuiltinProtection{
		DefenderAntivirusEnabled: antivirus,
		DefenderRealtimeEnabled:  realtime,
		DefenderSignatureVersion: strings.TrimSpace(signature),
		TamperProtectionEnabled:  tamper,
	}
	switch value := row["smartscreen_enabled"].(type) {
	case nil:
	case bool:
		protection.SmartScreenEnabled = boolPointer(value)
	default:
		return nil, errors.New("windows builtin_protection smartscreen_enabled must be boolean or null")
	}
	return protection, nil
}

// windowsBuiltinProtectionActive mirrors the macOS XProtect promotion: Defender
// antivirus and real-time protection on, a signature version present, and
// tamper protection on.
func windowsBuiltinProtectionActive(protection *posture.WindowsBuiltinProtection) bool {
	if protection == nil {
		return false
	}
	signature := strings.TrimSpace(protection.DefenderSignatureVersion)
	return protection.DefenderAntivirusEnabled && protection.DefenderRealtimeEnabled &&
		signature != "" && signature != windowsSignatureUnavailable && protection.TamperProtectionEnabled
}

// nullableRowBool returns nil for no rows or an explicit null, the value for a
// JSON boolean, and an error for any other type.
func nullableRowBool(rows []map[string]any, key string) (*bool, error) {
	if len(rows) == 0 || rows[0][key] == nil {
		return nil, nil
	}
	value, ok := rows[0][key].(bool)
	if !ok {
		return nil, fmt.Errorf("windows row %s must be boolean or null", key)
	}
	return boolPointer(value), nil
}
