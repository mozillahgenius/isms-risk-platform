package signing

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"isms-platform/agent/internal/canonicaljson"
)

type Envelope struct {
	Payload   json.RawMessage `json:"payload"`
	Signature string          `json:"signature"`
}

func NewKeyPair() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	publicKey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		return nil, nil, fmt.Errorf("generate device key: %w", err)
	}
	return publicKey, privateKey, nil
}

func Sign(privateKey ed25519.PrivateKey, canonicalPayload []byte) Envelope {
	signature := ed25519.Sign(privateKey, canonicalPayload)
	return Envelope{
		Payload:   json.RawMessage(canonicalPayload),
		Signature: base64.StdEncoding.EncodeToString(signature),
	}
}

func Verify(envelope Envelope, publicKey ed25519.PublicKey) ([]byte, error) {
	canonicalPayload, err := canonicaljson.Canonicalize(envelope.Payload)
	if err != nil {
		return nil, fmt.Errorf("canonicalize posture payload: %w", err)
	}
	signature, err := base64.StdEncoding.DecodeString(envelope.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return nil, fmt.Errorf("invalid posture signature encoding")
	}
	if !ed25519.Verify(publicKey, canonicalPayload, signature) {
		return nil, fmt.Errorf("posture signature is invalid")
	}
	return canonicalPayload, nil
}

func SavePrivateKey(path string, key ed25519.PrivateKey) error {
	if len(key) != ed25519.PrivateKeySize {
		return fmt.Errorf("invalid private key length")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create key directory: %w", err)
	}
	if err := os.WriteFile(path, key, 0600); err != nil {
		return fmt.Errorf("write private key: %w", err)
	}
	return nil
}

func LoadPrivateKey(path string) (ed25519.PrivateKey, error) {
	key, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read private key: %w", err)
	}
	if len(key) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("invalid private key length")
	}
	return ed25519.PrivateKey(key), nil
}
