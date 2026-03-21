package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestResolveBackendOptionsDefaultsToSourceDB(t *testing.T) {
	backend, err := resolveBackendOptions("")
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

func TestResolveBackendOptionsDetectsReplicaDB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replica.db")
	createSQLiteDB(t, path, `
		CREATE TABLE metadata (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		);
		INSERT INTO metadata (key, value) VALUES ('schema_version', '1');
	`)

	backend, err := resolveBackendOptions(path)
	if err != nil {
		t.Fatalf("resolveBackendOptions() error = %v", err)
	}
	if backend.kind != backendReplica {
		t.Fatalf("backend.kind = %q, want %q", backend.kind, backendReplica)
	}
	if backend.path != path {
		t.Fatalf("backend.path = %q, want %q", backend.path, path)
	}
}

func TestResolveBackendOptionsTreatsNonReplicaSQLiteDBAsSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")
	createSQLiteDB(t, path, `CREATE TABLE message (ROWID INTEGER PRIMARY KEY);`)

	backend, err := resolveBackendOptions(path)
	if err != nil {
		t.Fatalf("resolveBackendOptions() error = %v", err)
	}
	if backend.kind != backendSource {
		t.Fatalf("backend.kind = %q, want %q", backend.kind, backendSource)
	}
	if backend.path != path {
		t.Fatalf("backend.path = %q, want %q", backend.path, path)
	}
}

func TestExpandPathExpandsHomePrefix(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got := expandPath("~/replica.db")
	want := filepath.Join(home, "replica.db")
	if got != want {
		t.Fatalf("expandPath() = %q, want %q", got, want)
	}
}

func TestReplicaDBExamplePathForDarwin(t *testing.T) {
	got := replicaDBExamplePathFor("darwin", "/tmp/home", "")
	want := "~/Library/Application\\ Support/imsgkit/replica.db"
	if got != want {
		t.Fatalf("replicaDBExamplePathFor() = %q, want %q", got, want)
	}
}

func TestReplicaDBExamplePathForLinuxUsesXDGDataHome(t *testing.T) {
	got := replicaDBExamplePathFor("linux", "/tmp/home", "/tmp/data")
	want := "/tmp/data/imsgkit/replica.db"
	if got != want {
		t.Fatalf("replicaDBExamplePathFor() = %q, want %q", got, want)
	}
}

func TestReplicaDBExamplePathForLinuxFallsBackToHomeDataDir(t *testing.T) {
	got := replicaDBExamplePathFor("linux", "/tmp/home", "")
	want := "~/.local/share/imsgkit/replica.db"
	if got != want {
		t.Fatalf("replicaDBExamplePathFor() = %q, want %q", got, want)
	}
}

func createSQLiteDB(t *testing.T, path string, statements string) {
	t.Helper()

	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	defer db.Close()

	if _, err := db.Exec(statements); err != nil {
		t.Fatalf("db.Exec() error = %v", err)
	}
}
