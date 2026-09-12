package agentlog

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"isms-platform/agent/internal/signing"
)

func Append(path string, envelope signing.Envelope) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create posture log directory: %w", err)
	}
	line, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("marshal posture log: %w", err)
	}
	line = append(line, '\n')
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return fmt.Errorf("open posture log: %w", err)
	}
	defer file.Close()
	if err := file.Chmod(0600); err != nil {
		return fmt.Errorf("protect posture log: %w", err)
	}
	if _, err := file.Write(line); err != nil {
		return fmt.Errorf("append posture log: %w", err)
	}
	return nil
}
