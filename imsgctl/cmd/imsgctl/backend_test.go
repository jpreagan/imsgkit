package main

import "testing"

func TestResolveBackendOptionsDefaultsToSourceDB(t *testing.T) {
	backend, err := resolveBackendOptions("", "")
	if err != nil {
		t.Fatalf("resolveBackendOptions() error = %v", err)
	}
	if backend.kind != backendSource {
		t.Fatalf("backend.kind = %q, want %q", backend.kind, backendSource)
	}
	if backend.path != expandPath(defaultChatDBPath) {
		t.Fatalf("backend.path = %q, want %q", backend.path, expandPath(defaultChatDBPath))
	}
}

func TestResolveBackendOptionsUsesReplicaPathWhenRequested(t *testing.T) {
	backend, err := resolveBackendOptions("", "~/replica.db")
	if err != nil {
		t.Fatalf("resolveBackendOptions() error = %v", err)
	}
	if backend.kind != backendReplica {
		t.Fatalf("backend.kind = %q, want %q", backend.kind, backendReplica)
	}
	if backend.path == "~/replica.db" {
		t.Fatalf("backend.path was not expanded: %q", backend.path)
	}
}

func TestResolveBackendOptionsRejectsConflictingFlags(t *testing.T) {
	_, err := resolveBackendOptions("~/Library/Messages/chat.db", "~/replica.db")
	if err == nil {
		t.Fatal("resolveBackendOptions() error = nil, want conflict")
	}
}
