package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testClient(t *testing.T, url string, maxRetries int) *Client {
	t.Helper()
	c, err := NewClient(ClientConfig{URL: url, User: "u", Password: "p", Connections: 4, Timeout: 5 * time.Second, MaxRetries: maxRetries})
	if err != nil {
		t.Fatal(err)
	}
	c.sleep = func(ctx context.Context, d time.Duration) error { return ctx.Err() }
	return c
}

func docs(n int, f func(i int) string) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		b.WriteString(f(i))
		b.WriteString("\n")
	}
	return b.String()
}

// parseBulk returns the document lines of an NDJSON bulk body and checks that
// every document follows an action line.
func parseBulk(t *testing.T, body []byte) []string {
	t.Helper()
	var out []string
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		action := sc.Text()
		if action != `{"index":{}}` && action != `{"create":{}}` {
			t.Errorf("unexpected action line %q", action)
		}
		if !sc.Scan() {
			t.Fatalf("action without document")
		}
		out = append(out, sc.Text())
	}
	if len(body) == 0 || body[len(body)-1] != '\n' {
		t.Errorf("bulk body must end with a newline")
	}
	return out
}

func bulkItems(op string, statuses []int, errType string) []byte {
	items := make([]map[string]any, len(statuses))
	errs := false
	for i, s := range statuses {
		it := map[string]any{"status": s}
		if s >= 300 {
			errs = true
			typ := errType
			if s == 429 {
				typ = "es_rejected_execution_exception"
			}
			it["error"] = map[string]any{"type": typ, "reason": "test"}
		}
		items[i] = map[string]any{op: it}
	}
	b, _ := json.Marshal(map[string]any{"took": 1, "errors": errs, "items": items})
	return b
}

func TestClientRetriesOn429(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if u, p, ok := r.BasicAuth(); !ok || u != "u" || p != "p" {
			t.Errorf("basic auth missing or wrong")
		}
		if calls.Add(1) <= 2 {
			w.WriteHeader(429)
			return
		}
		w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	resp, err := testClient(t, srv.URL, 5).Do(context.Background(), "GET", "/", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if resp.Status != 200 || resp.Attempts != 3 || resp.Throttled != 2 {
		t.Fatalf("got status %d attempts %d throttled %d, want 200 3 2", resp.Status, resp.Attempts, resp.Throttled)
	}

	calls.Store(0)
	resp, err = testClient(t, srv.URL, 1).Do(context.Background(), "GET", "/", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if resp.Status != 429 || resp.Attempts != 2 || resp.Throttled != 2 {
		t.Fatalf("bounded retry: got status %d attempts %d throttled %d, want 429 2 2", resp.Status, resp.Attempts, resp.Throttled)
	}
}

func TestBackoffIsBounded(t *testing.T) {
	c, err := NewClient(ClientConfig{URL: "http://x", BackoffBase: 100 * time.Millisecond, BackoffMax: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	if got := c.backoff(0); got != 100*time.Millisecond {
		t.Errorf("backoff(0) = %v", got)
	}
	if got := c.backoff(3); got != 800*time.Millisecond {
		t.Errorf("backoff(3) = %v", got)
	}
	for _, a := range []int{4, 10, 70} {
		if got := c.backoff(a); got != time.Second {
			t.Errorf("backoff(%d) = %v, want cap 1s", a, got)
		}
	}
}

func runBulkAgainst(t *testing.T, h http.HandlerFunc, cfg BulkConfig, input string) (*BulkResult, error, string) {
	t.Helper()
	srv := httptest.NewServer(h)
	defer srv.Close()
	if cfg.Index == "" {
		cfg.Index = "app-test"
	}
	if cfg.OpType == "" {
		cfg.OpType = "index"
	}
	if cfg.Clients == 0 {
		cfg.Clients = 1
	}
	if len(cfg.Inputs) == 0 {
		cfg.Inputs = []string{"-"}
	}
	out := filepath.Join(t.TempDir(), "records.jsonl")
	rec, err := OpenRecords(out)
	if err != nil {
		t.Fatal(err)
	}
	res, runErr := RunBulk(context.Background(), testClient(t, srv.URL, cfg.MaxRetries), cfg, strings.NewReader(input), rec, t.Logf)
	rec.Close()
	raw, _ := os.ReadFile(out)
	return res, runErr, string(raw)
}

func TestBulkPartialFailureAndItemRetry(t *testing.T) {
	var mu sync.Mutex
	seen := map[string]int{}
	var bodies [][]string
	h := func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/app-test/_bulk" || r.Method != "POST" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/x-ndjson" {
			t.Errorf("content type %q", ct)
		}
		body, _ := io.ReadAll(r.Body)
		lines := parseBulk(t, body)
		mu.Lock()
		bodies = append(bodies, lines)
		statuses := make([]int, len(lines))
		for i, l := range lines {
			seen[l]++
			switch {
			case strings.Contains(l, "bad"):
				statuses[i] = 400
			case strings.Contains(l, "busy") && seen[l] == 1:
				statuses[i] = 429
			default:
				statuses[i] = 201
			}
		}
		mu.Unlock()
		w.Write(bulkItems("index", statuses, "document_parsing_exception"))
	}
	input := `{"n":"ok1"}` + "\n\n" + `{"n":"bad"}` + "\n" + `{"n":"busy"}` + "\n" + `{"n":"ok2"}` + "\n"
	res, err, records := runBulkAgainst(t, h, BulkConfig{BulkSize: 10, MaxRetries: 3}, input)
	if err != nil {
		t.Fatal(err)
	}
	st := res.Stats
	if st.DocsOK != 3 || st.DocsFailed != 1 || st.Item429 != 1 {
		t.Fatalf("docs ok %d failed %d item429 %d, want 3 1 1", st.DocsOK, st.DocsFailed, st.Item429)
	}
	if st.Errors["document_parsing_exception"] != 1 || len(st.Errors) != 1 {
		t.Fatalf("errors %v", st.Errors)
	}
	if len(bodies) != 2 || len(bodies[1]) != 1 || bodies[1][0] != `{"n":"busy"}` {
		t.Fatalf("retry must resend only the rejected document, got %v", bodies)
	}
	if want := int64(len(`{"n":"ok1"}`) + len(`{"n":"busy"}`) + len(`{"n":"ok2"}`)); st.SrcBytes != want {
		t.Fatalf("src bytes %d, want %d", st.SrcBytes, want)
	}
	if st.Requests != 2 || st.Retries != 1 {
		t.Fatalf("requests %d retries %d, want 2 1", st.Requests, st.Retries)
	}
	if n := strings.Count(records, "\n"); n != 2 {
		t.Fatalf("want 2 JSON records, got %d: %s", n, records)
	}
}

func TestBulkItem429Exhausted(t *testing.T) {
	var calls atomic.Int32
	h := func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		body, _ := io.ReadAll(r.Body)
		lines := parseBulk(t, body)
		st := make([]int, len(lines))
		for i := range st {
			st[i] = 429
		}
		w.Write(bulkItems("index", st, ""))
	}
	res, err, _ := runBulkAgainst(t, h, BulkConfig{BulkSize: 5, MaxRetries: 2}, docs(3, func(i int) string { return fmt.Sprintf(`{"i":%d}`, i) }))
	if err != nil {
		t.Fatal(err)
	}
	st := res.Stats
	if calls.Load() != 3 {
		t.Fatalf("want 1 try + 2 retries, got %d requests", calls.Load())
	}
	if st.Item429 != 9 || st.DocsFailed != 3 || st.Errors["es_rejected_execution_exception"] != 3 || st.DocsOK != 0 {
		t.Fatalf("item429 %d failed %d errors %v ok %d", st.Item429, st.DocsFailed, st.Errors, st.DocsOK)
	}
}

func TestBulkWholeRequest429(t *testing.T) {
	var calls atomic.Int32
	h := func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(429)
		w.Write([]byte(`{"error":{"type":"es_rejected_execution_exception"},"status":429}`))
	}
	res, err, _ := runBulkAgainst(t, h, BulkConfig{BulkSize: 10, MaxRetries: 2}, docs(4, func(int) string { return `{}` }))
	if err != nil {
		t.Fatal(err)
	}
	st := res.Stats
	if calls.Load() != 3 || st.HTTP429 != 3 || st.Retries != 2 {
		t.Fatalf("calls %d http429 %d retries %d, want 3 3 2", calls.Load(), st.HTTP429, st.Retries)
	}
	if st.Errors["http_429/es_rejected_execution_exception"] != 4 || st.DocsFailed != 4 || st.Failed != 1 {
		t.Fatalf("errors %v failed docs %d failed requests %d", st.Errors, st.DocsFailed, st.Failed)
	}
}

func TestBulkHTTPErrorAndMalformed(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		body    string
		wantErr string
	}{
		{"security", 403, `{"error":{"type":"security_exception","reason":"no"},"status":403}`, "http_403/security_exception"},
		{"plain 502", 502, `<html>bad gateway</html>`, "http_502"},
		{"not json", 200, `not json`, "malformed_response"},
		{"truncated", 200, `{"took":1,"errors":false,"items":[`, "malformed_response"},
		{"no errors field", 200, `{"took":1,"items":[]}`, "malformed_response"},
		{"item count mismatch", 200, string(bulkItems("index", []int{201}, "")), "malformed_response"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				w.Write([]byte(tc.body))
			}
			res, err, _ := runBulkAgainst(t, h, BulkConfig{BulkSize: 10, MaxRetries: 2}, docs(3, func(int) string { return `{}` }))
			if err != nil {
				t.Fatal(err)
			}
			st := res.Stats
			if st.Errors[tc.wantErr] != 3 || st.DocsFailed != 3 || st.DocsOK != 0 || st.Failed != 1 {
				t.Fatalf("errors %v failed docs %d ok %d failed requests %d", st.Errors, st.DocsFailed, st.DocsOK, st.Failed)
			}
			if p := st.Percentile(50); p != 0 {
				t.Fatalf("failed requests must not count towards latency, p50 %v", p)
			}
		})
	}
}

func TestBulkTransportError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close()
	res, err := RunBulk(context.Background(), testClient(t, url, 1),
		BulkConfig{Index: "x", BulkSize: 2, Clients: 1, OpType: "index", Inputs: []string{"-"}},
		strings.NewReader(docs(3, func(int) string { return `{}` })), nil, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if res.Stats.Errors["transport_error"] != 3 || res.Stats.Failed != 2 {
		t.Fatalf("errors %v failed requests %d", res.Stats.Errors, res.Stats.Failed)
	}
}

func okBulkHandler(t *testing.T, delay time.Duration, total *atomic.Int64) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/_bulk"):
			body, _ := io.ReadAll(r.Body)
			lines := parseBulk(t, body)
			total.Add(int64(len(lines)))
			time.Sleep(delay)
			st := make([]int, len(lines))
			for i := range st {
				st[i] = 201
			}
			w.Write(bulkItems("index", st, ""))
		case strings.HasSuffix(r.URL.Path, "/_stats/store"):
			fmt.Fprintf(w, `{"_all":{"primaries":{"store":{"size_in_bytes":%d}}}}`, total.Load()*100)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}
}

func TestBulkStopsAtMaxDocs(t *testing.T) {
	var total atomic.Int64
	res, err, _ := runBulkAgainst(t, okBulkHandler(t, 0, &total), BulkConfig{BulkSize: 7, Clients: 3, MaxDocs: 50},
		docs(1000, func(i int) string { return fmt.Sprintf(`{"i":%d}`, i) }))
	if err != nil {
		t.Fatal(err)
	}
	if res.Stats.DocsOK != 50 || total.Load() != 50 {
		t.Fatalf("docs ok %d server saw %d, want 50", res.Stats.DocsOK, total.Load())
	}
}

func TestBulkStopsAtStoreSize(t *testing.T) {
	var total atomic.Int64
	dir := t.TempDir()
	in := filepath.Join(dir, "docs.json")
	if err := os.WriteFile(in, []byte(docs(1000, func(i int) string { return fmt.Sprintf(`{"i":%d}`, i) })), 0o644); err != nil {
		t.Fatal(err)
	}
	// 100 store bytes per document on the fake server: the target is reached
	// after 2000 of the 50000 documents that 50 repeats would provide.
	res, err, _ := runBulkAgainst(t, okBulkHandler(t, 2*time.Millisecond, &total),
		BulkConfig{BulkSize: 100, Clients: 2, MaxStoreBytes: 200_000, StorePoll: 5 * time.Millisecond, Inputs: []string{in}, Repeat: 50}, "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Stats.DocsOK < 2000 || res.Stats.DocsOK >= 50000 {
		t.Fatalf("docs ok %d, want at least 2000 and well below 50000", res.Stats.DocsOK)
	}
	if res.Stats.DocsFailed != 0 {
		t.Fatalf("stopping on store size must not fail in-flight batches: %v", res.Stats.Errors)
	}
}

func TestReadDocsGzipRepeatAndBlankLines(t *testing.T) {
	dir := t.TempDir()
	gz := filepath.Join(dir, "a.json.gz")
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write([]byte("{\"a\":1}\n\n  \n{\"a\":2}"))
	zw.Close()
	if err := os.WriteFile(gz, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	out := make(chan []byte, 100)
	if err := readDocs(context.Background(), []string{gz, "-"}, 2, strings.NewReader("{\"s\":1}\n"), out); err != nil {
		t.Fatal(err)
	}
	close(out)
	var got []string
	for l := range out {
		got = append(got, string(l))
	}
	want := `{"a":1} {"a":2} {"s":1} {"a":1} {"a":2}`
	if strings.Join(got, " ") != want {
		t.Fatalf("got %v, want %s", got, want)
	}
}

func TestPrepareIndexMergesSettings(t *testing.T) {
	var calls []string
	var created map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		if r.Method == "DELETE" {
			w.WriteHeader(404)
			w.Write([]byte(`{"error":{"type":"index_not_found_exception"},"status":404}`))
			return
		}
		json.NewDecoder(r.Body).Decode(&created)
		w.Write([]byte(`{"acknowledged":true}`))
	}))
	defer srv.Close()
	mapping := filepath.Join(t.TempDir(), "m.json")
	os.WriteFile(mapping, []byte(`{"settings":{"index.number_of_shards":1,"index.refresh_interval":"1s"},"mappings":{"properties":{"a":{"type":"keyword"}}}}`), 0o644)
	err := prepareIndex(context.Background(), testClient(t, srv.URL, 0), "app-x", mapping, true,
		map[string]string{"index.refresh_interval": "30s", "index.codec": "best_compression"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(calls, ",") != "DELETE /app-x,PUT /app-x" {
		t.Fatalf("calls %v", calls)
	}
	s := created["settings"].(map[string]any)
	if s["index.refresh_interval"] != "30s" || s["index.codec"] != "best_compression" || s["index.number_of_shards"] != float64(1) {
		t.Fatalf("settings %v", s)
	}
	if _, ok := created["mappings"]; !ok {
		t.Fatalf("mappings dropped")
	}
}

func TestPrepareIndexFailsOnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		w.Write([]byte(`{"error":{"type":"resource_already_exists_exception"},"status":400}`))
	}))
	defer srv.Close()
	mapping := filepath.Join(t.TempDir(), "m.json")
	os.WriteFile(mapping, []byte(`{"settings":{}}`), 0o644)
	err := prepareIndex(context.Background(), testClient(t, srv.URL, 0), "app-x", mapping, false, nil)
	if err == nil || !strings.Contains(err.Error(), "resource_already_exists_exception") {
		t.Fatalf("want resource_already_exists_exception, got %v", err)
	}
}

func writeQuerySet(t *testing.T, qs string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "q.json")
	if err := os.WriteFile(p, []byte(qs), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadQuerySetVariables(t *testing.T) {
	p := writeQuerySet(t, `{"queries":[{"name":"t","body":{"query":{"term":{"country_code${kw}":"DE"}}}}]}`)
	qs, err := LoadQuerySet(p, map[string]string{"kw": ".keyword", "index": "i"})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(qs.Queries[0].Body); got != `{"query":{"term":{"country_code.keyword":"DE"}}}` {
		t.Fatalf("body %s", got)
	}
	if _, err := LoadQuerySet(p, map[string]string{"index": "i"}); err == nil || !strings.Contains(err.Error(), "undefined variables [kw]") {
		t.Fatalf("want undefined variable error, got %v", err)
	}
	dup := writeQuerySet(t, `{"queries":[{"name":"a","body":{}},{"name":"a","body":{}}]}`)
	if _, err := LoadQuerySet(dup, nil); err == nil {
		t.Fatalf("duplicate names must fail")
	}
}

func TestSearchClassifiesResponses(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/app-q/_search" || r.Method != "POST" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		var body struct {
			Q string `json:"q"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		switch body.Q {
		case "ok":
			w.Write([]byte(`{"took":1,"timed_out":false,"_shards":{"total":1,"successful":1,"failed":0},"hits":{"total":{"value":42}}}`))
		case "partial":
			w.Write([]byte(`{"timed_out":false,"_shards":{"total":2,"failed":1,"failures":[{"reason":{"type":"query_shard_exception"}}]},"hits":{"total":{"value":1}}}`))
		case "timeout":
			w.Write([]byte(`{"timed_out":true,"_shards":{"total":1,"failed":0},"hits":{"total":{"value":1}}}`))
		case "breaker":
			w.WriteHeader(429)
			w.Write([]byte(`{"error":{"type":"circuit_breaking_exception"},"status":429}`))
		case "broken":
			w.Write([]byte(`{"took":`))
		default:
			w.WriteHeader(400)
			w.Write([]byte(`{"error":{"type":"parsing_exception"},"status":400}`))
		}
	}))
	defer srv.Close()
	p := writeQuerySet(t, `{"queries":[
		{"name":"ok","body":{"q":"ok"}},{"name":"partial","body":{"q":"partial"}},
		{"name":"timeout","body":{"q":"timeout"}},{"name":"breaker","body":{"q":"breaker"}},
		{"name":"broken","body":{"q":"broken"}},{"name":"bad","body":{"q":"bad"}}]}`)
	qs, err := LoadQuerySet(p, map[string]string{"index": "app-q"})
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "r.jsonl")
	rec, _ := OpenRecords(out)
	res, err := RunSearch(context.Background(), testClient(t, srv.URL, 1), SearchConfig{Index: "app-q", Concurrency: 3, Duration: 150 * time.Millisecond}, qs, rec)
	rec.Close()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"partial": "shard_failure/query_shard_exception", "timeout": "timed_out",
		"breaker": "http_429/circuit_breaking_exception", "broken": "malformed_response", "bad": "http_400/parsing_exception",
	}
	if st := res.ByQuery["ok"]; st.Requests == 0 || st.Failed != 0 || st.Percentile(99) == 0 {
		t.Fatalf("ok query: requests %d failed %d", st.Requests, st.Failed)
	}
	for name, kind := range want {
		st := res.ByQuery[name]
		if st.Requests == 0 || st.Failed != st.Requests || st.Errors[kind] != st.Requests || st.Percentile(50) != 0 {
			t.Fatalf("%s: requests %d failed %d errors %v", name, st.Requests, st.Failed, st.Errors)
		}
	}
	if b := res.ByQuery["breaker"]; b.HTTP429 != 2*b.Requests || b.Retries != b.Requests {
		t.Fatalf("breaker: 429 %d retries %d requests %d, want one retry per request", b.HTTP429, b.Retries, b.Requests)
	}
	var sum int64
	for _, st := range res.ByQuery {
		sum += st.Requests
	}
	if sum != res.Total.Requests {
		t.Fatalf("total %d != sum of queries %d", res.Total.Requests, sum)
	}
	raw, _ := os.ReadFile(out)
	if int64(strings.Count(string(raw), "\n")) != res.Total.Requests || !strings.Contains(string(raw), `"hits":42`) {
		t.Fatalf("records do not match requests")
	}
}

func TestSearchWarmupNotRecorded(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		time.Sleep(time.Millisecond)
		w.Write([]byte(`{"timed_out":false,"_shards":{"failed":0},"hits":{"total":{"value":0}}}`))
	}))
	defer srv.Close()
	p := writeQuerySet(t, `{"queries":[{"name":"a","body":{}}]}`)
	qs, _ := LoadQuerySet(p, map[string]string{"index": "i"})
	res, err := RunSearch(context.Background(), testClient(t, srv.URL, 0), SearchConfig{Index: "i", Concurrency: 1, Duration: 50 * time.Millisecond, Warmup: 50 * time.Millisecond}, qs, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.Total.Requests == 0 || int64(calls.Load()) <= res.Total.Requests {
		t.Fatalf("server saw %d, recorded %d: warmup requests must be sent but not recorded", calls.Load(), res.Total.Requests)
	}
}

func TestPercentileNearestRank(t *testing.T) {
	var lat []time.Duration
	for i := 1; i <= 100; i++ {
		lat = append(lat, time.Duration(101-i)*time.Millisecond)
	}
	for p, want := range map[float64]time.Duration{50: 50 * time.Millisecond, 90: 90 * time.Millisecond, 99: 99 * time.Millisecond, 100: 100 * time.Millisecond, 0: time.Millisecond} {
		if got := percentile(lat, p); got != want {
			t.Errorf("p%v = %v, want %v", p, got, want)
		}
	}
	if percentile(nil, 99) != 0 {
		t.Errorf("empty input must give 0")
	}
}

func TestSummaryCSVHeaderOnce(t *testing.T) {
	p := filepath.Join(t.TempDir(), "summary.csv")
	st := NewStats()
	st.Requests, st.DocsOK = 2, 10
	st.AddLatency(time.Millisecond)
	st.AddError("b_type", 2)
	st.AddError("a_type", 1)
	row := SummaryRow{RunID: "r", Op: "bulk", Index: "i", Stats: st, Duration: time.Second, DocsPerSec: 10}
	for i := 0; i < 2; i++ {
		if err := AppendSummary(p, []SummaryRow{row}); err != nil {
			t.Fatal(err)
		}
	}
	f, _ := os.Open(p)
	defer f.Close()
	recs, err := csv.NewReader(f).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 3 || recs[0][0] != "run_id" || recs[1][0] != "r" {
		t.Fatalf("records %v", recs)
	}
	if last := recs[1][len(recs[1])-1]; last != "a_type=1;b_type=2" {
		t.Fatalf("errors column %q", last)
	}
	if len(recs[1]) != len(summaryHeader) {
		t.Fatalf("row has %d fields, header %d", len(recs[1]), len(summaryHeader))
	}
}

// The query sets and mapping profiles shipped in the repo must parse and
// resolve with the variables bench/run.sh passes for each profile.
func TestRepoQuerySetsAndMappingsParse(t *testing.T) {
	sets, _ := filepath.Glob("../queries/*.json")
	if len(sets) == 0 {
		t.Fatal("no query sets found in ../queries")
	}
	for _, s := range sets {
		for _, kw := range []string{"", ".keyword"} {
			if _, err := LoadQuerySet(s, map[string]string{"index": "i", "kw": kw}); err != nil {
				t.Errorf("%s: %v", s, err)
			}
		}
	}
	maps, _ := filepath.Glob("../mappings/*/*.json")
	if len(maps) == 0 {
		t.Fatal("no mapping profiles found in ../mappings")
	}
	for _, m := range maps {
		raw, _ := os.ReadFile(m)
		var doc map[string]json.RawMessage
		if err := json.Unmarshal(raw, &doc); err != nil {
			t.Errorf("%s: %v", m, err)
			continue
		}
		var settings map[string]any
		if err := json.Unmarshal(doc["settings"], &settings); err != nil {
			t.Errorf("%s: settings must be an object: %v", m, err)
		}
		for k := range settings {
			if !strings.HasPrefix(k, "index.") {
				t.Errorf("%s: setting %q must use the flat index.* form so loader overrides replace it", m, k)
			}
		}
	}
}

func TestCommandsEndToEnd(t *testing.T) {
	var total atomic.Int64
	bulk := okBulkHandler(t, 0, &total)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "PUT" && r.URL.Path == "/app-e2e":
			w.Write([]byte(`{"acknowledged":true}`))
		case strings.HasSuffix(r.URL.Path, "/_refresh"):
			w.Write([]byte(`{"_shards":{"failed":0}}`))
		case strings.HasSuffix(r.URL.Path, "/_count"):
			fmt.Fprintf(w, `{"count":%d}`, total.Load())
		case strings.HasSuffix(r.URL.Path, "/_search"):
			w.Write([]byte(`{"timed_out":false,"_shards":{"failed":0},"hits":{"total":{"value":1}}}`))
		default:
			bulk(w, r)
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	summary := filepath.Join(dir, "summary.csv")
	mapping := filepath.Join(dir, "m.json")
	os.WriteFile(mapping, []byte(`{"settings":{"index.number_of_shards":1}}`), 0o644)
	var stdout, stderr bytes.Buffer
	err := cmdBulk(context.Background(), []string{"-url", srv.URL, "-index", "app-e2e", "-input", "-", "-mapping", mapping,
		"-bulk-size", "3", "-clients", "2", "-summary", summary, "-run-id", "r1", "-refresh-interval", "30s"},
		strings.NewReader(docs(10, func(i int) string { return fmt.Sprintf(`{"i":%d}`, i) })), &stdout, &stderr)
	if err != nil {
		t.Fatalf("%v: %s", err, stderr.String())
	}
	var row map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &row); err != nil {
		t.Fatal(err)
	}
	if row["docs_ok"] != float64(10) || row["index_docs"] != float64(10) || row["store_bytes"] != float64(1000) || row["refresh_interval"] != "30s" {
		t.Fatalf("bulk summary %v", row)
	}
	qs := writeQuerySet(t, `{"queries":[{"name":"a","body":{}},{"name":"b","body":{}}]}`)
	stdout.Reset()
	err = cmdSearch(context.Background(), []string{"-url", srv.URL, "-index", "app-e2e", "-queries", qs, "-concurrency", "2",
		"-duration", "50ms", "-summary", summary, "-run-id", "r1"}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("%v: %s", err, stderr.String())
	}
	if n := strings.Count(stdout.String(), "\n"); n != 3 {
		t.Fatalf("want rows all, a, b; got %d lines", n)
	}
	f, _ := os.Open(summary)
	defer f.Close()
	recs, err := csv.NewReader(f).ReadAll()
	if err != nil || len(recs) != 5 {
		t.Fatalf("summary rows %d (want header + 1 bulk + 3 search): %v", len(recs), err)
	}
}

func TestBulkSkipDocs(t *testing.T) {
	var mu sync.Mutex
	var got []string
	h := func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		lines := parseBulk(t, body)
		mu.Lock()
		got = append(got, lines...)
		mu.Unlock()
		st := make([]int, len(lines))
		for i := range st {
			st[i] = 201
		}
		w.Write(bulkItems("index", st, ""))
	}
	res, err, _ := runBulkAgainst(t, h, BulkConfig{BulkSize: 2, SkipDocs: 3, MaxDocs: 2}, docs(10, func(i int) string { return fmt.Sprintf(`{"i":%d}`, i) }))
	if err != nil {
		t.Fatal(err)
	}
	if res.Stats.DocsOK != 2 || strings.Join(got, ",") != `{"i":3},{"i":4}` {
		t.Fatalf("docs ok %d, sent %v", res.Stats.DocsOK, got)
	}
}

func TestBulkSkipsWhenStoreAlreadyAtTarget(t *testing.T) {
	var total atomic.Int64
	total.Store(50)
	res, err, _ := runBulkAgainst(t, okBulkHandler(t, 0, &total),
		BulkConfig{BulkSize: 10, MaxStoreBytes: 5000, StorePoll: time.Hour}, docs(100, func(int) string { return `{}` }))
	if err != nil {
		t.Fatal(err)
	}
	if res.Stats.Requests != 0 || total.Load() != 50 {
		t.Fatalf("requests %d, server docs %d: nothing must be sent", res.Stats.Requests, total.Load())
	}
}
