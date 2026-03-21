package replica

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
)

const schemaVersion = "1"

func Health(path string) (protocol.HealthResponse, error) {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return protocol.HealthResponse{
				OK:              false,
				ReadOnly:        true,
				DBPath:          path,
				DBExists:        false,
				CanReadDB:       false,
				SQLiteOpenOK:    false,
				ProtocolVersion: protocol.ProtocolVersion,
			}, nil
		}
		return protocol.HealthResponse{}, fmt.Errorf("stat replica: %w", err)
	}

	health := protocol.HealthResponse{
		ReadOnly:        true,
		DBPath:          path,
		DBExists:        !info.IsDir(),
		CanReadDB:       !info.IsDir(),
		ProtocolVersion: protocol.ProtocolVersion,
	}
	if info.IsDir() {
		return health, nil
	}

	db, err := open(path)
	if err != nil {
		return health, nil
	}
	defer db.Close()

	health.SQLiteOpenOK = true

	var version string
	if err := db.QueryRow(`SELECT value FROM metadata WHERE key = 'schema_version'`).Scan(&version); err != nil {
		return health, nil
	}
	if version != schemaVersion {
		return health, nil
	}

	_ = db.QueryRow(`SELECT value FROM metadata WHERE key = 'builder_version'`).Scan(&health.ServerVersion)
	health.OK = true
	return health, nil
}

func ListChats(path string, limit int) ([]protocol.ChatSummary, error) {
	if limit < 0 {
		return nil, fmt.Errorf("limit must be zero or greater")
	}
	if limit == 0 {
		return []protocol.ChatSummary{}, nil
	}

	db, err := open(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	rows, err := db.Query(
		`
		SELECT
			chat_id,
			service,
			identifier,
			label,
			contact_name,
			participant_count,
			participants_json,
			last_message_at,
			message_count
		FROM chats
		ORDER BY
			CASE WHEN last_message_at IS NULL THEN 1 ELSE 0 END,
			last_message_at DESC,
			chat_id DESC
		LIMIT ?
		`,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query chats: %w", err)
	}
	defer rows.Close()

	var chats []protocol.ChatSummary
	for rows.Next() {
		var chat protocol.ChatSummary
		var participantsJSON string
		if err := rows.Scan(
			&chat.ID,
			&chat.Service,
			&chat.Identifier,
			&chat.Label,
			&chat.ContactName,
			&chat.ParticipantCount,
			&participantsJSON,
			&chat.LastMessageAt,
			&chat.MessageCount,
		); err != nil {
			return nil, fmt.Errorf("scan chats: %w", err)
		}
		if err := json.Unmarshal([]byte(participantsJSON), &chat.Participants); err != nil {
			return nil, fmt.Errorf("decode participants: %w", err)
		}
		chats = append(chats, chat)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate chats: %w", err)
	}
	return chats, nil
}

func GetHistory(
	path string,
	chatID int64,
	limit int,
	start *string,
	end *string,
) ([]protocol.ChatMessage, error) {
	if chatID <= 0 {
		return nil, fmt.Errorf("chat-id must be greater than zero")
	}
	if limit < 0 {
		return nil, fmt.Errorf("limit must be zero or greater")
	}
	if limit == 0 {
		return []protocol.ChatMessage{}, nil
	}

	db, err := open(path)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	rows, err := db.Query(
		`
		SELECT
			message_id,
			chat_id,
			guid,
			reply_to_guid,
			thread_originator_guid,
			sender,
			sender_name,
			sender_label,
			from_me,
			text,
			created_at,
			service,
			destination_caller_id,
			attachments_json,
			reactions_json
		FROM messages
		WHERE chat_id = ?
		  AND (? = '' OR (created_at IS NOT NULL AND created_at >= ?))
		  AND (? = '' OR (created_at IS NOT NULL AND created_at < ?))
		ORDER BY created_at DESC, message_id DESC
		LIMIT ?
		`,
		chatID,
		stringOrEmpty(start),
		stringOrEmpty(start),
		stringOrEmpty(end),
		stringOrEmpty(end),
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query history: %w", err)
	}
	defer rows.Close()

	var messages []protocol.ChatMessage
	for rows.Next() {
		message, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, message)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate history: %w", err)
	}

	return messages, nil
}

func Watch(
	ctx context.Context,
	path string,
	params protocol.WatchParams,
	handle func(protocol.WatchEvent) error,
) error {
	db, err := open(path)
	if err != nil {
		return err
	}
	defer db.Close()

	cursor, err := maxWatchRowID(db)
	if err != nil {
		return fmt.Errorf("watch cursor: %w", err)
	}

	if params.Start != nil || params.End != nil {
		if err := replayWatchBatch(db, 0, cursor, params, handle); err != nil {
			return err
		}
	}

	interval := time.Duration(params.DebounceMilliseconds) * time.Millisecond
	if interval <= 0 {
		interval = 250 * time.Millisecond
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			upper, err := maxWatchRowID(db)
			if err != nil {
				return fmt.Errorf("watch upper bound: %w", err)
			}
			if upper <= cursor {
				continue
			}

			if err := replayWatchBatch(db, cursor, upper, params, handle); err != nil {
				return err
			}
			cursor = upper
		}
	}
}

func replayWatchBatch(
	db *sql.DB,
	afterRowID int64,
	throughRowID int64,
	params protocol.WatchParams,
	handle func(protocol.WatchEvent) error,
) error {
	rows, err := db.Query(
		`
		SELECT payload_json
		FROM watch_events
		WHERE source_rowid > ?
		  AND source_rowid <= ?
		  AND (? IS NULL OR chat_id = ?)
		  AND (? = 1 OR event_type <> 'reaction')
		  AND (? = '' OR (created_at IS NOT NULL AND created_at >= ?))
		  AND (? = '' OR (created_at IS NOT NULL AND created_at < ?))
		ORDER BY source_rowid ASC
		`,
		afterRowID,
		throughRowID,
		params.ChatID,
		params.ChatID,
		boolToInt(params.IncludeReactions),
		stringOrEmpty(params.Start),
		stringOrEmpty(params.Start),
		stringOrEmpty(params.End),
		stringOrEmpty(params.End),
	)
	if err != nil {
		return fmt.Errorf("query watch events: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var payload string
		if err := rows.Scan(&payload); err != nil {
			return fmt.Errorf("scan watch event: %w", err)
		}

		var event protocol.WatchEvent
		if err := json.Unmarshal([]byte(payload), &event); err != nil {
			return fmt.Errorf("decode watch event: %w", err)
		}

		if err := handle(event); err != nil {
			return err
		}
	}

	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate watch events: %w", err)
	}

	return nil
}

func maxWatchRowID(db *sql.DB) (int64, error) {
	var rowID int64
	if err := db.QueryRow(`SELECT COALESCE(MAX(source_rowid), 0) FROM watch_events`).Scan(&rowID); err != nil {
		return 0, fmt.Errorf("max watch row id: %w", err)
	}
	return rowID, nil
}

func scanMessage(scanner interface{ Scan(dest ...any) error }) (protocol.ChatMessage, error) {
	var message protocol.ChatMessage
	var fromMe int64
	var attachmentsJSON string
	var reactionsJSON string
	if err := scanner.Scan(
		&message.ID,
		&message.ChatID,
		&message.GUID,
		&message.ReplyToGUID,
		&message.ThreadOriginatorGUID,
		&message.Sender,
		&message.SenderName,
		&message.SenderLabel,
		&fromMe,
		&message.Text,
		&message.CreatedAt,
		&message.Service,
		&message.DestinationCallerID,
		&attachmentsJSON,
		&reactionsJSON,
	); err != nil {
		return protocol.ChatMessage{}, fmt.Errorf("scan message: %w", err)
	}
	message.FromMe = fromMe != 0
	if err := json.Unmarshal([]byte(attachmentsJSON), &message.Attachments); err != nil {
		return protocol.ChatMessage{}, fmt.Errorf("decode attachments: %w", err)
	}
	if err := json.Unmarshal([]byte(reactionsJSON), &message.Reactions); err != nil {
		return protocol.ChatMessage{}, fmt.Errorf("decode reactions: %w", err)
	}
	return message, nil
}

func open(path string) (*sql.DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("replica path is required")
	}
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("open replica: %w", err)
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open replica: %w", err)
	}
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("open replica: %w", err)
	}
	return db, nil
}

func stringOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
