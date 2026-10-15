// Opstation Print Helper — a tiny local service that lets the Opstation web
// app send labels straight to a label printer (TSC TE200 etc.) with no print
// dialog. Listens on 127.0.0.1:9123 only and accepts requests only from the
// Opstation web addresses.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const version = "1.1.0"
const addr = "127.0.0.1:9123"

var allowedOrigins = []string{
	"https://opstation-f06c7.web.app",
	"https://opstation-f06c7.firebaseapp.com",
}

type config struct {
	ExtraOrigins []string `json:"extra_origins"`
}

func appDir() string {
	base, err := os.UserConfigDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	d := filepath.Join(base, "OpstationPrint")
	_ = os.MkdirAll(d, 0o755)
	return d
}

func loadConfig() {
	b, err := os.ReadFile(filepath.Join(appDir(), "config.json"))
	if err != nil {
		return
	}
	var c config
	if json.Unmarshal(b, &c) == nil {
		allowedOrigins = append(allowedOrigins, c.ExtraOrigins...)
	}
}

func originAllowed(o string) bool {
	if o == "" {
		return false
	}
	if strings.HasPrefix(o, "http://localhost:") || strings.HasPrefix(o, "http://127.0.0.1:") {
		return true // local development of the web app
	}
	for _, a := range allowedOrigins {
		if strings.EqualFold(strings.TrimRight(a, "/"), o) {
			return true
		}
	}
	return false
}

func withCors(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		o := r.Header.Get("Origin")
		if !originAllowed(o) {
			http.Error(w, "origin not allowed", http.StatusForbidden)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", o)
		w.Header().Set("Vary", "Origin")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Private-Network", "true")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h(w, r)
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

type printReq struct {
	Printer string `json:"printer"`
	Data    string `json:"data"`
	JobName string `json:"job_name"`
}

func main() {
	// Double-clicked (no --background): install / start, show a message, exit.
	if handleInstall() {
		return
	}
	f, err := os.OpenFile(filepath.Join(appDir(), "helper.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		log.SetOutput(f)
	}
	loadConfig()

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("already running or port busy: %v", err)
		return // another copy is running — nothing to do
	}
	log.Printf("Opstation Print Helper %s listening on %s", version, addr)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, "<html><body style='font-family:sans-serif;padding:40px'><h2>Opstation Print Helper is running</h2><p>Version %s. You can close this tab and print labels from Opstation.</p></body></html>", version)
	})
	mux.HandleFunc("/health", withCors(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "version": version, "os": runtime.GOOS})
	}))
	mux.HandleFunc("/printers", withCors(func(w http.ResponseWriter, r *http.Request) {
		list, err := listPrinters()
		if err != nil {
			writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "printers": list})
	}))
	mux.HandleFunc("/print", withCors(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, 405, map[string]any{"ok": false, "error": "POST only"})
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		if err != nil {
			writeJSON(w, 400, map[string]any{"ok": false, "error": "could not read request"})
			return
		}
		var req printReq
		if err := json.Unmarshal(body, &req); err != nil || strings.TrimSpace(req.Printer) == "" || req.Data == "" {
			writeJSON(w, 400, map[string]any{"ok": false, "error": "printer and data are required"})
			return
		}
		if req.JobName == "" {
			req.JobName = "Opstation labels"
		}
		start := time.Now()
		if err := printRaw(req.Printer, req.JobName, []byte(req.Data)); err != nil {
			log.Printf("print to %q failed: %v", req.Printer, err)
			writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		log.Printf("printed %d bytes to %q in %s", len(req.Data), req.Printer, time.Since(start))
		writeJSON(w, 200, map[string]any{"ok": true})
	}))

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.Serve(ln); err != nil {
		log.Printf("server stopped: %v", err)
		fmt.Fprintln(os.Stderr, err)
	}
}
