package main

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/spf13/cobra"
)

const historyTimeout = 10 * time.Second

func newHistoryCommand() *cobra.Command {
	var dbPath string
	var showAttachments bool
	var jsonOutput bool
	var chatID int64
	var limit int
	var before int64

	cmd := &cobra.Command{
		Use:   "history",
		Short: "List messages from a chat",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runHistory(cmd, dbPath, jsonOutput, showAttachments, chatID, limit, before)
		},
	}

	flags := cmd.Flags()
	flags.StringVar(&dbPath, "db", defaultChatDBPath, "path to Messages chat.db")
	flags.BoolVar(&showAttachments, "attachments", false, "include attachment metadata in text output")
	flags.BoolVar(&jsonOutput, "json", false, "emit JSONL output")
	flags.Int64Var(&chatID, "chat-id", 0, "chat identifier from imsgctl chats")
	flags.IntVar(&limit, "limit", 50, "maximum messages to return")
	flags.Int64Var(&before, "before", 0, "return messages before this message_id cursor")
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
	before int64,
) error {
	if chatID <= 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("chat-id must be greater than zero")}
	}
	if limit < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("limit must be zero or greater")}
	}
	if before < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("before must be zero or greater")}
	}

	ctx, cancel := context.WithTimeout(context.Background(), historyTimeout)
	defer cancel()

	client, err := localtransport.Start(ctx, localtransport.Options{
		DBPath: dbPath,
	})
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("get history failed: %w", err)}
	}
	defer client.Close()

	var beforeCursor *int64
	if before > 0 {
		beforeCursor = &before
	}

	messages, err := client.GetHistory(ctx, chatID, limit, beforeCursor)
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
