package posture

import (
	"strings"
	"testing"
)

// PC の基礎情報（hardware）は、あってもなくてもよい唯一の項目（2026-09-25）。

func TestHardwareRoundTripsWhenPresent(t *testing.T) {
	s := macOSSnapshot()
	s.Hardware = &Hardware{CPU: "Apple M2", Cores: "8 (4 Performance and 4 Efficiency)", Memory: "16 GB"}
	canonical, err := s.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(canonical), `"hardware":{"cores":"8 (4 Performance and 4 Efficiency)","cpu":"Apple M2","memory":"16 GB"}`) {
		t.Fatalf("hardware missing from canonical: %s", canonical)
	}
	parsed, err := ParseSnapshot(canonical)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Hardware == nil || parsed.Hardware.CPU != "Apple M2" || parsed.Hardware.Memory != "16 GB" {
		t.Fatalf("hardware did not round-trip: %+v", parsed.Hardware)
	}
}

func TestSnapshotWithoutHardwareIsStillAccepted(t *testing.T) {
	// 古いエージェントの報告（hardware が無い）は、これまでどおり受ける。
	parsed, err := ParseSnapshot([]byte(macOSGoldenCanonical))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Hardware != nil {
		t.Fatalf("hardware should be absent: %+v", parsed.Hardware)
	}
}

func TestHardwareRejectsUnknownFields(t *testing.T) {
	raw := strings.Replace(macOSGoldenCanonical, `"hostname":"mac"`, `"hardware":{"cpu":"x","gpu":"y"},"hostname":"mac"`, 1)
	if _, err := ParseSnapshot([]byte(raw)); err == nil {
		t.Fatal("unknown field inside hardware must be rejected")
	}
}

func TestUnknownTopLevelKeyIsStillRejected(t *testing.T) {
	raw := strings.Replace(macOSGoldenCanonical, `"hostname":"mac"`, `"serial":"x","hostname":"mac"`, 1)
	if _, err := ParseSnapshot([]byte(raw)); err == nil {
		t.Fatal("unknown top-level key must still be rejected")
	}
}
