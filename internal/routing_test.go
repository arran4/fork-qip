package qinternal

import (
	"net/http"
	"testing"
)

func TestNewRequestHandlerRedirectsTrailingSlashNever(t *testing.T) {
	resolveCalled := false
	handler := NewRequestHandler(RequestHandlerConfig{
		LogPrefix:    "test",
		RouteOptions: RouteOptions{TrailingSlashMode: TrailingSlashModeNever},
		Resolve: func(r *http.Request, requestID uint64) (RoutedResponse, error) {
			resolveCalled = true
			return RoutedResponse{StatusCode: http.StatusOK}, nil
		},
	})

	resp, err := ServeInProcessHTTP(handler, http.MethodGet, "/foo/", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusPermanentRedirect {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusPermanentRedirect)
	}
	if got := resp.Header.Get("Location"); got != "/foo" {
		t.Fatalf("Location=%q, want %q", got, "/foo")
	}
	if resolveCalled {
		t.Fatal("Resolve should not be called for canonical redirect")
	}
}
