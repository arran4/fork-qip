package cmd

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestNormalizeRouteWarcArgs(t *testing.T) {
	in := []string{"docs/", "--recipes", "recipes/", "--host", "example.com", "-X", "HEAD", "-o", "out.warc"}
	got := normalizeRouteWarcArgs(in)
	want := []string{"--recipes", "recipes/", "--host", "example.com", "-X", "HEAD", "-o", "out.warc", "docs/"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}
}

func TestRunRouteWARCArchivesAllPaths(t *testing.T) {
	var out bytes.Buffer
	var listed bool
	resolved := make([]string, 0, 2)
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			listed = true
			if request.ContentRoot != "docs" {
				t.Fatalf("content root=%q, want docs", request.ContentRoot)
			}
			return []string{"/b", "/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			resolved = append(resolved, request.RequestPath)
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok-" + request.RequestPath),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if !listed {
		t.Fatalf("expected ListWARCPaths to be called")
	}
	if !reflect.DeepEqual(resolved, []string{"/a", "/b"}) {
		t.Fatalf("resolved=%v, want [/a /b]", resolved)
	}
	if got := strings.Count(out.String(), "WARC/1.0\r\n"); got != 2 {
		t.Fatalf("record count=%d, want 2", got)
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://qip.local/a\r\n") {
		t.Fatalf("missing URI for /a")
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://qip.local/b\r\n") {
		t.Fatalf("missing URI for /b")
	}
}

func TestRunRouteWARCNoPaths(t *testing.T) {
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return nil, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, errors.New("should not be called")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "no route paths found to archive") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCCustomHost(t *testing.T) {
	var out bytes.Buffer
	err := RunRoute([]string{"warc", "--host", "example.com", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			if request.Host != "example.com" {
				t.Fatalf("host=%q, want example.com", request.Host)
			}
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://example.com/a\r\n") {
		t.Fatalf("missing custom-host URI")
	}
}

func TestRunRouteWARCRejectsInvalidHost(t *testing.T) {
	err := RunRoute([]string{"warc", "--host", "https://example.com", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "invalid host") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildMinimalWARCResponseRecord(t *testing.T) {
	resp := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header: http.Header{
			"Content-Type": []string{"text/plain; charset=utf-8"},
		},
		Body: []byte("hello"),
	}

	out, err := buildMinimalWARCResponseRecord("http://qip.local/about", resp)
	if err != nil {
		t.Fatalf("buildMinimalWARCResponseRecord: %v", err)
	}

	checks := []string{
		"WARC/1.0\r\n",
		"WARC-Type: response\r\n",
		"WARC-Target-URI: http://qip.local/about\r\n",
		"Content-Type: application/http; msgtype=response\r\n",
		"HTTP/1.1 200 OK\r\n",
		"Content-Length: 5\r\n",
		"\r\nhello\r\n\r\n",
	}
	for _, check := range checks {
		if !bytes.Contains(out, []byte(check)) {
			t.Fatalf("missing %q in WARC output", check)
		}
	}
}
