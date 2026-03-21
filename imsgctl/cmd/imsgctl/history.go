package main

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/jpreagan/imsgkit/imsgctl/internal/replica"
	"github.com/spf13/cobra"
)

const historyTimeout = 10 * time.Second

func newHistoryCommand() *cobra.Command {
	var dbPath string
	var showAttachments bool
	var jsonOutput bool
	var chatID int64
	var limit int
	var start string
	var end string

	cmd := &cobra.Command{
		Use:   "history",
		Short: "List messages from a chat in a database",
		Example: "imsgctl history --chat-id 42 --limit 20\n" +
			"imsgctl history --db " + replicaDBExamplePath() + " --chat-id 42 --limit 20",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runHistory(
				cmd,
				dbPath,
				jsonOutput,
				showAttachments,
				chatID,
				limit,
				start,
				end,
			)
		},
	}

	flags := cmd.Flags()
	addBackendFlags(flags, &dbPath)
	flags.BoolVar(&showAttachments, "attachments", false, "include attachment metadata in text output")
	flags.BoolVar(&jsonOutput, "json", false, "emit JSONL output")
	flags.Int64Var(&chatID, "chat-id", 0, "chat ID")
	flags.IntVar(&limit, "limit", 50, "maximum messages to return")
	flags.StringVar(&start, "start", "", "ISO8601 start (inclusive)")
	flags.StringVar(&end, "end", "", "ISO8601 end (exclusive)")
	_ = cmd.MarkFlagRequired("chat-id")

	return cmd
}

func runHistory(
	cmd *cobra.Command,
	dbPath string,
	jsonOutput bool,
	showAttachments bool,
	chatID int64,
	limit int,
	start string,
	end string,
) error {
	if chatID <= 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("chat-id must be greater than zero")}
	}
	if limit < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("limit must be zero or greater")}
	}

	var startFilter *string
	if start != "" {
		startFilter = &start
	}
	var endFilter *string
	if end != "" {
		endFilter = &end
	}

	backend, err := resolveBackendOptions(dbPath)
	if err != nil {
		return &exitCodeError{code: 1, err: err}
	}

	var messages []protocol.ChatMessage
	switch backend.kind {
	case backendReplica:
		messages, err = replica.GetHistory(backend.path, chatID, limit, startFilter, endFilter)
	default:
		ctx, cancel := context.WithTimeout(context.Background(), historyTimeout)
		defer cancel()

		client, startErr := localtransport.Start(ctx, localtransport.Options{
			DBPath: backend.path,
		})
		if startErr != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("get history failed: %w", startErr)}
		}
		defer client.Close()

		messages, err = client.GetHistory(ctx, chatID, limit, startFilter, endFilter)
	}
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("get history failed: %w", err)}
	}

	if jsonOutput {
		for _, message := range messages {
			if err := output.WriteJSONLine(cmd.OutOrStdout(), message); err != nil {
				return &exitCodeError{code: 1, err: fmt.Errorf("write json: %w", err)}
			}
		}
		return nil
	}

	for _, message := range messages {
		_, _ = fmt.Fprintf(
			cmd.OutOrStdout(),
			"%s [%s] %s: %s\n",
			formatMessageTimestamp(message),
			formatMessageDirection(message),
			formatSenderLabel(message),
			message.Text,
		)
		if len(message.Attachments) > 0 {
			if showAttachments {
				for _, attachment := range message.Attachments {
					_, _ = fmt.Fprintf(
						cmd.OutOrStdout(),
						"  attachment: name=%s mime=%s missing=%t path=%s\n",
						formatAttachmentName(attachment),
						attachment.MimeType,
						attachment.Missing,
						attachment.OriginalPath,
					)
				}
			} else {
				_, _ = fmt.Fprintf(
					cmd.OutOrStdout(),
					"  (%d attachment%s)\n",
					len(message.Attachments),
					pluralSuffix(len(message.Attachments)),
				)
			}
		}
	}

	return nil
}

func formatMessageTimestamp(message protocol.ChatMessage) string {
	if message.CreatedAt == nil || *message.CreatedAt == "" {
		return "-"
	}

	return *message.CreatedAt
}

func formatSenderLabel(message protocol.ChatMessage) string {
	if message.FromMe {
		if message.SenderLabel != nil && *message.SenderLabel != "" {
			return *message.SenderLabel
		}
		return "Me"
	}
	if message.SenderLabel != nil && *message.SenderLabel != "" {
		return *message.SenderLabel
	}
	if message.Sender != "" {
		return message.Sender
	}

	return "-"
}

func formatMessageDirection(message protocol.ChatMessage) string {
	if message.FromMe {
		return "sent"
	}

	return "recv"
}

func pluralSuffix(count int) string {
	if count == 1 {
		return ""
	}

	return "s"
}

func formatAttachmentName(attachment protocol.AttachmentMeta) string {
	if attachment.TransferName != "" {
		return attachment.TransferName
	}
	if attachment.Filename != "" {
		return filepath.Base(attachment.Filename)
	}
	if attachment.OriginalPath != "" {
		return filepath.Base(attachment.OriginalPath)
	}

	return "-"
}
