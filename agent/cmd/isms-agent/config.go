package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type agentConfig struct {
	URL        string `json:"url"`
	DeviceID   string `json:"device_id"`
	ExternalID string `json:"external_id"`
	PrivateKey string `json:"private_key"`
	OffPremise bool   `json:"off_premise"`
	Log        string `json:"log"`
	Envelope   string `json:"envelope"`
	AgentVer   string `json:"agent_version"`
}

func (c agentConfig) validate() error {
	if c.URL == "" || c.DeviceID == "" || c.ExternalID == "" || c.PrivateKey == "" {
		return errors.New("config requires url, device_id, external_id, and private_key")
	}
	return nil
}

func loadAgentConfig(path string) (agentConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return agentConfig{}, fmt.Errorf("read agent config: %w", err)
	}
	var config agentConfig
	if err := json.Unmarshal(raw, &config); err != nil {
		return agentConfig{}, fmt.Errorf("decode agent config: %w", err)
	}
	if err := config.validate(); err != nil {
		return agentConfig{}, err
	}
	if config.Log == "" {
		config.Log = defaultLogPath()
	}
	if config.Envelope == "" {
		config.Envelope = defaultEnvelopePath()
	}
	if config.AgentVer == "" {
		config.AgentVer = agentVersion
	}
	return config, nil
}

func saveAgentConfig(path string, config agentConfig) error {
	if err := config.validate(); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("encode agent config: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create agent config directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("open agent config: %w", err)
	}
	defer file.Close()
	if err := file.Chmod(0600); err != nil {
		return fmt.Errorf("protect agent config: %w", err)
	}
	if _, err := file.Write(append(raw, '\n')); err != nil {
		return fmt.Errorf("write agent config: %w", err)
	}
	return nil
}

func defaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", ".config", "isms-agent", "config.json")
	}
	return filepath.Join(home, ".config", "isms-agent", "config.json")
}

func defaultEnvelopePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", ".local", "state", "isms-agent", "posture.json")
	}
	return filepath.Join(home, ".local", "state", "isms-agent", "posture.json")
}
