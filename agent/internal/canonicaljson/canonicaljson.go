// Package canonicaljson provides the small deterministic JSON subset used for
// signing posture payloads. Posture values are objects, arrays, strings,
// booleans, integers, and null; object keys are emitted in lexical order.
package canonicaljson

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
)

func Canonicalize(raw []byte) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, fmt.Errorf("decode JSON: %w", err)
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("JSON contains trailing data")
		}
		return nil, fmt.Errorf("decode trailing JSON: %w", err)
	}

	var out bytes.Buffer
	if err := writeValue(&out, value); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func writeValue(out *bytes.Buffer, value any) error {
	switch v := value.(type) {
	case nil:
		out.WriteString("null")
	case bool:
		if v {
			out.WriteString("true")
		} else {
			out.WriteString("false")
		}
	case json.Number:
		out.WriteString(v.String())
	case string:
		encoded, err := marshalString(v)
		if err != nil {
			return err
		}
		out.Write(encoded)
	case []any:
		out.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				out.WriteByte(',')
			}
			if err := writeValue(out, item); err != nil {
				return err
			}
		}
		out.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		out.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				out.WriteByte(',')
			}
			encoded, err := marshalString(key)
			if err != nil {
				return err
			}
			out.Write(encoded)
			out.WriteByte(':')
			if err := writeValue(out, v[key]); err != nil {
				return err
			}
		}
		out.WriteByte('}')
	default:
		return fmt.Errorf("unsupported JSON value type %T", value)
	}
	return nil
}

func marshalString(value string) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}), nil
}
