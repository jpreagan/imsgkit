package replica

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"

	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
)

func TestGetHistoryIncludesExactStartBoundary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replica.db")
	db := openSQLiteDB(t, path)
	defer db.Close()

	execSQLite(t, db, `
		CREATE TABLE messages (
			message_id INTEGER PRIMARY KEY,
			chat_id INTEGER NOT NULL,
			guid TEXT NOT NULL,
			reply_to_guid TEXT,
			thread_originator_guid TEXT,
			sender TEXT NOT NULL,
			sender_name TEXT,
			sender_label TEXT,
			from_me INTEGER NOT NULL,
			text TEXT NOT NULL,
			created_at TEXT,
			service TEXT NOT NULL,
			destination_caller_id TEXT,
			attachments_json TEXT NOT NULL,
			reactions_json TEXT NOT NULL
		);
	`)
	execSQLite(t, db, `
		INSERT INTO messages (
			message_id, chat_id, guid, sender, from_me, text, created_at, service, attachments_json, reactions_json
		) VALUES
			(100, 10, 'message-100', '+12125550100', 0, 'exact boundary', '2001-01-01T00:00:01.000Z', 'iMessage', '[]', '[]'),
			(101, 10, 'message-101', '+12125550100', 0, 'middle', '2001-01-01T00:00:01.500Z', 'iMessage', '[]', '[]'),
			(102, 10, 'message-102', '+12125550100', 0, 'end boundary', '2001-01-01T00:00:02.000Z', 'iMessage', '[]', '[]');
	`)

	start := "2001-01-01T00:00:01Z"
	end := "2001-01-01T00:00:02Z"
	messages, err := GetHistory(path, 10, 10, &start, &end)
	if err != nil {
		t.Fatalf("GetHistory() error = %v", err)
	}

	if len(messages) != 2 {
		t.Fatalf("len(messages) = %d, want 2", len(messages))
	}
	if messages[0].GUID != "message-101" {
		t.Fatalf("messages[0].GUID = %q, want %q", messages[0].GUID, "message-101")
	}
	if messages[1].GUID != "message-100" {
		t.Fatalf("messages[1].GUID = %q, want %q", messages[1].GUID, "message-100")
	}
}

func TestWatchIncludesExactStartBoundary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replica.db")
	db := openSQLiteDB(t, path)
	defer db.Close()

	execSQLite(t, db, `
		CREATE TABLE watch_events (
			source_rowid INTEGER PRIMARY KEY,
			event_type TEXT NOT NULL,
			chat_id INTEGER NOT NULL,
			created_at TEXT,
			payload_json TEXT NOT NULL
		);
	`)

	insertWatchEvent(t, db, 100, "2001-01-01T00:00:01.000Z", protocol.WatchEvent{
		Event: "message",
		Message: &protocol.ChatMessage{
			ID:        100,
			ChatID:    10,
			GUID:      "message-100",
			Sender:    "+12125550100",
			Text:      "exact boundary",
			CreatedAt: stringPtr("2001-01-01T00:00:01.000Z"),
			Service:   "iMessage",
		},
	})
	insertWatchEvent(t, db, 101, "2001-01-01T00:00:01.500Z", protocol.WatchEvent{
		Event: "message",
		Message: &protocol.ChatMessage{
			ID:        101,
			ChatID:    10,
			GUID:      "message-101",
			Sender:    "+12125550100",
			Text:      "middle",
			CreatedAt: stringPtr("2001-01-01T00:00:01.500Z"),
			Service:   "iMessage",
		},
	})
	insertWatchEvent(t, db, 102, "2001-01-01T00:00:02.000Z", protocol.WatchEvent{
		Event: "message",
		Message: &protocol.ChatMessage{
			ID:        102,
			ChatID:    10,
			GUID:      "message-102",
			Sender:    "+12125550100",
			Text:      "end boundary",
			CreatedAt: stringPtr("2001-01-01T00:00:02.000Z"),
			Service:   "iMessage",
		},
	})

	start := "2001-01-01T00:00:01Z"
	end := "2001-01-01T00:00:02Z"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var events []protocol.WatchEvent
	err := Watch(ctx, path, protocol.WatchParams{
		Start: &start,
		End:   &end,
	}, func(event protocol.WatchEvent) error {
		events = append(events, event)
		if len(events) == 2 {
			cancel()
		}
		return nil
	})
	if err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Watch() error = %v, want nil or context.Canceled", err)
	}

	if len(events) != 2 {
		t.Fatalf("len(events) = %d, want 2", len(events))
	}
	if events[0].Message == nil || events[0].Message.GUID != "message-100" {
		t.Fatalf("events[0] = %#v, want first boundary message", events[0])
	}
	if events[1].Message == nil || events[1].Message.GUID != "message-101" {
		t.Fatalf("events[1] = %#v, want second message", events[1])
	}
}

func openSQLiteDB(t *testing.T, path string) *sql.DB {
	t.Helper()

	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	return db
}

func execSQLite(t *testing.T, db *sql.DB, query string) {
	t.Helper()

	if _, err := db.Exec(query); err != nil {
		t.Fatalf("db.Exec() error = %v", err)
	}
}

func insertWatchEvent(t *testing.T, db *sql.DB, rowID int64, createdAt string, event protocol.WatchEvent) {
	t.Helper()

	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}

	if _, err := db.Exec(
		`INSERT INTO watch_events (source_rowid, event_type, chat_id, created_at, payload_json) VALUES (?, 'message', 10, ?, ?)`,
		rowID,
		createdAt,
		string(payload),
	); err != nil {
		t.Fatalf("db.Exec() error = %v", err)
	}
}

func stringPtr(value string) *string {
	return &value
}
