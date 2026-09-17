package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"isms-platform/agent/internal/collector"
	"isms-platform/agent/internal/definition"
	"isms-platform/agent/internal/httpclient"
	"isms-platform/agent/internal/signing"
)

const agentVersion = "0.2.0-phase3a-native"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "enroll":
		err = enroll(os.Args[2:])
	case "collect":
		err = collect(os.Args[2:])
	case "posture":
		err = post(os.Args[2:])
	case "run":
		err = run(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "isms-agent:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: isms-agent enroll|collect|posture|run [flags]")
}

func enroll(args []string) error {
	flags := flag.NewFlagSet("enroll", flag.ContinueOnError)
	url := flags.String("url", "", "agent API base URL")
	token := flags.String("enrollment-token", "", "one-time enrollment token")
	deliveryToken := flags.String("delivery-token", "", "one-time installer delivery token")
	externalID := flags.String("external-id", "", "stable device identifier")
	hostname := flags.String("hostname", "", "device hostname")
	model := flags.String("model", "", "device model")
	// The default follows the running OS so a Windows enrollment matches the
	// Windows definition and posture os_family.
	osFamily := flags.String("os-family", definition.PlatformForGOOS(runtime.GOOS), "OS family")
	offPremise := flags.Bool("off-premise", false, "mark the device as off-premise")
	keyPath := flags.String("private-key", defaultPrivateKeyPath(), "private key path")
	configPath := flags.String("config", defaultConfigPath(), "agent run config path")
	if err := flags.Parse(args); err != nil {
		return err
	}
	for name, value := range map[string]string{
		"url": *url, "external-id": *externalID,
		"hostname": *hostname, "model": *model,
	} {
		if value == "" {
			return fmt.Errorf("--%s is required", name)
		}
	}
	if *token == "" {
		deviceID, absKeyPath, err := enrollManagementLogin(
			context.Background(), *url, *externalID, *hostname, *model, *osFamily,
			*offPremise, *keyPath, *configPath,
			func(auth managementLoginAuthorization) {
				printManagementLoginInstructions(auth, *deliveryToken != "")
			},
			*deliveryToken,
		)
		if err != nil {
			return err
		}
		fmt.Printf("device_id: %s\nprivate_key: %s\n", deviceID, absKeyPath)
		return nil
	}
	publicKey, privateKey, err := signing.NewKeyPair()
	if err != nil {
		return err
	}
	client, err := httpclient.New(*url)
	if err != nil {
		return err
	}
	var response struct {
		DeviceID string `json:"device_id"`
	}
	err = client.Post(context.Background(), "/api/agent/v1/enroll", map[string]any{
		"token":       *token,
		"external_id": *externalID,
		"hostname":    *hostname,
		"model":       *model,
		"os_family":   *osFamily,
		"off_premise": *offPremise,
		"public_key":  encodeBase64(publicKey),
	}, &response)
	if err != nil {
		return err
	}
	if response.DeviceID == "" {
		return errors.New("enrollment response did not contain a device_id")
	}
	absKeyPath, err := filepath.Abs(*keyPath)
	if err != nil {
		return fmt.Errorf("resolve private key path: %w", err)
	}
	if err := signing.SavePrivateKey(absKeyPath, privateKey); err != nil {
		return err
	}
	if err := saveAgentConfig(*configPath, agentConfig{
		URL: *url, DeviceID: response.DeviceID, ExternalID: *externalID,
		PrivateKey: absKeyPath, OffPremise: *offPremise,
		Log: defaultLogPath(), Envelope: defaultEnvelopePath(), AgentVer: agentVersion,
	}); err != nil {
		return err
	}
	fmt.Printf("device_id: %s\nprivate_key: %s\n", response.DeviceID, absKeyPath)
	return nil
}

func printManagementLoginInstructions(auth managementLoginAuthorization, distributed bool) {
	openVerificationURI(auth.VerificationURI)
	if distributed {
		fmt.Printf("対象機器専用Gmailアクティベート画面: %s\nこの配布方式では認証コードの入力は不要です。送付先のGmailで画面を開き、「Gmailアカウントで認証してアクティベート」を押してください。（期限 %s）\n", auth.VerificationURI, auth.ExpiresAt)
		return
	}
	fmt.Printf("Managementの手動承認画面: %s\n認証コード: %s（期限 %s）\n", auth.VerificationURI, auth.UserCode, auth.ExpiresAt)
}

// openVerificationURI is best effort. Headless/service installs still receive
// the URL on stdout and can complete the same flow from another authenticated
// browser, while interactive installs open it on the target machine itself.
func openVerificationURI(uri string) {
	var command string
	var args []string
	switch runtime.GOOS {
	case "darwin":
		command, args = "open", []string{uri}
	case "windows":
		command, args = "rundll32", []string{"url.dll,FileProtocolHandler", uri}
	case "linux":
		command, args = "xdg-open", []string{uri}
	default:
		return
	}
	if err := exec.Command(command, args...).Start(); err != nil {
		fmt.Fprintf(os.Stderr, "isms-agent: 承認画面を自動で開けませんでした: %v\n", err)
	}
}

func collect(args []string) error {
	flags := flag.NewFlagSet("collect", flag.ContinueOnError)
	deviceID := flags.String("device-id", "", "enrolled device UUID")
	externalID := flags.String("external-id", "", "stable device identifier")
	keyPath := flags.String("private-key", defaultPrivateKeyPath(), "private key path")
	fixturePath := flags.String("fixture", "", "JSON fixture instead of osqueryi")
	logPath := flags.String("log", defaultLogPath(), "readable local posture log")
	outputPath := flags.String("output", "", "write the signed envelope to a file")
	offPremise := flags.Bool("off-premise", false, "mark the device as off-premise")
	version := flags.String("agent-version", agentVersion, "agent version")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *deviceID == "" || *externalID == "" {
		return errors.New("--device-id and --external-id are required")
	}
	privateKey, err := signing.LoadPrivateKey(*keyPath)
	if err != nil {
		return err
	}
	var runner collector.QueryRunner = collector.NativeRunner{}
	if *fixturePath != "" {
		runner, err = collector.LoadFixture(*fixturePath)
		if err != nil {
			return err
		}
	}
	envelope, err := collectEnvelope(context.Background(), privateKey, *deviceID, *externalID, *offPremise, *version, *logPath, runner)
	if err != nil {
		return err
	}
	rawEnvelope, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	if *outputPath != "" {
		if err := writeEnvelope(*outputPath, envelope); err != nil {
			return err
		}
	} else {
		fmt.Println(string(rawEnvelope))
	}
	return nil
}

func post(args []string) error {
	flags := flag.NewFlagSet("posture", flag.ContinueOnError)
	url := flags.String("url", "", "agent API base URL")
	envelopePath := flags.String("envelope", "", "signed envelope file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *url == "" || *envelopePath == "" {
		return errors.New("--url and --envelope are required")
	}
	raw, err := os.ReadFile(*envelopePath)
	if err != nil {
		return fmt.Errorf("read signed posture: %w", err)
	}
	var envelope signing.Envelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return fmt.Errorf("decode signed posture: %w", err)
	}
	client, err := httpclient.New(*url)
	if err != nil {
		return err
	}
	var response map[string]any
	if err := client.Post(context.Background(), "/api/agent/v1/posture", envelope, &response); err != nil {
		return err
	}
	encoded, _ := json.Marshal(response)
	fmt.Println(string(encoded))
	return nil
}

func defaultPrivateKeyPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", ".config", "isms-agent", "device.key")
	}
	return filepath.Join(home, ".config", "isms-agent", "device.key")
}

func defaultLogPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", ".local", "state", "isms-agent", "posture.log")
	}
	return filepath.Join(home, ".local", "state", "isms-agent", "posture.log")
}

func encodeBase64(value []byte) string {
	return base64.StdEncoding.EncodeToString(value)
}
