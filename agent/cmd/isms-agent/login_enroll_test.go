package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"isms-platform/agent/internal/canonicaljson"
)

func TestEnrollManagementLoginSignsAndPersistsAfterApproval(t *testing.T) {
	var publicKey ed25519.PublicKey
	var redeemCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatal("expected POST")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/agent/v1/login-enroll/start":
			if body["delivery_token"] != "delivery-token" {
				t.Fatalf("delivery token was not sent on start: %v", body["delivery_token"])
			}
			publicKeyText, _ := body["public_key"].(string)
			decoded, err := base64.StdEncoding.DecodeString(publicKeyText)
			if err != nil || len(decoded) != ed25519.PublicKeySize {
				t.Fatalf("invalid public key: %v", err)
			}
			publicKey = ed25519.PublicKey(decoded)
			_, _ = w.Write([]byte(`{"device_code":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","user_code":"BCDF-BCDF","verification_uri":"http://127.0.0.1/operations/device-control/approve","expires_at":"2099-01-01T00:00:00Z","interval":1}`))
		case "/api/agent/v1/login-enroll/redeem":
			if body["delivery_token"] != "delivery-token" {
				t.Fatalf("delivery token was not sent on redeem: %v", body["delivery_token"])
			}
			payload := map[string]string{
				"device_code": body["device_code"].(string),
				"issued_at":   body["issued_at"].(string),
				"nonce":       body["nonce"].(string),
				"purpose":     managementLoginRedeemPurpose,
			}
			canonical, err := canonicaljson.Canonicalize(mustJSON(payload))
			if err != nil {
				t.Fatal(err)
			}
			signatureText, _ := body["sig"].(string)
			signature, err := base64.StdEncoding.DecodeString(signatureText)
			if err != nil || !ed25519.Verify(publicKey, canonical, signature) {
				t.Fatal("redeem signature did not verify")
			}
			call := redeemCalls.Add(1)
			if call == 1 {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"authorization_pending"}`))
				return
			}
			_, _ = w.Write([]byte(`{"device_id":"11111111-1111-1111-1111-111111111111"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "device.key")
	configPath := filepath.Join(tmp, "config.json")
	var authorization managementLoginAuthorization
	deviceID, savedKey, err := enrollManagementLogin(
		t.Context(), server.URL, "test-serial", "test-host", "Mac mini", "macos", false,
		keyPath, configPath, func(value managementLoginAuthorization) { authorization = value },
		"delivery-token",
	)
	if err != nil {
		t.Fatal(err)
	}
	if deviceID == "" || savedKey != keyPath || authorization.UserCode != "BCDF-BCDF" {
		t.Fatalf("unexpected enrollment result: device=%q key=%q auth=%+v", deviceID, savedKey, authorization)
	}
	if _, err := os.Stat(configPath); err != nil {
		t.Fatal(err)
	}
	configRaw, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var config agentConfig
	if err := json.Unmarshal(configRaw, &config); err != nil {
		t.Fatal(err)
	}
	if config.DeviceID != deviceID || config.PrivateKey != keyPath {
		t.Fatalf("config was not persisted: %+v", config)
	}
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("private key mode = %o, want 600", info.Mode().Perm())
	}
}
