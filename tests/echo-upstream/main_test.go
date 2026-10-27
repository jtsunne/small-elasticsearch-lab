package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rawRequest(t *testing.T, addr, req string) (*http.Response, []byte) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, body
}

func decodeOne(t *testing.T, b []byte) Record {
	t.Helper()
	var rec Record
	if err := json.Unmarshal(bytes.TrimSpace(b), &rec); err != nil {
		t.Fatalf("not one JSON record: %v: %q", err, b)
	}
	return rec
}

func TestRawTargetIsKeptEncoded(t *testing.T) {
	var logBuf bytes.Buffer
	srv := httptest.NewServer(newHandler(&logBuf))
	defer srv.Close()
	addr := strings.TrimPrefix(srv.URL, "http://")

	cases := []struct {
		target, path string
	}{
		{"/app%2Da/%5Fsearch", "/app-a/_search"},
		{"/app-a%252Csecret/_search", "/app-a%2Csecret/_search"},
		{"/app-a/../_cluster/settings", "/app-a/../_cluster/settings"},
		{"//_cluster/settings?pretty", "//_cluster/settings"},
	}
	for _, c := range cases {
		resp, body := rawRequest(t, addr, "GET "+c.target+" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
		if resp.StatusCode != 200 {
			t.Fatalf("%s: status %d", c.target, resp.StatusCode)
		}
		if resp.Header.Get(MarkerHeader) != "1" {
			t.Fatalf("%s: marker header missing", c.target)
		}
		rec := decodeOne(t, body)
		if rec.RequestURI != c.target {
			t.Errorf("request_uri = %q, want %q", rec.RequestURI, c.target)
		}
		if rec.Path != c.path {
			t.Errorf("path = %q, want %q", rec.Path, c.path)
		}
		if want := "GET " + c.target + " HTTP/1.1"; rec.RequestLine != want {
			t.Errorf("request_line = %q, want %q", rec.RequestLine, want)
		}
	}
	lines := strings.Split(strings.TrimSpace(logBuf.String()), "\n")
	if len(lines) != len(cases) {
		t.Fatalf("log has %d lines, want %d", len(lines), len(cases))
	}
}

func TestAbsoluteFormAndHTTP10(t *testing.T) {
	var logBuf bytes.Buffer
	srv := httptest.NewServer(newHandler(&logBuf))
	defer srv.Close()
	addr := strings.TrimPrefix(srv.URL, "http://")

	_, body := rawRequest(t, addr, "GET http://es01:9200/_cluster/settings HTTP/1.1\r\nHost: es01:9200\r\nConnection: close\r\n\r\n")
	rec := decodeOne(t, body)
	if rec.RequestURI != "http://es01:9200/_cluster/settings" || rec.Path != "/_cluster/settings" {
		t.Errorf("absolute form: %+v", rec)
	}

	_, body = rawRequest(t, addr, "GET /app-a/_count HTTP/1.0\r\n\r\n")
	rec = decodeOne(t, body)
	if rec.Proto != "HTTP/1.0" {
		t.Errorf("proto = %q, want HTTP/1.0", rec.Proto)
	}
}

func TestBodyAndHeaders(t *testing.T) {
	var logBuf bytes.Buffer
	srv := httptest.NewServer(newHandler(&logBuf))
	defer srv.Close()

	body := strings.Repeat("x", 12345)
	req, err := http.NewRequest(http.MethodPost, srv.URL+"/app-a/_bulk", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-HTTP-Method-Override", "DELETE")
	req.Header.Set("X-Matrix-Id", "t1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	rec := decodeOne(t, got)
	if rec.Method != "POST" || rec.BodyBytes != int64(len(body)) {
		t.Errorf("method %q body %d", rec.Method, rec.BodyBytes)
	}
	if v := rec.Headers["X-Http-Method-Override"]; len(v) != 1 || v[0] != "DELETE" {
		t.Errorf("override header: %v", rec.Headers)
	}
	if v := rec.Headers["X-Matrix-Id"]; len(v) != 1 || v[0] != "t1" {
		t.Errorf("matrix id header: %v", rec.Headers)
	}
	if strings.TrimSpace(logBuf.String()) != strings.TrimSpace(string(got)) {
		t.Errorf("log line and response differ")
	}
}

func TestRunWritesAddrFileAndLog(t *testing.T) {
	dir := t.TempDir()
	addrFile := filepath.Join(dir, "addr")
	logPath := filepath.Join(dir, "requests.jsonl")
	errc := make(chan error, 1)
	go func() { errc <- run("127.0.0.1:0", addrFile, logPath) }()

	var addr string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(addrFile)
		if err == nil {
			addr = strings.TrimSpace(string(b))
			break
		}
		select {
		case err := <-errc:
			t.Fatalf("run exited early: %v", err)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if addr == "" {
		t.Fatal("addr file never appeared")
	}
	resp, _ := rawRequest(t, addr, "GET /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if rec := decodeOne(t, b); rec.RequestURI != "/x" {
		t.Errorf("log record %+v", rec)
	}
}
