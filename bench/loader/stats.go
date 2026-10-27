package main

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Stats is safe for concurrent use. Latencies are recorded only for
// requests that succeeded; failures are counted by error type instead.
type Stats struct {
	mu         sync.Mutex
	lat        []time.Duration
	Requests   int64
	Failed     int64
	DocsOK     int64
	DocsFailed int64
	SrcBytes   int64
	HTTP429    int64
	Item429    int64
	Retries    int64
	Errors     map[string]int64
}

func NewStats() *Stats {
	return &Stats{Errors: map[string]int64{}}
}

func (s *Stats) Lock()   { s.mu.Lock() }
func (s *Stats) Unlock() { s.mu.Unlock() }

// AddLatency and AddError expect the caller to hold the lock.
func (s *Stats) AddLatency(d time.Duration) { s.lat = append(s.lat, d) }
func (s *Stats) AddError(kind string, n int64) {
	if n > 0 {
		s.Errors[kind] += n
	}
}

// Percentile uses the nearest-rank method on successful service times.
func (s *Stats) Percentile(p float64) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return percentile(s.lat, p)
}

func percentile(lat []time.Duration, p float64) time.Duration {
	if len(lat) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), lat...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	rank := int(math.Ceil(p / 100 * float64(len(sorted))))
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}

func (s *Stats) Max() time.Duration {
	return s.Percentile(100)
}

// ErrorString renders the error counters as "type=count;type=count", sorted
// by type, for a single CSV column.
func (s *Stats) ErrorString() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	keys := make([]string, 0, len(s.Errors))
	for k := range s.Errors {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + strconv.FormatInt(s.Errors[k], 10)
	}
	return strings.Join(parts, ";")
}

func ms(d time.Duration) float64 {
	return math.Round(float64(d)/float64(time.Millisecond)*1000) / 1000
}
