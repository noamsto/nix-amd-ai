package bench

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWaitReady_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	err := waitReady(srv.URL, 2*time.Second)
	if err != nil {
		t.Fatalf("waitReady returned error: %v", err)
	}
}

func TestWaitReady_Timeout(t *testing.T) {
	// Use a non-routable address (unreachable host) with a very short timeout.
	err := waitReady("http://192.0.2.1:9999", 300*time.Millisecond)
	if err == nil {
		t.Fatal("waitReady should have returned an error on unreachable host")
	}
}

func TestWaitReady_NonOKStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	err := waitReady(srv.URL, 400*time.Millisecond)
	if err == nil {
		t.Fatal("waitReady should return error when server returns non-200")
	}
}

func TestFindFreePort(t *testing.T) {
	port, err := FindFreePort()
	if err != nil {
		t.Fatalf("FindFreePort returned error: %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Fatalf("FindFreePort returned invalid port: %d", port)
	}
}
