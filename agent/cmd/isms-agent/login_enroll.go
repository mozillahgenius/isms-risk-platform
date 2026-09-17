package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"isms-platform/agent/internal/canonicaljson"
	"isms-platform/agent/internal/httpclient"
	"isms-platform/agent/internal/signing"
)

const managementLoginRedeemPurpose = "management-login-enrollment-redeem/v1"

type managementLoginAuthorization struct {
	UserCode        string
	VerificationURI string
	ExpiresAt       string
}

type managementLoginStartResponse struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	ExpiresAt       string `json:"expires_at"`
	Interval        int    `json:"interval"`
}

type managementLoginRedeemResponse struct {
	DeviceID string `json:"device_id"`
	Error    string `json:"error"`
}

func enrollManagementLogin(
	ctx context.Context,
	baseURL, externalID, hostname, model, osFamily string,
	offPremise bool, keyPath, configPath string,
	onAuthorization func(managementLoginAuthorization),
	deliveryToken ...string,
) (string, string, error) {
	publicKey, privateKey, err := signing.NewKeyPair()
	if err != nil {
		return "", "", err
	}
	client, err := httpclient.New(baseURL)
	if err != nil {
		return "", "", err
	}
	var start managementLoginStartResponse
	startBody := map[string]any{
		"hardware_id":    externalID,
		"hostname":       hostname,
		"model":          model,
		"os_family":      osFamily,
		"off_premise":    offPremise,
		"public_key":     base64.StdEncoding.EncodeToString(publicKey),
		"notice_version": "2026-09-14.1",
	}
	if len(deliveryToken) > 0 && deliveryToken[0] != "" {
		startBody["delivery_token"] = deliveryToken[0]
	}
	status, err := postManagementJSON(ctx, client, "/api/agent/v1/login-enroll/start", startBody, &start)
	if err != nil {
		return "", "", err
	}
	if status != http.StatusOK || start.DeviceCode == "" || start.UserCode == "" || start.VerificationURI == "" || start.ExpiresAt == "" {
		return "", "", fmt.Errorf("management login enrollment start rejected with HTTP %d", status)
	}
	expiresAt, err := time.Parse(time.RFC3339, start.ExpiresAt)
	if err != nil {
		return "", "", fmt.Errorf("management enrollment expiry is invalid: %w", err)
	}
	if onAuthorization != nil {
		onAuthorization(managementLoginAuthorization{
			UserCode: start.UserCode, VerificationURI: start.VerificationURI, ExpiresAt: start.ExpiresAt,
		})
	}
	interval := start.Interval
	if interval < 1 {
		interval = 5
	}
	for time.Now().Before(expiresAt) {
		nonceBytes := make([]byte, 24)
		if _, err := rand.Read(nonceBytes); err != nil {
			return "", "", fmt.Errorf("generate enrollment nonce: %w", err)
		}
		nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
		issuedAt := time.Now().UTC().Format(time.RFC3339Nano)
		payload, err := canonicaljson.Canonicalize(mustJSON(map[string]string{
			"device_code": start.DeviceCode,
			"issued_at":   issuedAt,
			"nonce":       nonce,
			"purpose":     managementLoginRedeemPurpose,
		}))
		if err != nil {
			return "", "", fmt.Errorf("canonicalize enrollment request: %w", err)
		}
		signature := ed25519.Sign(privateKey, payload)
		var redeem managementLoginRedeemResponse
		redeemBody := map[string]string{
			"device_code": start.DeviceCode,
			"nonce":       nonce,
			"issued_at":   issuedAt,
			"sig":         base64.StdEncoding.EncodeToString(signature),
		}
		if len(deliveryToken) > 0 && deliveryToken[0] != "" {
			redeemBody["delivery_token"] = deliveryToken[0]
		}
		status, err := postManagementJSON(ctx, client, "/api/agent/v1/login-enroll/redeem", redeemBody, &redeem)
		if err != nil {
			return "", "", err
		}
		if status == http.StatusOK && redeem.DeviceID != "" {
			absKeyPath, err := resolvePrivateKeyPath(keyPath)
			if err != nil {
				return "", "", err
			}
			if err := signing.SavePrivateKey(absKeyPath, privateKey); err != nil {
				return "", "", err
			}
			if err := saveAgentConfig(configPath, agentConfig{
				URL: baseURL, DeviceID: redeem.DeviceID, ExternalID: externalID,
				PrivateKey: absKeyPath, OffPremise: offPremise,
				Log: defaultLogPath(), Envelope: defaultEnvelopePath(), AgentVer: agentVersion,
			}); err != nil {
				return "", "", err
			}
			return redeem.DeviceID, absKeyPath, nil
		}
		if status == http.StatusBadRequest && (redeem.Error == "authorization_pending" || redeem.Error == "slow_down") {
			if redeem.Error == "slow_down" {
				interval += 5
			}
			time.Sleep(time.Duration(interval) * time.Second)
			continue
		}
		if redeem.Error == "access_denied" {
			return "", "", errors.New("management administrator denied enrollment")
		}
		if redeem.Error == "expired_token" {
			return "", "", errors.New("management enrollment approval expired")
		}
		return "", "", fmt.Errorf("management login enrollment rejected with HTTP %d", status)
	}
	return "", "", errors.New("management enrollment approval expired")
}

func resolvePrivateKeyPath(path string) (string, error) {
	return filepath.Abs(path)
}

func mustJSON(value any) []byte {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}

func postManagementJSON(ctx context.Context, client *httpclient.Client, path string, requestBody any, responseBody any) (int, error) {
	raw, err := json.Marshal(requestBody)
	if err != nil {
		return 0, fmt.Errorf("encode enrollment request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, client.BaseURL+path, strings.NewReader(string(raw)))
	if err != nil {
		return 0, fmt.Errorf("create enrollment request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.HTTP.Do(req)
	if err != nil {
		return 0, fmt.Errorf("enrollment request failed: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, 1<<20)
	if err := json.NewDecoder(limited).Decode(responseBody); err != nil {
		return response.StatusCode, fmt.Errorf("decode enrollment response: %w", err)
	}
	return response.StatusCode, nil
}
