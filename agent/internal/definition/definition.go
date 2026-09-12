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
	if d.Version != 2 || d.Platform != "macos" {
		return fmt.Errorf("unsupported definition version/platform: %d/%s", d.Version, d.Platform)
	}
	if len(d.Items) != len(expected) {
		return fmt.Errorf("definition must contain exactly %d items", len(expected))
	}
	seen := make(map[string]bool, len(d.Items))
	for _, item := range d.Items {
		want, ok := expected[item.Name]
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
