package definition

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
)

// Command is an exact executable/argv pair from the reviewed definition.
// Shell parsing is deliberately not part of the contract.
type Command struct {
	Executable string   `json:"executable"`
	Args       []string `json:"args"`
}

type AdminExclusions struct {
	Names    []string `json:"names,omitempty"`
	Prefixes []string `json:"prefixes,omitempty"`
}

// Item is the only shape that can reach the collector. The server never sends
// arbitrary query or command text to the agent.
type Item struct {
	Name                     string              `json:"name"`
	Collector                string              `json:"collector"`
	Commands                 []Command           `json:"commands"`
	Output                   string              `json:"output,omitempty"`
	ApprovedNames            []string            `json:"approved_names,omitempty"`
	AdminExclude             AdminExclusions     `json:"admin_exclusions,omitempty"`
	LocationPrefixes         []string            `json:"location_prefixes,omitempty"`
	ExcludedLocationPrefixes []string            `json:"excluded_location_prefixes,omitempty"`
	LocationDepth            int                 `json:"location_depth,omitempty"`
	ApplicationInventory     string              `json:"application_inventory,omitempty"`
	IncludeHiddenBundles     bool                `json:"include_hidden_bundles,omitempty"`
	ExecutablePathPrefixes   map[string][]string `json:"executable_path_prefixes,omitempty"`
	ProcessPathLookup        string              `json:"process_path_lookup,omitempty"`
	PromotesTo               []string            `json:"promotes_to,omitempty"`
	Kind                     string              `json:"kind"`
}

type Definition struct {
	Version  int    `json:"version"`
	Platform string `json:"platform"`
	Items    []Item `json:"items"`
}

var expected = map[string]Item{
	"disk_encrypted": {
		Name: "disk_encrypted", Collector: "native", Commands: []Command{{Executable: "/usr/bin/fdesetup", Args: []string{"status"}}}, Output: "stdout", Kind: "boolean",
	},
	"screen_lock": {
		Name: "screen_lock", Collector: "native", Commands: []Command{{Executable: "/usr/sbin/sysadminctl", Args: []string{"-screenLock", "status"}}}, Output: "combined", Kind: "screen_lock",
	},
	"os_version": {
		Name: "os_version", Collector: "native", Commands: []Command{{Executable: "/usr/bin/sw_vers", Args: []string{"-productVersion"}}}, Output: "stdout", Kind: "os_version",
	},
	"patch_current": {
		Name: "patch_current", Collector: "native", Commands: []Command{{Executable: "/usr/sbin/softwareupdate", Args: []string{"--list"}}}, Output: "stdout", Kind: "boolean",
	},
	"auto_update_checks_enabled": {
		Name: "auto_update_checks_enabled", Collector: "native", Commands: []Command{{Executable: "/usr/sbin/softwareupdate", Args: []string{"--schedule"}}}, Output: "stdout", Kind: "boolean",
	},
	"firewall_enabled": {
		Name: "firewall_enabled", Collector: "native", Commands: []Command{{Executable: "/usr/libexec/ApplicationFirewall/socketfilterfw", Args: []string{"--getglobalstate"}}}, Output: "stdout", Kind: "boolean",
	},
	"edr_running": {
		Name: "edr_running", Collector: "native", Commands: []Command{{Executable: "/bin/ps", Args: []string{"-axo", "pid="}}}, Output: "stdout", ExecutablePathPrefixes: map[string][]string{"sentinelone": {"/Library/SentinelOne/", "/Library/Sentinel/"}, "crowdstrike": {"/Library/CS/", "/Library/CrowdStrike/"}}, ProcessPathLookup: "kernel_proc_pidpath", Kind: "presence",
	},
	"edr_vendor": {
		Name: "edr_vendor", Collector: "native", Commands: []Command{{Executable: "/bin/ps", Args: []string{"-axo", "pid="}}}, Output: "stdout", ExecutablePathPrefixes: map[string][]string{"sentinelone": {"/Library/SentinelOne/", "/Library/Sentinel/"}, "crowdstrike": {"/Library/CS/", "/Library/CrowdStrike/"}}, ProcessPathLookup: "kernel_proc_pidpath", Kind: "edr_vendor",
	},
	"builtin_protection": {
		Name: "builtin_protection", Collector: "native", Commands: []Command{
			{Executable: "/usr/bin/pgrep", Args: []string{"-fi", "xprotect"}},
			{Executable: "/usr/bin/defaults", Args: []string{"read", "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist", "CFBundleShortVersionString"}},
			{Executable: "/usr/bin/defaults", Args: []string{"read", "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/Info.plist", "CFBundleShortVersionString"}},
			{Executable: "/usr/sbin/spctl", Args: []string{"--status"}},
			{Executable: "/usr/bin/csrutil", Args: []string{"status"}},
			{Executable: "/usr/bin/systemextensionsctl", Args: []string{"list"}},
		}, Output: "stdout", PromotesTo: []string{"edr_running"}, Kind: "builtin_protection",
	},
	"admin_account_count": {
		Name: "admin_account_count", Collector: "native", Commands: []Command{{Executable: "/usr/bin/dscl", Args: []string{".", "-read", "/Groups/admin", "GroupMembership"}}}, Output: "stdout", AdminExclude: AdminExclusions{Names: []string{"root"}, Prefixes: []string{"_"}}, Kind: "count",
	},
	"password_manager_installed": {
		Name: "password_manager_installed", Collector: "native", Commands: []Command{{Executable: "/usr/sbin/system_profiler", Args: []string{"SPApplicationsDataType", "-detailLevel", "mini"}}},
		Output: "stdout", ApprovedNames: []string{"1Password", "Bitwarden", "KeePassXC"}, Kind: "presence",
	},
	"unapproved_apps": {
		Name: "unapproved_apps", Collector: "native", Commands: []Command{
			{Executable: "/usr/sbin/system_profiler", Args: []string{"SPApplicationsDataType", "-detailLevel", "mini"}},
			{Executable: "/usr/bin/find", Args: []string{"/Applications", "-name", "*.app", "-prune", "-print"}},
		},
		Output: "stdout", ApprovedNames: []string{"1Password", "Bitwarden", "KeePassXC", "Google Chrome", "Safari", "Microsoft Edge", "Firefox"},
		LocationPrefixes: []string{"/Applications"}, ExcludedLocationPrefixes: []string{"/System/Applications", "~/Applications"}, LocationDepth: 1,
		ApplicationInventory: "system_profiler_and_directory", IncludeHiddenBundles: true, Kind: "names",
	},
	"device_identity": {
		Name: "device_identity", Collector: "native", Commands: []Command{
			{Executable: "/usr/sbin/system_profiler", Args: []string{"SPHardwareDataType"}},
			{Executable: "/bin/hostname", Args: []string{}},
		}, Output: "stdout", Kind: "identity",
	},
	"off_premise": {
		Name: "off_premise", Collector: "metadata", Commands: []Command{}, Kind: "enrollment",
	},
}

// Windows collector commands. Each one is a fixed absolute executable with a
// fixed argv; nothing is assembled at run time (these are compile-time
// constants). Every script prints exactly one JSON object through
// ConvertTo-Json so the collector never splits table-formatted console output.
// The scripts contain no double quotes on purpose: Windows argv quoting of
// embedded double quotes is fragile for powershell.exe -Command.
// Each body runs inside `& { ... }` with try/catch so an unreadable source
// becomes JSON null instead of a non-zero exit that would stop collection.
const (
	windowsPowerShell       = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
	windowsScriptPrologue   = `[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & { `
	windowsScriptEpilogue   = ` } | ConvertTo-Json -Compress`
	windowsDiskScript       = windowsScriptPrologue + `$d=$env:SystemDrive; $s=$null; $c=$null; try { $s=(New-Object -ComObject Shell.Application).NameSpace($d+'\').Self.ExtendedProperty('System.Volume.BitLockerProtection') } catch {}; try { $c=(Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ('DriveLetter='''+$d+'''') -ErrorAction Stop).ProtectionStatus } catch {}; [pscustomobject]@{shell_protection=$s; cim_protection_status=$c}` + windowsScriptEpilogue
	windowsScreenLockScript = windowsScriptPrologue + `function IbReg($p,$n) { try { (Get-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop).$n } catch { $null } }; $u='HKCU:\Control Panel\Desktop'; $g='HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; $m='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; [pscustomobject]@{user_active=(IbReg $u 'ScreenSaveActive'); user_secure=(IbReg $u 'ScreenSaverIsSecure'); user_timeout=(IbReg $u 'ScreenSaveTimeOut'); user_saver=(IbReg $u 'SCRNSAVE.EXE'); policy_active=(IbReg $g 'ScreenSaveActive'); policy_secure=(IbReg $g 'ScreenSaverIsSecure'); policy_timeout=(IbReg $g 'ScreenSaveTimeOut'); policy_saver=(IbReg $g 'SCRNSAVE.EXE'); inactivity_timeout_secs=(IbReg $m 'InactivityTimeoutSecs')}` + windowsScriptEpilogue
	windowsOSVersionScript  = windowsScriptPrologue + `$v=$null; try { $v=(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Version } catch {}; if (-not $v) { $o=[Environment]::OSVersion.Version; $v=[string]$o.Major+'.'+[string]$o.Minor+'.'+[string]$o.Build }; [pscustomobject]@{version=$v}` + windowsScriptEpilogue
	windowsPatchScript      = windowsScriptPrologue + `$n=$null; try { $q=(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher(); $q.Online=$false; $n=$q.Search('IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type=''Software''').Updates.Count } catch {}; [pscustomobject]@{pending_count=$n}` + windowsScriptEpilogue
	// policy_read separates "the AU policy key/value is absent" (OpenSubKey
	// returns null / GetValue returns null, policy_read=true) from "the policy
	// could not be read" (an exception such as an ACL denial, a provider
	// failure, or Constrained Language Mode, policy_read=false). The 64-bit
	// registry view is opened explicitly so a 32-bit host cannot be redirected.
	windowsAutoUpdateScript = windowsScriptPrologue + `$ErrorActionPreference='Stop'; $r=$false; $a=$null; $o=$null; $m=$null; try { $b=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64'); $k=$b.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'); if ($null -ne $k) { $a=$k.GetValue('NoAutoUpdate'); $o=$k.GetValue('AUOptions'); $k.Close() }; $r=$true } catch {}; try { $m=[string](Get-CimInstance -ClassName Win32_Service -Filter 'Name=''wuauserv''' -ErrorAction Stop).StartMode } catch {}; [pscustomobject]@{policy_read=$r; no_auto_update=$a; au_options=$o; wuauserv_start_mode=$m}` + windowsScriptEpilogue
	windowsFirewallScript   = windowsScriptPrologue + `$r=$null; try { $r=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop) } catch { try { $r=@(Get-NetFirewallProfile -ErrorAction Stop) } catch {} }; if ($null -eq $r) { [pscustomobject]@{profile_count=$null; enabled_profiles=$null; disabled_profiles=$null} } else { [pscustomobject]@{profile_count=$r.Count; enabled_profiles=@($r | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { [string]$_.Name }); disabled_profiles=@($r | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })} }` + windowsScriptEpilogue
	windowsEDRScript        = windowsScriptPrologue + `$p=$null; $s=$null; try { $p=@(Get-Process -ErrorAction Stop | ForEach-Object { $_.Path } | Where-Object { $_ } | Sort-Object -Unique) } catch {}; try { $s=@(Get-CimInstance -ClassName Win32_Service -Filter 'State=''Running''' -ErrorAction Stop | ForEach-Object { $_.PathName } | Where-Object { $_ } | Sort-Object -Unique) } catch {}; [pscustomobject]@{process_paths=$p; service_paths=$s}` + windowsScriptEpilogue
	windowsProtectionScript = windowsScriptPrologue + `$m=$null; $sp=$null; $se=$null; try { $m=Get-MpComputerStatus -ErrorAction Stop } catch {}; try { $sp=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableSmartScreen' -ErrorAction Stop).EnableSmartScreen } catch {}; try { $se=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SmartScreenEnabled' -ErrorAction Stop).SmartScreenEnabled } catch {}; [pscustomobject]@{antivirus_enabled=$m.AntivirusEnabled; realtime_protection_enabled=$m.RealTimeProtectionEnabled; antivirus_signature_version=$m.AntivirusSignatureVersion; is_tamper_protected=$m.IsTamperProtected; smartscreen_policy=$sp; smartscreen_explorer=$se}` + windowsScriptEpilogue
	windowsAdminScript      = windowsScriptPrologue + `$r=$null; try { $n=(New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]; $g=[ADSI]('WinNT://'+$env:COMPUTERNAME+'/'+$n+',group'); $r=@(foreach ($x in @($g.psbase.Invoke('Members'))) { $t=$x.GetType(); $a=[string]$t.InvokeMember('ADsPath','GetProperty',$null,$x,$null); $c=[string]$t.InvokeMember('Class','GetProperty',$null,$x,$null); $f=0; if ($c -eq 'User') { try { $f=[int]$t.InvokeMember('UserFlags','GetProperty',$null,$x,$null) } catch {} }; $u=($a -split '/')[-1]; if (($f -band 2) -ne 0) { 'disabled:'+$u } else { $u } }) } catch {}; [pscustomobject]@{members=$r}` + windowsScriptEpilogue
	// The application inventory walks the three Uninstall keys with the .NET
	// registry API so that "a key is absent" (OpenSubKey returns null: skipped)
	// is distinct from "a key exists but could not be read" (an exception:
	// counted in unreadable_keys). A subkey that vanished between enumeration
	// and open also returns null and is skipped. If the walk itself cannot run
	// (for example Constrained Language Mode), both fields are null.
	// MSIX/AppX and Microsoft Store apps are not registered under the Uninstall
	// keys and are out of scope for this inventory.
	windowsAppsScript        = windowsScriptPrologue + `$ErrorActionPreference='Stop'; function IbApps($h,$p) { $k=$null; try { $k=$h.OpenSubKey($p) } catch { 'f:'; return }; if ($null -eq $k) { return }; $s=$null; try { $s=$k.GetSubKeyNames() } catch { 'f:'; $k.Close(); return }; foreach ($x in $s) { try { $c=$k.OpenSubKey($x); if ($null -eq $c) { continue }; $d=[string]$c.GetValue('DisplayName'); $sc=$c.GetValue('SystemComponent'); $pk=[string]$c.GetValue('ParentKeyName'); $rt=[string]$c.GetValue('ReleaseType'); $c.Close(); if ($d -and $sc -ne 1 -and -not $pk -and $rt -notin @('Security Update','Update Rollup','Hotfix')) { 'n:'+$d } } catch { 'f:' } }; $k.Close() }; $o=$null; try { $lm=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64'); $cu=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry64'); $o=@(IbApps $lm 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; IbApps $lm 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; IbApps $cu 'Software\Microsoft\Windows\CurrentVersion\Uninstall') } catch {}; if ($null -eq $o) { [pscustomobject]@{display_names=$null; unreadable_keys=$null} } else { [pscustomobject]@{display_names=@($o | Where-Object { $_.StartsWith('n:') } | ForEach-Object { $_.Substring(2) } | Sort-Object -Unique); unreadable_keys=@($o | Where-Object { $_ -eq 'f:' }).Count} }` + windowsScriptEpilogue
	windowsIdentityScript    = windowsScriptPrologue + `$m=$null; $s=$null; try { $m=(Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model } catch {}; try { $s=(Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber } catch {}; [pscustomobject]@{model=$m; serial=$s; hostname=[System.Net.Dns]::GetHostName()}` + windowsScriptEpilogue
	windowsProcessPathLookup = "process_path_and_running_service_image"
)

func windowsCommand(script string) []Command {
	return []Command{{Executable: windowsPowerShell, Args: []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script}}}
}

var windowsEDRPrefixes = map[string][]string{
	"sentinelone": {`C:\Program Files\SentinelOne\`},
	"crowdstrike": {`C:\Program Files\CrowdStrike\`},
}

// expectedWindows is the fixed Windows allowlist. Item names, kinds, and the
// promotes_to rule mirror the macOS allowlist; only the commands and the
// OS-specific matching data differ. Output "json" marks items whose stdout is a
// single JSON object parsed by the Windows parsers.
var expectedWindows = map[string]Item{
	"disk_encrypted": {
		Name: "disk_encrypted", Collector: "native", Commands: windowsCommand(windowsDiskScript), Output: "json", Kind: "boolean",
	},
	"screen_lock": {
		Name: "screen_lock", Collector: "native", Commands: windowsCommand(windowsScreenLockScript), Output: "json", Kind: "screen_lock",
	},
	"os_version": {
		Name: "os_version", Collector: "native", Commands: windowsCommand(windowsOSVersionScript), Output: "json", Kind: "os_version",
	},
	"patch_current": {
		Name: "patch_current", Collector: "native", Commands: windowsCommand(windowsPatchScript), Output: "json", Kind: "boolean",
	},
	"auto_update_checks_enabled": {
		Name: "auto_update_checks_enabled", Collector: "native", Commands: windowsCommand(windowsAutoUpdateScript), Output: "json", Kind: "boolean",
	},
	"firewall_enabled": {
		Name: "firewall_enabled", Collector: "native", Commands: windowsCommand(windowsFirewallScript), Output: "json", Kind: "boolean",
	},
	"edr_running": {
		Name: "edr_running", Collector: "native", Commands: windowsCommand(windowsEDRScript), Output: "json",
		ExecutablePathPrefixes: windowsEDRPrefixes, ProcessPathLookup: windowsProcessPathLookup, Kind: "presence",
	},
	"edr_vendor": {
		Name: "edr_vendor", Collector: "native", Commands: windowsCommand(windowsEDRScript), Output: "json",
		ExecutablePathPrefixes: windowsEDRPrefixes, ProcessPathLookup: windowsProcessPathLookup, Kind: "edr_vendor",
	},
	"builtin_protection": {
		Name: "builtin_protection", Collector: "native", Commands: windowsCommand(windowsProtectionScript), Output: "json",
		PromotesTo: []string{"edr_running"}, Kind: "builtin_protection",
	},
	"admin_account_count": {
		// The script tags local user accounts whose UserFlags has
		// ACCOUNTDISABLE (0x2) as "disabled:<name>"; the exclusion below drops
		// them, which covers the disabled built-in Administrator.
		Name: "admin_account_count", Collector: "native", Commands: windowsCommand(windowsAdminScript), Output: "json",
		AdminExclude: AdminExclusions{Prefixes: []string{"disabled:"}}, Kind: "count",
	},
	"password_manager_installed": {
		Name: "password_manager_installed", Collector: "native", Commands: windowsCommand(windowsAppsScript), Output: "json",
		ApprovedNames: []string{"1Password", "Bitwarden", "KeePassXC"}, Kind: "presence",
	},
	"unapproved_apps": {
		Name: "unapproved_apps", Collector: "native", Commands: windowsCommand(windowsAppsScript), Output: "json",
		ApprovedNames: []string{"1Password", "Bitwarden", "KeePassXC", "Google Chrome", "Microsoft Edge", "Firefox"}, Kind: "names",
	},
	"device_identity": {
		Name: "device_identity", Collector: "native", Commands: windowsCommand(windowsIdentityScript), Output: "json", Kind: "identity",
	},
	"off_premise": {
		Name: "off_premise", Collector: "metadata", Commands: []Command{}, Kind: "enrollment",
	},
}

// allowlists maps each supported platform to its fixed v2 allowlist.
var allowlists = map[string]map[string]Item{
	"macos":   expected,
	"windows": expectedWindows,
}

func Parse(raw []byte) (Definition, error) {
	var d Definition
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		return Definition{}, fmt.Errorf("definition JSON: %w", err)
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return Definition{}, errors.New("definition JSON contains trailing data")
		}
		return Definition{}, fmt.Errorf("definition JSON trailing data: %w", err)
	}
	if err := d.Validate(); err != nil {
		return Definition{}, err
	}
	return d, nil
}

func (d Definition) Validate() error {
	allowlist, supported := allowlists[d.Platform]
	if d.Version != 2 || !supported {
		return fmt.Errorf("unsupported definition version/platform: %d/%s", d.Version, d.Platform)
	}
	if len(d.Items) != len(allowlist) {
		return fmt.Errorf("definition must contain exactly %d items", len(allowlist))
	}
	seen := make(map[string]bool, len(d.Items))
	for _, item := range d.Items {
		want, ok := allowlist[item.Name]
		if !ok || seen[item.Name] {
			return fmt.Errorf("definition item is not allowlisted or duplicated: %q", item.Name)
		}
		if !reflect.DeepEqual(item, want) {
			return fmt.Errorf("definition item %q differs from the fixed allowlist", item.Name)
		}
		seen[item.Name] = true
	}
	return nil
}

func RawHash(raw []byte) [32]byte { return sha256.Sum256(raw) }

func LoadFile(path string) ([]byte, Definition, [32]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, Definition{}, [32]byte{}, err
	}
	d, err := Parse(raw)
	if err != nil {
		return nil, Definition{}, [32]byte{}, err
	}
	return raw, d, RawHash(raw), nil
}

func VerifySignature(raw, signature []byte, publicKey ed25519.PublicKey) error {
	if len(publicKey) != ed25519.PublicKeySize {
		return errors.New("definition public key has an invalid length")
	}
	if !ed25519.Verify(publicKey, raw, signature) {
		return errors.New("definition signature is invalid")
	}
	return nil
}

func DecodeBase64(s string, size int) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) != size {
		return nil, errors.New("invalid base64 key or signature")
	}
	return b, nil
}
