package definition

import (
	"bytes"
	"crypto/ed25519"
	"strings"
	"testing"
)

func TestEmbeddedDefinitionIsTheFixedMacOSAllowlist(t *testing.T) {
	raw, d, _, err := LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) == 0 || len(d.Items) != 14 {
		t.Fatalf("unexpected embedded definition shape: %d items", len(d.Items))
	}
	mutated := bytes.Replace(raw, []byte("/usr/bin/fdesetup"), []byte("/usr/bin/other-tool"), 1)
	if _, err := Parse(mutated); err == nil {
		t.Fatal("mutated native command was accepted")
	}
	if _, err := Parse(append(raw, []byte("{}")...)); err == nil {
		t.Fatal("trailing JSON was accepted")
	}
	for _, prohibited := range []string{
		"file_contents", "browser_history", "keystroke", "clipboard", "screenshot",
		"geolocation", "app_usage", "email_body", "chat_body",
	} {
		if strings.Contains(strings.ToLower(string(raw)), prohibited) {
			t.Fatalf("prohibited collection term appears in fixed definition: %s", prohibited)
		}
	}
}

func TestDefinitionSignatureRejectsMutation(t *testing.T) {
	raw, _, _, err := LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, raw)
	if err := VerifySignature(raw, signature, publicKey); err != nil {
		t.Fatal(err)
	}
	mutated := bytes.Replace(raw, []byte("\"macos\""), []byte("\"windows\""), 1)
	if err := VerifySignature(mutated, signature, publicKey); err == nil {
		t.Fatal("mutated definition was accepted with the original signature")
	}
}
