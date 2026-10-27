// Command loader is the benchmark client for small-elasticsearch-lab. It
// speaks plain HTTP to Elasticsearch and OpenSearch alike: "bulk" indexes
// NDJSON documents through _bulk, "search" runs a fixed query set through
// _search. Both write one JSON line per request and append summary rows to a
// CSV file.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

type kvFlag map[string]string

func (m kvFlag) String() string { return fmt.Sprint(map[string]string(m)) }
func (m kvFlag) Set(v string) error {
	k, val, ok := strings.Cut(v, "=")
	if !ok || k == "" {
		return fmt.Errorf("want key=value, got %q", v)
	}
	m[k] = val
	return nil
}

type common struct {
	client  ClientConfig
	index   string
	out     string
	summary string
	runID   string
	label   string
}

func registerCommon(fs *flag.FlagSet, c *common) {
	fs.StringVar(&c.client.URL, "url", "http://127.0.0.1:9200", "cluster URL")
	fs.StringVar(&c.client.User, "user", "", "basic auth user (password from -password or LOADER_PASSWORD)")
	fs.StringVar(&c.client.Password, "password", "", "basic auth password; prefer LOADER_PASSWORD")
	fs.StringVar(&c.client.CAFile, "ca", "", "PEM file with the CA that signed the server certificate")
	fs.BoolVar(&c.client.Insecure, "insecure", false, "skip TLS verification (local labs only)")
	fs.DurationVar(&c.client.Timeout, "timeout", 120*time.Second, "per-request timeout")
	fs.IntVar(&c.client.MaxRetries, "max-retries", 8, "retries on HTTP 429 per request and on item-level 429 per batch")
	fs.StringVar(&c.index, "index", "", "target index (required)")
	fs.StringVar(&c.out, "out", "", "append one JSON line per request to this file")
	fs.StringVar(&c.summary, "summary", "", "append summary rows to this CSV file")
	fs.StringVar(&c.runID, "run-id", "", "run id written to the summary (default: UTC timestamp)")
	fs.StringVar(&c.label, "label", "", "free-form label for the summary, for example es-9.5.5-keyword")
}

func (c *common) finish() error {
	if c.index == "" {
		return errors.New("-index is required")
	}
	if c.client.Password == "" {
		c.client.Password = os.Getenv("LOADER_PASSWORD")
	}
	if c.runID == "" {
		c.runID = time.Now().UTC().Format("20060102T150405Z")
	}
	return nil
}

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var err error
	switch os.Args[1] {
	case "bulk":
		err = cmdBulk(ctx, os.Args[2:], os.Stdin, os.Stdout, os.Stderr)
	case "search":
		err = cmdSearch(ctx, os.Args[2:], os.Stdout, os.Stderr)
	case "-h", "--help", "help":
		usage(os.Stdout)
		return
	default:
		usage(os.Stderr)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "loader:", err)
		os.Exit(1)
	}
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: loader bulk|search [flags]; loader <command> -h for flags")
}

func cmdBulk(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("bulk", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var c common
	registerCommon(fs, &c)
	var cfg BulkConfig
	var inputs multiFlag
	settings := kvFlag{}
	var mapping, refresh string
	var recreate bool
	fs.Var(&inputs, "input", "NDJSON input file, - for stdin, .bz2/.gz decompressed (repeatable, read in order)")
	fs.IntVar(&cfg.Repeat, "repeat", 1, "read the input files this many times (synthetic replication; stdin is read once)")
	fs.IntVar(&cfg.BulkSize, "bulk-size", 1000, "documents per _bulk request")
	fs.IntVar(&cfg.Clients, "clients", 1, "concurrent bulk clients, one connection each")
	fs.StringVar(&cfg.OpType, "op-type", "index", "bulk action: index or create")
	fs.Int64Var(&cfg.SkipDocs, "skip-docs", 0, "skip this many input documents first, to continue a previous load (docs_ok + docs_failed of earlier runs)")
	fs.Int64Var(&cfg.MaxDocs, "max-docs", 0, "stop after this many documents (0: no limit)")
	fs.Int64Var(&cfg.MaxStoreBytes, "max-store-bytes", 0, "stop when the primary store reaches this size (0: no limit)")
	fs.DurationVar(&cfg.StorePoll, "store-poll", 5*time.Second, "how often to check the store size")
	fs.StringVar(&mapping, "mapping", "", "create the index from this create-index body (settings + mappings)")
	fs.BoolVar(&recreate, "recreate", false, "delete the index first (with -mapping)")
	fs.StringVar(&refresh, "refresh-interval", "", "index.refresh_interval to set before loading, for example 1s or 30s")
	fs.Var(settings, "setting", "extra flat index setting key=value (repeatable), for example index.codec=best_compression")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := c.finish(); err != nil {
		return err
	}
	if len(inputs) == 0 {
		return errors.New("at least one -input is required")
	}
	cfg.Index, cfg.Inputs, cfg.MaxRetries = c.index, inputs, c.client.MaxRetries
	if refresh != "" {
		settings["index.refresh_interval"] = refresh
	}
	c.client.Connections = cfg.Clients + 1
	client, err := NewClient(c.client)
	if err != nil {
		return err
	}
	if err := prepareIndex(ctx, client, c.index, mapping, recreate, settings); err != nil {
		return fmt.Errorf("prepare index: %w", err)
	}
	rec, err := OpenRecords(c.out)
	if err != nil {
		return err
	}
	defer rec.Close()

	logf := func(f string, a ...any) { fmt.Fprintf(stderr, "loader: "+f+"\n", a...) }
	res, runErr := RunBulk(ctx, client, cfg, stdin, rec, logf)
	if res == nil {
		return runErr
	}
	row := SummaryRow{
		RunID: c.runID, Label: c.label, Op: "bulk", Index: c.index, BulkSize: cfg.BulkSize, Clients: cfg.Clients,
		RefreshInterval: refresh, Duration: res.Elapsed, Stats: res.Stats, StoreBytes: -1, IndexDocs: -1,
	}
	if secs := res.Elapsed.Seconds(); secs > 0 {
		row.DocsPerSec = float64(res.Stats.DocsOK) / secs
		row.OpsPerSec = float64(res.Stats.Requests-res.Stats.Failed) / secs
		row.BytesPerSec = float64(res.Stats.SrcBytes) / secs
	}
	if runErr == nil {
		if err := expectOK(client.Do(ctx, "POST", "/"+c.index+"/_refresh", nil, "")); err != nil {
			logf("refresh: %v", err)
		}
		if b, err := storeBytes(ctx, client, c.index); err == nil {
			row.StoreBytes = b
		} else {
			logf("store size: %v", err)
		}
		if n, err := indexDocs(ctx, client, c.index); err == nil {
			row.IndexDocs = n
		} else {
			logf("doc count: %v", err)
		}
	}
	if err := AppendSummary(c.summary, []SummaryRow{row}); err != nil {
		return err
	}
	if err := json.NewEncoder(stdout).Encode(row.JSON()); err != nil {
		return err
	}
	return runErr
}

func cmdSearch(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("search", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var c common
	registerCommon(fs, &c)
	var cfg SearchConfig
	var queries string
	vars := kvFlag{}
	fs.StringVar(&queries, "queries", "", "query set file, see bench/queries (required)")
	fs.Var(vars, "var", "query variable name=value (repeatable); ${index} is always set")
	fs.IntVar(&cfg.Concurrency, "concurrency", 1, "concurrent search clients")
	fs.DurationVar(&cfg.Duration, "duration", 5*time.Minute, "measured duration")
	fs.DurationVar(&cfg.Warmup, "warmup", 0, "unrecorded warmup before the measured duration")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := c.finish(); err != nil {
		return err
	}
	if queries == "" {
		return errors.New("-queries is required")
	}
	vars["index"] = c.index
	qs, err := LoadQuerySet(queries, vars)
	if err != nil {
		return err
	}
	cfg.Index = c.index
	c.client.Connections = cfg.Concurrency
	client, err := NewClient(c.client)
	if err != nil {
		return err
	}
	rec, err := OpenRecords(c.out)
	if err != nil {
		return err
	}
	defer rec.Close()

	res, runErr := RunSearch(ctx, client, cfg, qs, rec)
	if res == nil {
		return runErr
	}
	mk := func(name string, st *Stats) SummaryRow {
		row := SummaryRow{
			RunID: c.runID, Label: c.label, Op: "search", Query: name, Index: c.index, Clients: cfg.Concurrency,
			Duration: res.Elapsed, Stats: st, StoreBytes: -1, IndexDocs: -1,
		}
		if secs := res.Elapsed.Seconds(); secs > 0 {
			row.OpsPerSec = float64(st.Requests-st.Failed) / secs
		}
		return row
	}
	rows := []SummaryRow{mk("all", res.Total)}
	for _, n := range res.QueryNames() {
		rows = append(rows, mk(n, res.ByQuery[n]))
	}
	if err := AppendSummary(c.summary, rows); err != nil {
		return err
	}
	enc := json.NewEncoder(stdout)
	for _, r := range rows {
		if err := enc.Encode(r.JSON()); err != nil {
			return err
		}
	}
	return runErr
}
