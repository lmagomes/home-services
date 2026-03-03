package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"text/template"
	"time"

	"gopkg.in/yaml.v3"
)

// Config represents the webhook receiver configuration.
type Config struct {
	RepoOwner  string             `yaml:"repo_owner"`
	RepoName   string             `yaml:"repo_name"`
	BaseBranch string             `yaml:"base_branch"`
	Services   map[string]Service `yaml:"services"`
}

// Service maps an Argus service to one or more container files.
type Service struct {
	Containers []Container `yaml:"containers"`
}

// Container represents a container file to update.
type Container struct {
	File        string `yaml:"file"`
	TagTemplate string `yaml:"tag_template"`
}

// forgejoClient handles all Forgejo API interactions.
type forgejoClient struct {
	baseURL string
	token   string
	owner   string
	repo    string
	client  *http.Client
}

func main() {
	configPath := envOrDefault("CONFIG_PATH", "/app/config.yml")
	listenAddr := envOrDefault("LISTEN_ADDR", ":8080")
	forgejoURL := mustEnv("FORGEJO_URL")
	forgejoToken := mustEnv("FORGEJO_TOKEN")
	webhookSecret := os.Getenv("WEBHOOK_SECRET") // optional

	cfg, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	fc := &forgejoClient{
		baseURL: strings.TrimRight(forgejoURL, "/"),
		token:   forgejoToken,
		owner:   cfg.RepoOwner,
		repo:    cfg.RepoName,
		client:  &http.Client{Timeout: 30 * time.Second},
	}

	http.HandleFunc("/webhook", handleWebhook(cfg, fc, webhookSecret))
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	log.Printf("update-webhook listening on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

// handleWebhook returns an HTTP handler that processes Argus webhook calls.
func handleWebhook(cfg *Config, fc *forgejoClient, secret string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Read body for signature verification
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}

		// Verify HMAC signature if secret is configured
		if secret != "" {
			sig := r.Header.Get("X-Hub-Signature-256")
			if sig == "" {
				sig = r.Header.Get("X-Hub-Signature")
			}
			if !verifySignature(body, sig, secret) {
				log.Printf("webhook signature verification failed")
				http.Error(w, "invalid signature", http.StatusUnauthorized)
				return
			}
		}

		serviceID := r.Header.Get("X-Service")
		version := r.Header.Get("X-Version")

		if serviceID == "" || version == "" {
			http.Error(w, "missing X-Service or X-Version header", http.StatusBadRequest)
			return
		}

		svc, ok := cfg.Services[serviceID]
		if !ok {
			log.Printf("unknown service: %s", serviceID)
			http.Error(w, fmt.Sprintf("unknown service: %s", serviceID), http.StatusNotFound)
			return
		}

		log.Printf("received update for %s → %s", serviceID, version)

		if err := processUpdate(fc, cfg.BaseBranch, serviceID, version, svc); err != nil {
			log.Printf("ERROR processing update for %s: %v", serviceID, err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "PR created for %s %s\n", serviceID, version)
	}
}

// processUpdate orchestrates the Forgejo API calls to create a PR.
func processUpdate(fc *forgejoClient, baseBranch, serviceID, version string, svc Service) error {
	// Build branch name: updates/monitor-dozzle-20260303
	safeName := strings.ReplaceAll(serviceID, "/", "-")
	date := time.Now().Format("20060102")
	branch := fmt.Sprintf("updates/%s-%s", safeName, date)

	// 1. Create branch
	log.Printf("creating branch %s from %s", branch, baseBranch)
	if err := fc.createBranch(branch, baseBranch); err != nil {
		return fmt.Errorf("create branch: %w", err)
	}

	// 2. Update each container file
	containerUpdates := []string{}
	for _, c := range svc.Containers {
		tag, err := renderTag(c.TagTemplate, version)
		if err != nil {
			return fmt.Errorf("render tag template for %s: %w", c.File, err)
		}

		log.Printf("updating %s → image tag %s", c.File, tag)
		if err := fc.updateContainerFile(c.File, branch, tag); err != nil {
			return fmt.Errorf("update file %s: %w", c.File, err)
		}

		// Extract container name from path for PR title
		parts := strings.Split(c.File, "/")
		containerName := strings.TrimSuffix(parts[len(parts)-1], ".container")
		containerUpdates = append(containerUpdates, fmt.Sprintf("%s=%s", containerName, tag))
	}

	// 3. Create PR
	// Extract quadlet group from service ID (e.g., "monitor" from "monitor/dozzle")
	group := strings.Split(serviceID, "/")[0]
	title := fmt.Sprintf("Update %s: %s", group, strings.Join(containerUpdates, ", "))

	log.Printf("creating PR: %s", title)
	if err := fc.createPR(title, branch, baseBranch); err != nil {
		return fmt.Errorf("create PR: %w", err)
	}

	log.Printf("successfully created PR for %s %s", serviceID, version)
	return nil
}

// updateContainerFile fetches a file from Forgejo, replaces the Image= tag, and updates it.
func (fc *forgejoClient) updateContainerFile(filePath, branch, newTag string) error {
	// GET current file content
	content, sha, err := fc.getFileContent(filePath, branch)
	if err != nil {
		return fmt.Errorf("get file: %w", err)
	}

	// Replace the Image= line tag
	re := regexp.MustCompile(`(?m)^(Image=.*:)(.+)$`)
	if !re.MatchString(content) {
		return fmt.Errorf("no Image= line found in %s", filePath)
	}
	updated := re.ReplaceAllString(content, "${1}"+newTag)

	if updated == content {
		log.Printf("no change needed for %s (already at %s)", filePath, newTag)
		return nil
	}

	// PUT updated file
	return fc.updateFile(filePath, branch, updated, sha,
		fmt.Sprintf("update %s image tag to %s", filePath, newTag))
}

// --- Forgejo API methods ---

func (fc *forgejoClient) createBranch(name, from string) error {
	payload := map[string]string{
		"new_branch_name":  name,
		"old_branch_name":  from,
	}
	_, err := fc.apiCall("POST",
		fmt.Sprintf("/api/v1/repos/%s/%s/branches", fc.owner, fc.repo),
		payload)
	return err
}

func (fc *forgejoClient) getFileContent(path, ref string) (content, sha string, err error) {
	respBody, err := fc.apiCall("GET",
		fmt.Sprintf("/api/v1/repos/%s/%s/contents/%s?ref=%s", fc.owner, fc.repo, path, ref),
		nil)
	if err != nil {
		return "", "", err
	}

	var result struct {
		Content  string `json:"content"`
		SHA      string `json:"sha"`
		Encoding string `json:"encoding"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", "", fmt.Errorf("parse response: %w", err)
	}

	decoded, err := base64.StdEncoding.DecodeString(result.Content)
	if err != nil {
		return "", "", fmt.Errorf("decode content: %w", err)
	}

	return string(decoded), result.SHA, nil
}

func (fc *forgejoClient) updateFile(path, branch, content, sha, message string) error {
	payload := map[string]interface{}{
		"content":    base64.StdEncoding.EncodeToString([]byte(content)),
		"sha":        sha,
		"branch":     branch,
		"message":    message,
	}
	_, err := fc.apiCall("PUT",
		fmt.Sprintf("/api/v1/repos/%s/%s/contents/%s", fc.owner, fc.repo, path),
		payload)
	return err
}

func (fc *forgejoClient) createPR(title, head, base string) error {
	payload := map[string]string{
		"title": title,
		"head":  head,
		"base":  base,
	}
	_, err := fc.apiCall("POST",
		fmt.Sprintf("/api/v1/repos/%s/%s/pulls", fc.owner, fc.repo),
		payload)
	return err
}

func (fc *forgejoClient) apiCall(method, path string, payload interface{}) ([]byte, error) {
	var bodyReader io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("marshal payload: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	url := fc.baseURL + path
	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Authorization", "token "+fc.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := fc.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("API %s %s returned %d: %s", method, path, resp.StatusCode, string(respBody))
	}

	return respBody, nil
}

// --- Helpers ---

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.BaseBranch == "" {
		cfg.BaseBranch = "main"
	}
	return &cfg, nil
}

func renderTag(tmplStr, version string) (string, error) {
	tmpl, err := template.New("tag").Parse(tmplStr)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, struct{ Version string }{version}); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func verifySignature(body []byte, signature, secret string) bool {
	if signature == "" {
		return false
	}
	// Strip "sha256=" prefix
	signature = strings.TrimPrefix(signature, "sha256=")
	signature = strings.TrimPrefix(signature, "sha1=")

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	expected := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(signature))
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required environment variable %s is not set", key)
	}
	return v
}
