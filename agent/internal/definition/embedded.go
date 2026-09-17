package definition

import (
	_ "embed"
	"fmt"
	"runtime"
)

// Embedded is the reviewed, fixed macOS collector definition shipped with
// isms-agent. The server may publish a signed copy, but the agent never accepts
// arbitrary query or command text at runtime.
//
//go:embed v2.json
var Embedded []byte

// EmbeddedWindows is the reviewed, fixed Windows collector definition. It uses
// the same item names, kinds, and posture contract as the macOS definition.
//
//go:embed windows-v2.json
var EmbeddedWindows []byte

// PlatformForGOOS maps a Go GOOS value to the definition platform the agent
// runs with: windows uses the Windows definition, everything else keeps the
// existing macOS definition.
func PlatformForGOOS(goos string) string {
	if goos == "windows" {
		return "windows"
	}
	return "macos"
}

// LoadEmbedded returns the embedded definition for the running OS.
func LoadEmbedded() ([]byte, Definition, [32]byte, error) {
	return LoadEmbeddedFor(PlatformForGOOS(runtime.GOOS))
}

// LoadEmbeddedFor returns the embedded definition for an explicit platform.
func LoadEmbeddedFor(platform string) ([]byte, Definition, [32]byte, error) {
	var raw []byte
	switch platform {
	case "macos":
		raw = Embedded
	case "windows":
		raw = EmbeddedWindows
	default:
		return nil, Definition{}, [32]byte{}, fmt.Errorf("no embedded definition for platform %q", platform)
	}
	d, err := Parse(raw)
	if err != nil {
		return nil, Definition{}, [32]byte{}, err
	}
	if d.Platform != platform {
		return nil, Definition{}, [32]byte{}, fmt.Errorf("embedded definition platform %q does not match %q", d.Platform, platform)
	}
	return raw, d, RawHash(raw), nil
}
