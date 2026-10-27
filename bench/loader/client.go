package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type ClientConfig struct {
	URL         string
	User        string
	Password    string
	CAFile      string
	Insecure    bool
	Connections int
	Timeout     time.Duration
	MaxRetries  int
	BackoffBase time.Duration
	BackoffMax  time.Duration
}

// Client is a plain HTTP client that behaves the same against Elasticsearch
// and OpenSearch: it only uses REST endpoints both engines share.
type Client struct {
	base       string
	user, pass string
	http       *http.Client
	maxRetries int
	backoff    func(attempt int) time.Duration
	sleep      func(ctx context.Context, d time.Duration) error
}

type Response struct {
	Status int
	Body   []byte
	// Elapsed is the service time of the final attempt: request written to
	// response body fully read. Time spent in 429 backoff is excluded.
	Elapsed  time.Duration
	Attempts int
	// Throttled counts HTTP 429 responses received before the final attempt,
	// plus the final one if it was a 429 too.
	Throttled int
}

func NewClient(cfg ClientConfig) (*Client, error) {
	if cfg.URL == "" {
		return nil, errors.New("url is required")
	}
	if cfg.Connections < 1 {
		cfg.Connections = 1
	}
	tlsCfg := &tls.Config{InsecureSkipVerify: cfg.Insecure}
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read ca file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("ca file %s: no certificates found", cfg.CAFile)
		}
		tlsCfg.RootCAs = pool
	}
	tr := &http.Transport{
		Proxy:               nil,
		TLSClientConfig:     tlsCfg,
		MaxConnsPerHost:     cfg.Connections,
		MaxIdleConnsPerHost: cfg.Connections,
		IdleConnTimeout:     90 * time.Second,
		// Asking for gzip would add loader-side decompression to the
		// measured service time.
		DisableCompression: true,
	}
	base, backoffMax := cfg.BackoffBase, cfg.BackoffMax
	if base <= 0 {
		base = 100 * time.Millisecond
	}
	if backoffMax <= 0 {
		backoffMax = 5 * time.Second
	}
	return &Client{
		base:       strings.TrimRight(cfg.URL, "/"),
		user:       cfg.User,
		pass:       cfg.Password,
		http:       &http.Client{Transport: tr, Timeout: cfg.Timeout},
		maxRetries: cfg.MaxRetries,
		backoff: func(attempt int) time.Duration {
			d := base << attempt
			if d > backoffMax || d <= 0 {
				d = backoffMax
			}
			return d
		},
		sleep: sleepCtx,
	}, nil
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Do sends one request and retries only on HTTP 429, at most maxRetries
// times. Any other status is returned to the caller as is.
func (c *Client) Do(ctx context.Context, method, path string, body []byte, contentType string) (*Response, error) {
	resp := &Response{}
	for attempt := 0; ; attempt++ {
		resp.Attempts = attempt + 1
		status, data, elapsed, err := c.once(ctx, method, path, body, contentType)
		if err != nil {
			return resp, err
		}
		resp.Status, resp.Body, resp.Elapsed = status, data, elapsed
		if status != http.StatusTooManyRequests {
			return resp, nil
		}
		resp.Throttled++
		if attempt >= c.maxRetries {
			return resp, nil
		}
		if err := c.sleep(ctx, c.backoff(attempt)); err != nil {
			return resp, err
		}
	}
}

func (c *Client) once(ctx context.Context, method, path string, body []byte, contentType string) (int, []byte, time.Duration, error) {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
	if err != nil {
		return 0, nil, 0, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set("Accept", "application/json")
	if c.user != "" {
		req.SetBasicAuth(c.user, c.pass)
	}
	start := time.Now()
	res, err := c.http.Do(req)
	if err != nil {
		return 0, nil, 0, err
	}
	data, err := io.ReadAll(res.Body)
	res.Body.Close()
	elapsed := time.Since(start)
	if err != nil {
		return res.StatusCode, nil, elapsed, err
	}
	return res.StatusCode, data, elapsed, nil
}
