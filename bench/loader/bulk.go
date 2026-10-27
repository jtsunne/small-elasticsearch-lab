package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"
)

type BulkConfig struct {
	Index         string
	BulkSize      int
	Clients       int
	OpType        string
	SkipDocs      int64
	MaxDocs       int64
	MaxStoreBytes int64
	StorePoll     time.Duration
	MaxRetries    int
	Inputs        []string
	Repeat        int
}

type bulkItem struct {
	Status int `json:"status"`
	Error  *struct {
		Type   string `json:"type"`
		Reason string `json:"reason"`
	} `json:"error"`
}

type bulkResponse struct {
	Errors *bool                 `json:"errors"`
	Items  []map[string]bulkItem `json:"items"`
}

type bulkRecord struct {
	TS        string           `json:"ts"`
	Op        string           `json:"op"`
	Worker    int              `json:"worker"`
	Attempt   int              `json:"attempt"`
	Status    int              `json:"status"`
	ServiceMS float64          `json:"service_ms"`
	Docs      int              `json:"docs"`
	DocsOK    int              `json:"docs_ok"`
	Item429   int              `json:"item_429"`
	Throttled int              `json:"http_429"`
	Bytes     int              `json:"bytes"`
	Errors    map[string]int64 `json:"errors,omitempty"`
}

type BulkResult struct {
	Stats   *Stats
	Elapsed time.Duration
}

func buildBulkBody(docs [][]byte, action []byte) []byte {
	n := 0
	for _, d := range docs {
		n += len(action) + len(d) + 2
	}
	buf := make([]byte, 0, n)
	for _, d := range docs {
		buf = append(buf, action...)
		buf = append(buf, '\n')
		buf = append(buf, d...)
		buf = append(buf, '\n')
	}
	return buf
}

func httpErrorType(status int, body []byte) string {
	var e struct {
		Error struct {
			Type string `json:"type"`
		} `json:"error"`
	}
	kind := "http_" + strconv.Itoa(status)
	if json.Unmarshal(body, &e) == nil && e.Error.Type != "" {
		kind += "/" + e.Error.Type
	}
	return kind
}

// sendBatch indexes one batch. Item-level 429s (es_rejected_execution_exception)
// are retried for those documents only, at most cfg.MaxRetries times; whole
// request 429s are already retried by the client.
func sendBatch(ctx context.Context, c *Client, cfg BulkConfig, worker int, docs [][]byte, st *Stats, rec *RecordWriter) {
	action := []byte(`{"` + cfg.OpType + `":{}}`)
	path := "/" + url.PathEscape(cfg.Index) + "/_bulk"
	pending := docs
	for attempt := 0; len(pending) > 0; attempt++ {
		body := buildBulkBody(pending, action)
		resp, err := c.Do(ctx, http.MethodPost, path, body, "application/x-ndjson")
		r := bulkRecord{
			TS: time.Now().UTC().Format(time.RFC3339Nano), Op: "bulk", Worker: worker, Attempt: attempt,
			Docs: len(pending), Bytes: len(body), Errors: map[string]int64{},
		}
		if resp != nil {
			r.Status, r.ServiceMS, r.Throttled = resp.Status, ms(resp.Elapsed), resp.Throttled
		}
		retry, okBytes := classifyBulk(resp, err, pending, &r)

		st.Lock()
		st.Requests++
		st.HTTP429 += int64(r.Throttled)
		if resp != nil && resp.Attempts > 1 {
			st.Retries += int64(resp.Attempts - 1)
		}
		st.Item429 += int64(r.Item429)
		st.DocsOK += int64(r.DocsOK)
		st.SrcBytes += okBytes
		if r.Status == http.StatusOK && err == nil && r.Errors["malformed_response"] == 0 {
			st.AddLatency(resp.Elapsed)
		} else {
			st.Failed++
		}
		final := len(retry) == 0 || attempt >= cfg.MaxRetries || ctx.Err() != nil
		if final && len(retry) > 0 {
			r.Errors["es_rejected_execution_exception"] += int64(len(retry))
		}
		var failed int64
		for k, v := range r.Errors {
			st.AddError(k, v)
			failed += v
		}
		st.DocsFailed += failed
		if !final {
			st.Retries++
		}
		st.Unlock()
		_ = rec.Write(r)

		if final {
			return
		}
		if c.sleep(ctx, c.backoff(attempt)) != nil {
			st.Lock()
			st.AddError("es_rejected_execution_exception", int64(len(retry)))
			st.DocsFailed += int64(len(retry))
			st.Unlock()
			return
		}
		pending = retry
	}
}

// classifyBulk fills r with per-document outcomes and returns the documents to
// retry plus the source bytes of documents that were accepted. Retryable
// documents are not counted as errors here.
func classifyBulk(resp *Response, err error, docs [][]byte, r *bulkRecord) ([][]byte, int64) {
	if err != nil {
		r.Errors["transport_error"] += int64(len(docs))
		return nil, 0
	}
	if resp.Status != http.StatusOK {
		r.Errors[httpErrorType(resp.Status, resp.Body)] += int64(len(docs))
		return nil, 0
	}
	var br bulkResponse
	if json.Unmarshal(resp.Body, &br) != nil || br.Errors == nil || len(br.Items) != len(docs) {
		r.Errors["malformed_response"] += int64(len(docs))
		return nil, 0
	}
	var retry [][]byte
	var okBytes int64
	for i, m := range br.Items {
		if len(m) != 1 {
			r.Errors["malformed_response"]++
			continue
		}
		for _, it := range m {
			switch {
			case it.Status >= 200 && it.Status < 300:
				r.DocsOK++
				okBytes += int64(len(docs[i]))
			case it.Status == http.StatusTooManyRequests:
				r.Item429++
				retry = append(retry, docs[i])
			case it.Error != nil && it.Error.Type != "":
				r.Errors[it.Error.Type]++
			default:
				r.Errors["item_"+strconv.Itoa(it.Status)]++
			}
		}
	}
	return retry, okBytes
}

// storeBytes returns the primary store size of the index.
func storeBytes(ctx context.Context, c *Client, index string) (int64, error) {
	resp, err := c.Do(ctx, http.MethodGet, "/"+url.PathEscape(index)+"/_stats/store", nil, "")
	if err != nil {
		return 0, err
	}
	if resp.Status != http.StatusOK {
		return 0, fmt.Errorf("_stats/store: %s", httpErrorType(resp.Status, resp.Body))
	}
	var s struct {
		All struct {
			Primaries struct {
				Store struct {
					Bytes *int64 `json:"size_in_bytes"`
				} `json:"store"`
			} `json:"primaries"`
		} `json:"_all"`
	}
	if err := json.Unmarshal(resp.Body, &s); err != nil || s.All.Primaries.Store.Bytes == nil {
		return 0, fmt.Errorf("_stats/store: malformed response")
	}
	return *s.All.Primaries.Store.Bytes, nil
}

func indexDocs(ctx context.Context, c *Client, index string) (int64, error) {
	resp, err := c.Do(ctx, http.MethodGet, "/"+url.PathEscape(index)+"/_count", nil, "")
	if err != nil {
		return 0, err
	}
	if resp.Status != http.StatusOK {
		return 0, fmt.Errorf("_count: %s", httpErrorType(resp.Status, resp.Body))
	}
	var s struct {
		Count *int64 `json:"count"`
	}
	if err := json.Unmarshal(resp.Body, &s); err != nil || s.Count == nil {
		return 0, fmt.Errorf("_count: malformed response")
	}
	return *s.Count, nil
}

// RunBulk skips the first SkipDocs documents, then batches the rest and
// indexes them with cfg.Clients concurrent workers until the input ends, MaxDocs is reached or the primary
// store reaches MaxStoreBytes (checked every StorePoll, so it overshoots by
// up to one poll interval of ingest).
func RunBulk(ctx context.Context, c *Client, cfg BulkConfig, stdin io.Reader, rec *RecordWriter, logf func(string, ...any)) (*BulkResult, error) {
	if cfg.BulkSize < 1 || cfg.Clients < 1 {
		return nil, fmt.Errorf("bulk size and clients must be at least 1")
	}
	if cfg.OpType != "index" && cfg.OpType != "create" {
		return nil, fmt.Errorf("op type must be index or create")
	}
	if cfg.MaxStoreBytes > 0 {
		b, err := storeBytes(ctx, c, cfg.Index)
		if err != nil {
			return nil, err
		}
		if b >= cfg.MaxStoreBytes {
			logf("primary store %d bytes already at target %d, nothing to load", b, cfg.MaxStoreBytes)
			return &BulkResult{Stats: NewStats()}, nil
		}
	}
	stopCtx, stop := context.WithCancel(ctx)
	defer stop()

	lines := make(chan []byte, cfg.BulkSize*cfg.Clients)
	batches := make(chan [][]byte, cfg.Clients)
	readErr := make(chan error, 1)
	go func() {
		defer close(lines)
		readErr <- readDocs(stopCtx, cfg.Inputs, cfg.Repeat, stdin, lines)
	}()
	go func() {
		defer close(batches)
		var n, skipped int64
		batch := make([][]byte, 0, cfg.BulkSize)
		for line := range lines {
			if skipped < cfg.SkipDocs {
				skipped++
				continue
			}
			batch = append(batch, line)
			n++
			if len(batch) == cfg.BulkSize || (cfg.MaxDocs > 0 && n >= cfg.MaxDocs) {
				select {
				case batches <- batch:
				case <-stopCtx.Done():
					return
				}
				batch = make([][]byte, 0, cfg.BulkSize)
			}
			if cfg.MaxDocs > 0 && n >= cfg.MaxDocs {
				stop()
				return
			}
		}
		if len(batch) > 0 {
			select {
			case batches <- batch:
			case <-stopCtx.Done():
			}
		}
	}()

	var monitorErr error
	monitorDone := make(chan struct{})
	if cfg.MaxStoreBytes > 0 {
		poll := cfg.StorePoll
		if poll <= 0 {
			poll = 5 * time.Second
		}
		go func() {
			defer close(monitorDone)
			t := time.NewTicker(poll)
			defer t.Stop()
			for {
				select {
				case <-stopCtx.Done():
					return
				case <-t.C:
					b, err := storeBytes(ctx, c, cfg.Index)
					if err != nil {
						monitorErr = err
						stop()
						return
					}
					if b >= cfg.MaxStoreBytes {
						logf("primary store %d bytes reached target %d, stopping", b, cfg.MaxStoreBytes)
						stop()
						return
					}
				}
			}
		}()
	} else {
		close(monitorDone)
	}

	st := NewStats()
	start := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < cfg.Clients; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for b := range batches {
				// In-flight batches finish even after a stop, so that a stop
				// on store size does not turn into transport errors.
				sendBatch(ctx, c, cfg, w, b, st, rec)
			}
		}(w)
	}
	wg.Wait()
	elapsed := time.Since(start)
	stop()
	<-monitorDone
	if err := <-readErr; err != nil {
		return &BulkResult{Stats: st, Elapsed: elapsed}, err
	}
	if monitorErr != nil {
		return &BulkResult{Stats: st, Elapsed: elapsed}, monitorErr
	}
	return &BulkResult{Stats: st, Elapsed: elapsed}, nil
}

// prepareIndex optionally deletes and creates the index from a create-index
// body file, then applies flat settings overrides. Keys in overrides use the
// flat form ("index.refresh_interval"), so mapping files must use flat keys
// for any setting that may be overridden.
func prepareIndex(ctx context.Context, c *Client, index, mappingFile string, recreate bool, overrides map[string]string) error {
	p := "/" + url.PathEscape(index)
	if mappingFile == "" {
		if len(overrides) == 0 {
			return nil
		}
		settings := map[string]any{}
		for k, v := range overrides {
			settings[k] = v
		}
		body, _ := json.Marshal(settings)
		return expectOK(c.Do(ctx, http.MethodPut, p+"/_settings", body, "application/json"))
	}
	raw, err := os.ReadFile(mappingFile)
	if err != nil {
		return err
	}
	var doc map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		return fmt.Errorf("%s: %w", mappingFile, err)
	}
	settings, _ := doc["settings"].(map[string]any)
	if settings == nil {
		settings = map[string]any{}
	}
	for k, v := range overrides {
		settings[k] = v
	}
	doc["settings"] = settings
	body, _ := json.Marshal(doc)
	if recreate {
		resp, err := c.Do(ctx, http.MethodDelete, p, nil, "")
		if err != nil {
			return err
		}
		if resp.Status != http.StatusOK && resp.Status != http.StatusNotFound {
			return fmt.Errorf("delete %s: %s", index, httpErrorType(resp.Status, resp.Body))
		}
	}
	return expectOK(c.Do(ctx, http.MethodPut, p, body, "application/json"))
}

func expectOK(resp *Response, err error) error {
	if err != nil {
		return err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return fmt.Errorf("%s: %s", httpErrorType(resp.Status, resp.Body), bytes.TrimSpace(resp.Body))
	}
	return nil
}
