package collector

import "testing"

// system_profiler SPHardwareDataType の出力から PC の基礎情報を読む（2026-09-25）。
func TestParseDeviceIdentityReadsHardware(t *testing.T) {
	appleSilicon := `Hardware:
    Hardware Overview:
      Model Name: Mac mini
      Chip: Apple M2
      Total Number of Cores: 8 (4 Performance and 4 Efficiency)
      Memory: 16 GB
      Serial Number (system): ABC123
`
	rows, err := parseDeviceIdentity([]string{appleSilicon, "example-mac\n"})
	if err != nil {
		t.Fatal(err)
	}
	r := rows[0]
	if r["cpu"] != "Apple M2" || r["cores"] != "8 (4 Performance and 4 Efficiency)" || r["memory"] != "16 GB" {
		t.Fatalf("unexpected hardware row: %+v", r)
	}

	intel := `      Model Name: MacBook Pro
      Processor Name: 8-Core Intel Core i9
      Total Number of Cores: 8
      Memory: 32 GB
      Serial Number (system): XYZ
`
	rows, err = parseDeviceIdentity([]string{intel, "mbp\n"})
	if err != nil {
		t.Fatal(err)
	}
	if rows[0]["cpu"] != "8-Core Intel Core i9" {
		t.Fatalf("intel cpu not read: %+v", rows[0])
	}
}
