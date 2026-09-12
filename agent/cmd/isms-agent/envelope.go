package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"isms-platform/agent/internal/agentlog"
	"isms-platform/agent/internal/collector"
	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/signing"
)

func collectEnvelope(
	ctx context.Context,
	privateKey []byte,
	deviceID string,
	externalID string,
	offPremise bool,
	version string,
	logPath string,
	runner collector.QueryRunner,
) (signing.Envelope, error) {
	_, d, definitionHash, err := definition.LoadEmbedded()
	if err != nil {
		return signing.Envelope{}, err
	}
	snapshot, err := collector.Collect(ctx, d, runner, collector.Metadata{
		DeviceID: deviceID, ExternalID: externalID, OffPremise: offPremise, AgentVer: version,
	})
	if err != nil {
		return signing.Envelope{}, err
	}
	snapshot.DefinitionHash = hex.EncodeToString(definitionHash[:])
	snapshot.SortApps()
	canonical, err := snapshot.Canonical()
	if err != nil {
		return signing.Envelope{}, err
	}
	envelope := signing.Sign(privateKey, canonical)
	if err := agentlog.Append(logPath, envelope); err != nil {
		return signing.Envelope{}, err
	}
	return envelope, nil
}

func writeEnvelope(path string, envelope signing.Envelope) error {
	raw, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create posture directory: %w", err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0600); err != nil {
		return fmt.Errorf("write signed posture: %w", err)
	}
	if err := os.Chmod(path, 0600); err != nil {
		return fmt.Errorf("protect signed posture: %w", err)
	}
	return nil
}
