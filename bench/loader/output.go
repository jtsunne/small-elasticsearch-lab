package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"sync"
	"time"
)

// RecordWriter writes one JSON object per line. A nil *RecordWriter discards.
type RecordWriter struct {
	mu  sync.Mutex
	enc *json.Encoder
	c   io.Closer
}

func OpenRecords(path string) (*RecordWriter, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &RecordWriter{enc: json.NewEncoder(f), c: f}, nil
}

func (w *RecordWriter) Write(rec any) error {
	if w == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.enc.Encode(rec)
}

func (w *RecordWriter) Close() error {
	if w == nil {
		return nil
	}
	return w.c.Close()
}

// SummaryRow is one line of the summary CSV. Bulk and search runs share the
// columns so that results from several runs can be appended to one file.
type SummaryRow struct {
	RunID           string
	Label           string
	Op              string
	Query           string
	Index           string
	BulkSize        int
	Clients         int
	RefreshInterval string
	Duration        time.Duration
	Stats           *Stats
	DocsPerSec      float64
	OpsPerSec       float64
	BytesPerSec     float64
	StoreBytes      int64
	IndexDocs       int64
}

var summaryHeader = []string{
	"run_id", "label", "op", "query", "index", "bulk_size", "clients", "refresh_interval",
	"duration_s", "requests", "failed_requests", "docs_ok", "docs_failed", "src_bytes",
	"docs_per_s", "ops_per_s", "bytes_per_s", "p50_ms", "p90_ms", "p99_ms", "max_ms",
	"http_429", "item_429", "retries", "store_bytes", "index_docs", "errors",
}

func (r SummaryRow) fields() []string {
	s := r.Stats
	f := func(v float64) string { return strconv.FormatFloat(v, 'f', 3, 64) }
	i := func(v int64) string { return strconv.FormatInt(v, 10) }
	return []string{
		r.RunID, r.Label, r.Op, r.Query, r.Index, strconv.Itoa(r.BulkSize), strconv.Itoa(r.Clients), r.RefreshInterval,
		f(r.Duration.Seconds()), i(s.Requests), i(s.Failed), i(s.DocsOK), i(s.DocsFailed), i(s.SrcBytes),
		f(r.DocsPerSec), f(r.OpsPerSec), f(r.BytesPerSec),
		f(ms(s.Percentile(50))), f(ms(s.Percentile(90))), f(ms(s.Percentile(99))), f(ms(s.Max())),
		i(s.HTTP429), i(s.Item429), i(s.Retries), i(r.StoreBytes), i(r.IndexDocs), s.ErrorString(),
	}
}

// AppendSummary appends rows to a CSV file, writing the header when the file
// is new or empty.
func AppendSummary(path string, rows []SummaryRow) error {
	if path == "" {
		return nil
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	w := csv.NewWriter(f)
	if st.Size() == 0 {
		if err := w.Write(summaryHeader); err != nil {
			return err
		}
	}
	for _, r := range rows {
		if err := w.Write(r.fields()); err != nil {
			return err
		}
	}
	w.Flush()
	if err := w.Error(); err != nil {
		return fmt.Errorf("write summary: %w", err)
	}
	return nil
}

// SummaryJSON is the machine-readable form printed to stdout at the end.
func (r SummaryRow) JSON() map[string]any {
	s := r.Stats
	s.Lock()
	errs := make(map[string]int64, len(s.Errors))
	for k, v := range s.Errors {
		errs[k] = v
	}
	s.Unlock()
	return map[string]any{
		"run_id": r.RunID, "label": r.Label, "op": r.Op, "query": r.Query, "index": r.Index,
		"bulk_size": r.BulkSize, "clients": r.Clients, "refresh_interval": r.RefreshInterval,
		"duration_s": r.Duration.Seconds(), "requests": s.Requests, "failed_requests": s.Failed,
		"docs_ok": s.DocsOK, "docs_failed": s.DocsFailed, "src_bytes": s.SrcBytes,
		"docs_per_s": r.DocsPerSec, "ops_per_s": r.OpsPerSec, "bytes_per_s": r.BytesPerSec,
		"p50_ms": ms(s.Percentile(50)), "p90_ms": ms(s.Percentile(90)), "p99_ms": ms(s.Percentile(99)), "max_ms": ms(s.Max()),
		"http_429": s.HTTP429, "item_429": s.Item429, "retries": s.Retries,
		"store_bytes": r.StoreBytes, "index_docs": r.IndexDocs, "errors": errs,
	}
}
