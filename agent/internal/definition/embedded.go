package definition

import _ "embed"

// Embedded is the reviewed, fixed macOS collector definition shipped with
// isms-agent. The server may publish a signed copy, but the agent never accepts
// arbitrary query or command text at runtime.
//
//go:embed v2.json
var Embedded []byte

func LoadEmbedded() ([]byte, Definition, [32]byte, error) {
	d, err := Parse(Embedded)
	if err != nil {
		return nil, Definition{}, [32]byte{}, err
	}
	return Embedded, d, RawHash(Embedded), nil
}
