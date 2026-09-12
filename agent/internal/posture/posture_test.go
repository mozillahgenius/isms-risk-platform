package posture

import (
	"bytes"
	"encoding/hex"
	"testing"

	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/signing"
)

func TestCanonicalPostureSignsAndRejectsMutation(t *testing.T) {
	_, _, hash, err := definition.LoadEmbedded()
	if err != nil {
		t.Fatal(err)
	}
	good := true
	delay := 300
	admins := 1
	snapshot := Snapshot{
		DeviceID: "d0000000-0000-4000-8000-000000000001", CollectedAt: "2026-08-14T00:00:00Z",
		AgentVersion: "test", DefinitionVersion: 2, DefinitionHash: hex.EncodeToString(hash[:]),
		ExternalID: "serial", Hostname: "mac", Model: "Mac mini", OSFamily: "macos", OSVersion: "14.6.1",
		OffPremise: false, DiskEncrypted: &good, ScreenLockEnabled: &good, ScreenLockDelaySec: &delay,
		PatchCurrent: &good, AutoUpdateChecksEnabled: &good, FirewallEnabled: &good, EDRRunning: &good,
		EDRVendor: "sentinelone", BuiltinProtection: &BuiltinProtection{
			XProtectProcessCount: 5, XProtectDefinitionVersion: "5355", XProtectRemediatorVersion: "157",
			SpctlAssessmentsEnabled: true, CSRUtilEnabled: true, SystemExtensions: []string{},
		},
		AdminAccountCount: &admins, PasswordManagerInstall: &good, UnapprovedApps: []string{}, ApplicationInventoryMismatches: []string{},
	}
	canonical, err := snapshot.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	publicKey, privateKey, err := signing.NewKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	envelope := signing.Sign(privateKey, canonical)
	if _, err := signing.Verify(envelope, publicKey); err != nil {
		t.Fatal(err)
	}
	envelope.Payload = bytes.Replace(envelope.Payload, []byte("\"serial\""), []byte("\"tamper\""), 1)
	if _, err := signing.Verify(envelope, publicKey); err == nil {
		t.Fatal("tampered posture payload was accepted")
	}
}
