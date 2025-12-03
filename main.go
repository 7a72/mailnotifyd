package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/joho/godotenv"
)

//
// ========= Stalwart MTA Hook Request Structure =========
//

type Context struct {
	Stage string `json:"stage"`
	Queue *struct {
		ID string `json:"id"`
	} `json:"queue,omitempty"`
}

type Envelope struct {
	From struct {
		Address string `json:"address"`
	} `json:"from"`

	To []struct {
		Address string `json:"address"`
	} `json:"to"`
}

type Message struct {
	Headers  [][]string `json:"headers"`
	Contents string     `json:"contents"`
}

type MTARequest struct {
	Context  Context  `json:"context"`
	Envelope Envelope `json:"envelope"`
	Message  Message  `json:"message"`
}

//
// ========= Notifier Configuration =========
//

type NotifierConfig struct {
	// Authentication
	AuthToken string

	// Telegram
	TelegramBotToken string
	TelegramChatID   string

	// ntfy
	NtfyServer string // e.g., https://ntfy.sh
	NtfyTopic  string // e.g., my-email-alerts
	NtfyToken  string // optional auth token

	// DingTalk
	DingTalkWebhook string // DingTalk robot webhook URL
	DingTalkSecret  string // DingTalk robot signature secret (optional)

	// Channel Control
	EnabledChannels []string // telegram, ntfy, dingtalk

	// General Configuration
	BindAddr     string
	AllowedRcpts []string
}

var config NotifierConfig

//
// ========= Notifier Interface =========
//

type Notifier interface {
	Send(from, to, subject string) error
	Name() string
	ChannelID() string // Returns channel identifier
}

//
// ========= Telegram Notifier =========
//

type TelegramNotifier struct {
	botToken string
	chatID   string
}

func (t *TelegramNotifier) Name() string {
	return "Telegram"
}

func (t *TelegramNotifier) ChannelID() string {
	return "telegram"
}

func (t *TelegramNotifier) Send(from, to, subject string) error {
	text := fmt.Sprintf(
		"📧 New Email Received\nFrom: %s\nTo: %s\nSubject: %s",
		from, to, subject,
	)

	body := map[string]string{
		"chat_id": t.chatID,
		"text":    text,
	}

	bs, _ := json.Marshal(body)
	client := &http.Client{Timeout: 5 * time.Second}

	req, _ := http.NewRequest(
		"POST",
		"https://api.telegram.org/bot"+t.botToken+"/sendMessage",
		bytes.NewReader(bs),
	)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("telegram status: %s", resp.Status)
	}
	return nil
}

//
// ========= ntfy Notifier =========
//

type NtfyNotifier struct {
	server string
	topic  string
	token  string
}

func (n *NtfyNotifier) Name() string {
	return "ntfy"
}

func (n *NtfyNotifier) ChannelID() string {
	return "ntfy"
}

func (n *NtfyNotifier) Send(from, to, subject string) error {
	urlStr := fmt.Sprintf("%s/%s", strings.TrimRight(n.server, "/"), n.topic)

	message := fmt.Sprintf("From: %s\nTo: %s", from, to)

	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("POST", urlStr, strings.NewReader(message))
	if err != nil {
		return err
	}

	// Set title and priority
	req.Header.Set("Title", subject)
	req.Header.Set("Priority", "default")
	req.Header.Set("Tags", "email,incoming")

	// Add authentication if token is configured
	if n.token != "" {
		req.Header.Set("Authorization", "Bearer "+n.token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("ntfy status: %s", resp.Status)
	}
	return nil
}

//
// ========= DingTalk Notifier =========
//

type DingTalkNotifier struct {
	webhook string
	secret  string
}

func (d *DingTalkNotifier) Name() string {
	return "DingTalk"
}

func (d *DingTalkNotifier) ChannelID() string {
	return "dingtalk"
}

func (d *DingTalkNotifier) Send(from, to, subject string) error {
	text := fmt.Sprintf(
		"📧 New Email Received\n\nFrom: %s\nTo: %s\nSubject: %s",
		from, to, subject,
	)

	// Build request body
	body := map[string]interface{}{
		"msgtype": "text",
		"text": map[string]string{
			"content": text,
		},
	}

	bs, _ := json.Marshal(body)

	// Build URL (with signature if configured)
	webhookURL := d.webhook
	if d.secret != "" {
		timestamp := time.Now().UnixMilli()
		sign := d.generateSign(timestamp)

		u, err := url.Parse(d.webhook)
		if err != nil {
			return fmt.Errorf("invalid dingtalk webhook url: %w", err)
		}

		q := u.Query()
		q.Set("timestamp", strconv.FormatInt(timestamp, 10))
		q.Set("sign", sign)
		u.RawQuery = q.Encode()
		webhookURL = u.String()
	}

	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("POST", webhookURL, bytes.NewReader(bs))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("dingtalk status: %s", resp.Status)
	}

	// Check DingTalk error code
	var result struct {
		ErrCode int    `json:"errcode"`
		ErrMsg  string `json:"errmsg"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return err
	}

	if result.ErrCode != 0 {
		return fmt.Errorf("dingtalk error: %s", result.ErrMsg)
	}

	return nil
}

// DingTalk signature generation
func (d *DingTalkNotifier) generateSign(timestamp int64) string {
	stringToSign := fmt.Sprintf("%d\n%s", timestamp, d.secret)
	h := hmac.New(sha256.New, []byte(d.secret))
	h.Write([]byte(stringToSign))
	signature := base64.StdEncoding.EncodeToString(h.Sum(nil))
	return url.QueryEscape(signature)
}

//
// ========= Main Program =========
//

func main() {
	_ = godotenv.Load()

	// Load configuration
	config = NotifierConfig{
		AuthToken:        os.Getenv("AUTH_TOKEN"),
		TelegramBotToken: os.Getenv("TELEGRAM_BOT_TOKEN"),
		TelegramChatID:   os.Getenv("TELEGRAM_CHAT_ID"),
		NtfyServer:       os.Getenv("NTFY_SERVER"),
		NtfyTopic:        os.Getenv("NTFY_TOPIC"),
		NtfyToken:        os.Getenv("NTFY_TOKEN"),
		DingTalkWebhook:  os.Getenv("DINGTALK_WEBHOOK"),
		DingTalkSecret:   os.Getenv("DINGTALK_SECRET"),
		BindAddr:         os.Getenv("BIND_ADDR"),
	}

	if config.BindAddr == "" {
		config.BindAddr = ":8000"
	}

	// Parse enabled channels
	enabledChannelsEnv := os.Getenv("ENABLED_CHANNELS")
	if enabledChannelsEnv != "" {
		for _, ch := range strings.Split(enabledChannelsEnv, ",") {
			ch = strings.ToLower(strings.TrimSpace(ch))
			if ch != "" {
				config.EnabledChannels = append(config.EnabledChannels, ch)
			}
		}
	}

	// Parse allowed recipients
	allowedEnv := os.Getenv("ALLOWED_RCPTS")
	if allowedEnv != "" {
		for _, v := range strings.Split(allowedEnv, ",") {
			v = strings.ToLower(strings.TrimSpace(v))
			if v != "" {
				config.AllowedRcpts = append(config.AllowedRcpts, v)
			}
		}
	}

	// Initialize notifiers
	notifiers := initNotifiers()
	if len(notifiers) == 0 {
		log.Fatal("At least one notification channel must be configured (Telegram/ntfy/DingTalk)")
	}

	// Log startup information
	log.Printf("===========================================")
	log.Printf("Email Notification Service Started")
	log.Printf("===========================================")

	if config.AuthToken != "" {
		log.Printf("✓ Authentication: Enabled (Token: %s)", maskToken(config.AuthToken))
	} else {
		log.Printf("⚠ Authentication: Disabled (Recommended for production)")
	}

	log.Printf("✓ Enabled Notification Channels (%d):", len(notifiers))
	for _, n := range notifiers {
		log.Printf("  - %s", n.Name())
	}

	if len(config.EnabledChannels) > 0 {
		log.Printf("✓ Channel Filter: %v", config.EnabledChannels)
	} else {
		log.Printf("✓ Channel Filter: All available channels")
	}

	if len(config.AllowedRcpts) > 0 {
		log.Printf("✓ Recipient Whitelist: %v", config.AllowedRcpts)
	} else {
		log.Printf("✓ Recipient Whitelist: All emails")
	}

	log.Printf("✓ Listen Address: %s", config.BindAddr)
	log.Printf("===========================================")

	http.HandleFunc("/", makeHandler(notifiers))
	http.HandleFunc("/health", healthHandler)

	if err := http.ListenAndServe(config.BindAddr, nil); err != nil {
		log.Fatal(err)
	}
}

//
// ========= Initialize Notifiers =========
//

func initNotifiers() []Notifier {
	var allNotifiers []Notifier

	// Telegram
	if config.TelegramBotToken != "" && config.TelegramChatID != "" {
		allNotifiers = append(allNotifiers, &TelegramNotifier{
			botToken: config.TelegramBotToken,
			chatID:   config.TelegramChatID,
		})
	}

	// ntfy
	if config.NtfyTopic != "" {
		server := config.NtfyServer
		if server == "" {
			server = "https://ntfy.sh"
		}
		allNotifiers = append(allNotifiers, &NtfyNotifier{
			server: server,
			topic:  config.NtfyTopic,
			token:  config.NtfyToken,
		})
	}

	// DingTalk
	if config.DingTalkWebhook != "" {
		allNotifiers = append(allNotifiers, &DingTalkNotifier{
			webhook: config.DingTalkWebhook,
			secret:  config.DingTalkSecret,
		})
	}

	// Filter notifiers if ENABLED_CHANNELS is set
	if len(config.EnabledChannels) > 0 {
		var filtered []Notifier
		enabledMap := make(map[string]bool)
		for _, ch := range config.EnabledChannels {
			enabledMap[ch] = true
		}

		for _, n := range allNotifiers {
			if enabledMap[n.ChannelID()] {
				filtered = append(filtered, n)
			}
		}
		return filtered
	}

	return allNotifiers
}

//
// ========= HTTP Handler =========
//

func makeHandler(notifiers []Notifier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Authentication check（Bearer 大小写不敏感）
		if config.AuthToken != "" {
			authHeader := r.Header.Get("Authorization")
			token := strings.TrimSpace(authHeader)

			if len(token) >= 7 && strings.EqualFold(token[:7], "Bearer ") {
				token = strings.TrimSpace(token[7:])
			}

			if token != config.AuthToken {
				log.Printf("[WARN] Authentication failed, source: %s", r.RemoteAddr)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}

		// ✅ 通过方法 + 鉴权之后，第一时间返回「同意」
		writeAccept(w)

		// 后续所有错误只记日志，不影响上面的响应

		// 在 handler 里把请求体读出来，避免在 goroutine 中访问 r.Body
		bodyBytes, err := io.ReadAll(r.Body)
		if err != nil {
			log.Printf("[ERROR] Read body failed: %v", err)
			return
		}

		// 后续解析和通知放到后台 goroutine，完全用已读好的 body
		go func(b []byte) {
			var payload MTARequest
			if err := json.Unmarshal(b, &payload); err != nil {
				log.Printf("[ERROR] Decode payload failed: %v", err)
				return
			}
			processPayload(notifiers, payload)
		}(bodyBytes)
	}
}

//
// ========= Health Check =========
//

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "ok",
		"time":    time.Now().Format(time.RFC3339),
		"version": "1.0.0",
	})
}

//
// ========= Concurrent Notification Sending =========
//

func sendToAllChannels(notifiers []Notifier, from, to, subject string) {
	var wg sync.WaitGroup

	for _, notifier := range notifiers {
		wg.Add(1)
		go func(n Notifier) {
			defer wg.Done()

			err := n.Send(from, to, subject)
			if err != nil {
				log.Printf("[ERROR] %s notification failed: %v", n.Name(), err)
			} else {
				log.Printf("[INFO] %s notification sent successfully", n.Name())
			}
		}(notifier)
	}

	wg.Wait()
}

//
// ========= Payload Processing =========
//

func processPayload(notifiers []Notifier, payload MTARequest) {
	envelope := payload.Envelope
	headers := payload.Message.Headers

	fullFrom := extractFull(headers, "From")
	if fullFrom == "" {
		fullFrom = envelope.From.Address
	}

	fullTo := extractFull(headers, "To")
	subject := extractFull(headers, "Subject")

	// Recipient filtering
	if len(config.AllowedRcpts) > 0 {
		match := false
		for _, t := range envelope.To {
			addr := strings.ToLower(strings.TrimSpace(t.Address))
			for _, a := range config.AllowedRcpts {
				if addr == a {
					match = true
					break
				}
			}
			if match {
				break
			}
		}

		if !match {
			log.Printf("[INFO] Skipped email for non-whitelisted recipient")
			return
		}
	}

	// Send to all channels concurrently
	sendToAllChannels(notifiers, fullFrom, fullTo, subject)
}

//
// ========= Utility Functions =========
//

func extractFull(headers [][]string, key string) string {
	for _, h := range headers {
		if len(h) >= 2 && strings.EqualFold(h[0], key) {
			return h[1]
		}
	}
	return ""
}

func writeAccept(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"action": "accept"})
}

func maskToken(token string) string {
	if len(token) <= 8 {
		return "****"
	}
	return token[:4] + "****" + token[len(token)-4:]
}
