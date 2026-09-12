package canonicaljson

import "testing"

func TestCanonicalizeSortsObjectKeysWithoutHTMLEscaping(t *testing.T) {
	got, err := Canonicalize([]byte(`{"z":"<&","a":1,"nested":{"b":true,"a":null}}`))
	if err != nil {
		t.Fatal(err)
	}
	want := `{"a":1,"nested":{"a":null,"b":true},"z":"<&"}`
	if string(got) != want {
		t.Fatalf("canonical JSON mismatch: got %s want %s", got, want)
	}
}
