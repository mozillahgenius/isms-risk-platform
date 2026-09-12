package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"

	"isms-platform/agent/internal/collector"
	"isms-platform/agent/internal/httpclient"
	"isms-platform/agent/internal/signing"
)

func run(args []string) error {
	flags := newFlagSet("run")
	configPath := flags.String("config", defaultConfigPath(), "agent run config path")
	if err := flags.Parse(args); err != nil {
		return err
	}
	config, err := loadAgentConfig(*configPath)
	if err != nil {
		return err
	}
	privateKey, err := signing.LoadPrivateKey(config.PrivateKey)
	if err != nil {
		return err
	}
	envelope, err := collectEnvelope(
		context.Background(), privateKey, config.DeviceID, config.ExternalID,
		config.OffPremise, config.AgentVer, config.Log, collector.NativeRunner{},
	)
	if err != nil {
		return err
	}
	if err := writeEnvelope(config.Envelope, envelope); err != nil {
		return err
	}
	response, err := postEnvelope(context.Background(), config.URL, envelope)
	if err != nil {
		return err
	}
	encoded, _ := json.Marshal(response)
	fmt.Println(string(encoded))
	return nil
}

func postEnvelope(ctx context.Context, url string, envelope signing.Envelope) (map[string]any, error) {
	if url == "" {
		return nil, errors.New("agent URL is required")
	}
	client, err := httpclient.New(url)
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err := client.Post(ctx, "/api/agent/v1/posture", envelope, &response); err != nil {
		return nil, err
	}
	return response, nil
}

func newFlagSet(name string) *flag.FlagSet {
	return flag.NewFlagSet(name, flag.ContinueOnError)
}
