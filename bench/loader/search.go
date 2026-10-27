package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type Query struct {
	Name string          `json:"name"`
	Body json.RawMessage `json:"body"`
}

type QuerySet struct {
	Corpus      string  `json:"corpus"`
	Description string  `json:"description"`
	Queries     []Query `json:"queries"`
}

var varRef = regexp.MustCompile(`\$\{([a-z_][a-z0-9_]*)\}`)

// LoadQuerySet reads a query set and substitutes ${name} references in each
// body. "index" is always defined. An unknown reference is an error, so a
// query written for one mapping profile cannot silently run against another.
func LoadQuerySet(path string, vars map[string]string) (*QuerySet, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var qs QuerySet
	if err := json.Unmarshal(raw, &qs); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(qs.Queries) == 0 {
		return nil, fmt.Errorf("%s: no queries", path)
	}
	seen := map[string]bool{}
	for i, q := range qs.Queries {
		if q.Name == "" || seen[q.Name] {
			return nil, fmt.Errorf("%s: query %d: missing or duplicate name", path, i)
		}
		seen[q.Name] = true
		var missing []string
		body := varRef.ReplaceAllFunc(q.Body, func(m []byte) []byte {
			name := string(varRef.FindSubmatch(m)[1])
			v, ok := vars[name]
			if !ok {
				missing = append(missing, name)
				return m
			}
			return []byte(v)
		})
		if len(missing) > 0 {
			return nil, fmt.Errorf("%s: query %s: undefined variables %v", path, q.Name, missing)
		}
		if !json.Valid(body) {
			return nil, fmt.Errorf("%s: query %s: body is not valid JSON after substitution", path, q.Name)
		}
		var compact bytes.Buffer
		_ = json.Compact(&compact, body)
		qs.Queries[i].Body = compact.Bytes()
	}
	return &qs, nil
}

type SearchConfig struct {
	Index       string
	Concurrency int
	Duration    time.Duration
	Warmup      time.Duration
}

type searchRecord struct {
	TS        string  `json:"ts"`
	Op        string  `json:"op"`
	Query     string  `json:"query"`
	Worker    int     `json:"worker"`
	Status    int     `json:"status"`
	ServiceMS float64 `json:"service_ms"`
	Attempts  int     `json:"attempts"`
	Throttled int     `json:"http_429"`
	Hits      *int64  `json:"hits,omitempty"`
	Error     string  `json:"error,omitempty"`
}

type searchResponse struct {
	TimedOut *bool `json:"timed_out"`
	Shards   *struct {
		Failed   int `json:"failed"`
		Failures []struct {
			Reason struct {
				Type string `json:"type"`
			} `json:"reason"`
		} `json:"failures"`
	} `json:"_shards"`
	Hits *struct {
		Total *struct {
			Value int64 `json:"value"`
		} `json:"total"`
	} `json:"hits"`
}

// classifySearch returns an empty string for a fully successful response, or
// the error type to count. Partial results (shard failures, timeouts) count
// as errors, because their service time is not comparable.
func classifySearch(resp *Response, err error) (string, *int64) {
	if err != nil {
		return "transport_error", nil
	}
	if resp.Status != http.StatusOK {
		return httpErrorType(resp.Status, resp.Body), nil
	}
	var sr searchResponse
	if json.Unmarshal(resp.Body, &sr) != nil || sr.Shards == nil || sr.TimedOut == nil {
		return "malformed_response", nil
	}
	var hits *int64
	if sr.Hits != nil && sr.Hits.Total != nil {
		hits = &sr.Hits.Total.Value
	}
	if sr.Shards.Failed > 0 {
		kind := "shard_failure"
		if len(sr.Shards.Failures) > 0 && sr.Shards.Failures[0].Reason.Type != "" {
			kind += "/" + sr.Shards.Failures[0].Reason.Type
		}
		return kind, hits
	}
	if *sr.TimedOut {
		return "timed_out", hits
	}
	return "", hits
}

type SearchResult struct {
	Total   *Stats
	ByQuery map[string]*Stats
	Elapsed time.Duration
}

func (r *SearchResult) QueryNames() []string {
	names := make([]string, 0, len(r.ByQuery))
	for n := range r.ByQuery {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// RunSearch runs the query set round-robin with cfg.Concurrency workers. A
// worker starts no new request after the deadline; requests started during
// the warmup are sent but not recorded.
func RunSearch(ctx context.Context, c *Client, cfg SearchConfig, qs *QuerySet, rec *RecordWriter) (*SearchResult, error) {
	if cfg.Concurrency < 1 || cfg.Duration <= 0 {
		return nil, fmt.Errorf("concurrency must be at least 1 and duration positive")
	}
	res := &SearchResult{Total: NewStats(), ByQuery: map[string]*Stats{}}
	for _, q := range qs.Queries {
		res.ByQuery[q.Name] = NewStats()
	}
	path := "/" + url.PathEscape(cfg.Index) + "/_search"
	start := time.Now()
	measureFrom := start.Add(cfg.Warmup)
	deadline := measureFrom.Add(cfg.Duration)
	var next atomic.Uint64
	var wg sync.WaitGroup
	for w := 0; w < cfg.Concurrency; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for ctx.Err() == nil {
				sent := time.Now()
				if !sent.Before(deadline) {
					return
				}
				q := qs.Queries[(next.Add(1)-1)%uint64(len(qs.Queries))]
				resp, err := c.Do(ctx, http.MethodPost, path, q.Body, "application/json")
				if ctx.Err() != nil {
					return
				}
				if sent.Before(measureFrom) {
					continue
				}
				kind, hits := classifySearch(resp, err)
				r := searchRecord{
					TS: time.Now().UTC().Format(time.RFC3339Nano), Op: "search", Query: q.Name, Worker: w,
					Hits: hits, Error: kind,
				}
				if resp != nil {
					r.Status, r.ServiceMS, r.Attempts, r.Throttled = resp.Status, ms(resp.Elapsed), resp.Attempts, resp.Throttled
				}
				for _, st := range []*Stats{res.Total, res.ByQuery[q.Name]} {
					st.Lock()
					st.Requests++
					st.HTTP429 += int64(r.Throttled)
					if r.Attempts > 1 {
						st.Retries += int64(r.Attempts - 1)
					}
					if kind == "" {
						st.AddLatency(resp.Elapsed)
					} else {
						st.Failed++
						st.AddError(kind, 1)
					}
					st.Unlock()
				}
				_ = rec.Write(r)
			}
		}(w)
	}
	wg.Wait()
	res.Elapsed = time.Since(measureFrom)
	if res.Elapsed < 0 {
		res.Elapsed = 0
	}
	return res, ctx.Err()
}
