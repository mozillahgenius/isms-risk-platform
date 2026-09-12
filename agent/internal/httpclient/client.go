package httpclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	BaseURL string
	HTTP    *http.Client
}

func New(baseURL string) (*Client, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" || !(strings.HasPrefix(baseURL, "https://") || strings.HasPrefix(baseURL, "http://127.0.0.1")) {
		return nil, fmt.Errorf("agent URL must use HTTPS (or local loopback for tests)")
	}
	return &Client{BaseURL: baseURL, HTTP: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (c *Client) Post(ctx context.Context, path string, request any, response any) error {
	body, err := json.Marshal(request)
	if err != nil {
		return fmt.Errorf("encode agent request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create agent request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("agent request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("agent endpoint rejected request with HTTP %d", resp.StatusCode)
	}
	if response == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(response); err != nil {
		return fmt.Errorf("decode agent response: %w", err)
	}
	return nil
}
