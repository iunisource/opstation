// Opstation Print Helper — a tiny local service that lets the Opstation web
// app send labels straight to a label printer (TSC TE200 etc.) with no print
// dialog. Listens on 127.0.0.1:9123 only (never reachable from other PCs).
//
// Two ways in:
//  1. Opstation calls /print directly (fast, silent) when the browser allows it.
//  2. When the browser blocks that, Opstation opens /job#<data> in a small
//     window; that page (same origin as the helper) prints and closes itself.
//
// The printer is chosen on the helper's own page: http://127.0.0.1:9123
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
	"sync"
	"time"
)

const version = "1.3.0"
const addr = "127.0.0.1:9123"

// Used by the installer's own "is it running?" check.
var allowedOrigins = []string{"https://opstation-f06c7.web.app"}

type config struct {
	Printer string `json:"printer"`
}

var (
	cfgMu sync.Mutex
	cfg   config
)

func appDir() string {
	base, err := os.UserConfigDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	d := filepath.Join(base, "OpstationPrint")
	_ = os.MkdirAll(d, 0o755)
	return d
}

func cfgPath() string { return filepath.Join(appDir(), "config.json") }

func loadConfig() {
	b, err := os.ReadFile(cfgPath())
	if err != nil {
		return
	}
	cfgMu.Lock()
	_ = json.Unmarshal(b, &cfg)
	cfgMu.Unlock()
}

func saveConfig(c config) error {
	cfgMu.Lock()
	cfg = c
	cfgMu.Unlock()
	b, _ := json.MarshalIndent(c, "", "  ")
	return os.WriteFile(cfgPath(), b, 0o644)
}

func defaultPrinter() string {
	cfgMu.Lock()
	defer cfgMu.Unlock()
	return cfg.Printer
}

// Any caller is accepted: the helper only listens on this PC and can only
// print labels. CORS headers are added for browser calls from Opstation.
func withCors(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		o := r.Header.Get("Origin")
		log.Printf("%s %s from %q", r.Method, r.URL.Path, o)
		if o != "" {
			w.Header().Set("Access-Control-Allow-Origin", o)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Access-Control-Allow-Private-Network", "true")
		}
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
		return
	}
	log.Printf("Opstation Print Helper %s listening on %s", version, addr)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, strings.ReplaceAll(setupPage, "{{VERSION}}", version))
	})
	mux.HandleFunc("/job", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, jobPage)
	})
	mux.HandleFunc("/health", withCors(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "version": version, "os": runtime.GOOS, "printer": defaultPrinter()})
	}))
	mux.HandleFunc("/printers", withCors(func(w http.ResponseWriter, r *http.Request) {
		list, err := listPrinters()
		if err != nil {
			writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "printers": list, "default": defaultPrinter()})
	}))
	mux.HandleFunc("/config", withCors(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, 200, map[string]any{"ok": true, "printer": defaultPrinter()})
			return
		}
		var c config
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&c); err != nil {
			writeJSON(w, 400, map[string]any{"ok": false, "error": "bad request"})
			return
		}
		if err := saveConfig(c); err != nil {
			writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true})
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
		if err := json.Unmarshal(body, &req); err != nil || req.Data == "" {
			writeJSON(w, 400, map[string]any{"ok": false, "error": "nothing to print"})
			return
		}
		printer := strings.TrimSpace(req.Printer)
		if printer == "" {
			printer = defaultPrinter()
		}
		if printer == "" {
			writeJSON(w, 400, map[string]any{"ok": false, "error": "No label printer chosen yet. Open http://127.0.0.1:9123 and pick it."})
			return
		}
		if req.JobName == "" {
			req.JobName = "Opstation labels"
		}
		start := time.Now()
		if err := printRaw(printer, req.JobName, []byte(req.Data)); err != nil {
			log.Printf("print to %q failed: %v", printer, err)
			writeJSON(w, 500, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		log.Printf("printed %d bytes to %q in %s", len(req.Data), printer, time.Since(start))
		writeJSON(w, 200, map[string]any{"ok": true, "printer": printer})
	}))

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.Serve(ln); err != nil {
		log.Printf("server stopped: %v", err)
	}
}

const pageStyle = `<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f4f6fa;margin:0;padding:32px;color:#1f2937}
.card{max-width:520px;margin:0 auto;background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:24px}
h2{margin:0 0 4px} .muted{color:#6b7280;font-size:13px}
select,button{font-size:15px;padding:9px 12px;border-radius:8px;border:1px solid #cbd5e1}
button{background:#2563eb;color:#fff;border:0;cursor:pointer} button.sec{background:#fff;color:#2563eb;border:1px solid #2563eb}
.ok{color:#15803d;font-weight:600} .err{color:#b91c1c;font-weight:600}
</style>`

const setupPage = `<!doctype html><html><head><meta charset="utf-8"><title>Opstation Print Helper</title>` + pageStyle + `</head><body><div class="card">
<h2>Opstation Print Helper</h2><div class="muted">Running · version {{VERSION}}</div>
<p style="margin-top:20px"><b>Label printer</b></p>
<select id="p" style="width:100%"></select>
<p style="display:flex;gap:8px;margin-top:14px"><button onclick="save()">Save</button><button class="sec" onclick="test()">Test print</button></p>
<div id="msg" class="muted"></div>
<p class="muted" style="margin-top:22px">Opstation prints to the printer saved here. You can close this tab.</p>
</div><script>
const msg=(t,c)=>{const m=document.getElementById('msg');m.textContent=t;m.className=c||'muted'};
fetch('/printers').then(r=>r.json()).then(j=>{const s=document.getElementById('p');
 (j.printers||[]).forEach(n=>{const o=document.createElement('option');o.value=o.textContent=n;s.appendChild(o)});
 if(j.default){s.value=j.default}else{const t=(j.printers||[]).find(n=>/tsc|te200/i.test(n));if(t)s.value=t}
 if(!(j.printers||[]).length)msg('No printers found. Install the TSC driver first.','err')});
async function save(){const r=await fetch('/config',{method:'POST',body:JSON.stringify({printer:document.getElementById('p').value})});
 const j=await r.json();msg(j.ok?'Saved.':j.error,j.ok?'ok':'err')}
async function test(){await save();const d='SIZE 38.1 mm,25.4 mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 1,0\r\nCLS\r\nTEXT 10,10,"3",0,1,1,"Opstation test"\r\nBARCODE 10,50,"128",60,1,0,2,2,"TEST-123"\r\nPRINT 1,1\r\n';
 const r=await fetch('/print',{method:'POST',body:JSON.stringify({data:d,job_name:'Opstation test'})});const j=await r.json();
 msg(j.ok?'Test label sent to '+j.printer+'.':j.error,j.ok?'ok':'err')}
</script></body></html>`

const jobPage = `<!doctype html><html><head><meta charset="utf-8"><title>Printing labels…</title>` + pageStyle + `</head><body><div class="card">
<h2 id="h">Printing labels…</h2><div id="msg" class="muted">Sending to the label printer.</div>
<p id="setup" style="display:none;margin-top:16px"><a href="/">Choose the label printer</a></p>
</div><script>
(async()=>{const msg=(t,c)=>{const m=document.getElementById('msg');m.textContent=t;m.className=c||'muted'};
try{const raw=decodeURIComponent(escape(atob(location.hash.slice(1).replace(/-/g,'+').replace(/_/g,'/'))));
 history.replaceState(null,'',location.pathname);
 const r=await fetch('/print',{method:'POST',body:raw});const j=await r.json();
 if(j.ok){document.getElementById('h').textContent='Printed';msg('Sent to '+j.printer+'. This window closes by itself.','ok');setTimeout(()=>window.close(),1500)}
 else{document.getElementById('h').textContent='Not printed';msg(j.error,'err');document.getElementById('setup').style.display='block'}
}catch(e){document.getElementById('h').textContent='Not printed';msg('Nothing to print ('+e+').','err')}})();
</script></body></html>`
