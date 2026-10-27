// Command echo-upstream stands in for Elasticsearch or OpenSearch behind
// Caddy in the proxy matrix. It answers every request with 200 and a JSON
// record of what arrived: method, the request-target exactly as it appeared
// on the request line, the decoded path for comparison, headers and body
// length. The same record is appended as one JSON line to the log, so the
// matrix can prove what reached the upstream, not only what the client got.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// Record is one request as seen by the upstream.
type Record struct {
	Time        string              `json:"time"`
	RemoteAddr  string              `json:"remote_addr"`
	RequestLine string              `json:"request_line"`
	Method      string              `json:"method"`
	RequestURI  string              `json:"request_uri"`
	Proto       string              `json:"proto"`
	Path        string              `json:"path"`
	Host        string              `json:"host"`
	Headers     map[string][]string `json:"headers"`
	BodyBytes   int64               `json:"body_bytes"`
	BodyError   string              `json:"body_error,omitempty"`
}

// MarkerHeader is set on every echo response so a client can tell an
// upstream answer from one Caddy generated itself.
const MarkerHeader = "X-Echo-Upstream"

type handler struct {
	mu  sync.Mutex
	log io.Writer
}

func newHandler(logw io.Writer) http.Handler {
	return &handler{log: logw}
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	n, err := io.Copy(io.Discard, r.Body)
	// net/http copies the request-target into RequestURI unmodified; r.URL
	// is the parsed and decoded form. Keeping both is the point of this
	// server: they differ exactly when a proxy forwards an encoded path.
	rec := Record{
		Time:        time.Now().UTC().Format(time.RFC3339Nano),
		RemoteAddr:  r.RemoteAddr,
		RequestLine: r.Method + " " + r.RequestURI + " " + r.Proto,
		Method:      r.Method,
		RequestURI:  r.RequestURI,
		Proto:       r.Proto,
		Path:        r.URL.Path,
		Host:        r.Host,
		Headers:     r.Header,
		BodyBytes:   n,
	}
	if err != nil {
		rec.BodyError = err.Error()
	}
	line, merr := json.Marshal(rec)
	if merr != nil {
		http.Error(w, merr.Error(), http.StatusInternalServerError)
		return
	}
	h.mu.Lock()
	_, werr := h.log.Write(append(line, '\n'))
	h.mu.Unlock()
	if werr != nil {
		http.Error(w, werr.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set(MarkerHeader, "1")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(append(line, '\n'))
}

func run(listen, addrFile, logPath string) error {
	logw := io.Writer(os.Stderr)
	if logPath != "" {
		f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		logw = f
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	if addrFile != "" {
		// Written to a temp name and renamed so a poller never reads a
		// half-written address.
		tmp := addrFile + ".tmp"
		if err := os.WriteFile(tmp, []byte(ln.Addr().String()+"\n"), 0o644); err != nil {
			ln.Close()
			return err
		}
		if err := os.Rename(tmp, addrFile); err != nil {
			ln.Close()
			return err
		}
	}
	srv := &http.Server{
		Handler:           newHandler(logw),
		ReadHeaderTimeout: 10 * time.Second,
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		_ = srv.Close()
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "address to listen on; port 0 picks a free port")
	addrFile := flag.String("addr-file", "", "write the bound address to this file once listening")
	logPath := flag.String("log", "", "append one JSON record per request to this file (default stderr)")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "usage: echo-upstream [-listen addr] [-addr-file path] [-log path]\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if err := run(*listen, *addrFile, *logPath); err != nil {
		log.Fatal(err)
	}
}
