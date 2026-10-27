package main

import (
	"bufio"
	"bytes"
	"compress/bzip2"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// readDocs sends every non-empty line of the inputs, in order, to out. "-"
// means stdin. Files ending in .bz2 or .gz are decompressed on the fly; for
// throughput runs decompress first, since stdlib bzip2 is single-threaded and
// can become the bottleneck. Files are read repeat times; stdin once.
func readDocs(ctx context.Context, inputs []string, repeat int, stdin io.Reader, out chan<- []byte) error {
	if repeat < 1 {
		repeat = 1
	}
	for pass := 0; pass < repeat; pass++ {
		for _, in := range inputs {
			if in == "-" && pass > 0 {
				continue
			}
			if err := readOne(ctx, in, stdin, out); err != nil {
				return err
			}
		}
	}
	return nil
}

func readOne(ctx context.Context, name string, stdin io.Reader, out chan<- []byte) error {
	var r io.Reader
	if name == "-" {
		r = stdin
	} else {
		f, err := os.Open(name)
		if err != nil {
			return err
		}
		defer f.Close()
		r = f
		switch {
		case strings.HasSuffix(name, ".bz2"):
			r = bzip2.NewReader(f)
		case strings.HasSuffix(name, ".gz"):
			gz, err := gzip.NewReader(f)
			if err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
			defer gz.Close()
			r = gz
		}
	}
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		line, err := br.ReadBytes('\n')
		if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 {
			select {
			case out <- trimmed:
			case <-ctx.Done():
				return nil
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
}
