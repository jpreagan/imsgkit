package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/jpreagan/imsgkit/imsgctl/internal/replica"
	"github.com/spf13/cobra"
)

func newWatchCommand() *cobra.Command {
	var dbPath string
	var replicaPath string
	var chatID int64
	var debounce string
	var showAttachments bool
	var includeReactions bool
	var jsonOutput bool
	var start string
	var end string

	cmd := &cobra.Command{
		Use:   "watch",
		Short: "Stream new messages from the source or replica database",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runWatch(
				cmd,
				dbPath,
				replicaPath,
				chatID,
				debounce,
				showAttachments,
				includeReactions,
				jsonOutput,
				start,
				end,
			)
		},
	}

	flags := cmd.Flags()
	addBackendFlags(flags, &dbPath, &replicaPath)
	flags.Int64Var(&chatID, "chat-id", 0, "limit to a specific chat rowid")
	flags.StringVar(&debounce, "debounce", "250ms", "debounce interval for filesystem events")
	flags.BoolVar(&showAttachments, "attachments", false, "include attachment metadata in text output")
	flags.BoolVar(&includeReactions, "reactions", false, "include reaction events in the stream")
	flags.BoolVar(&jsonOutput, "json", false, "emit JSONL output")
	flags.StringVar(&start, "start", "", "ISO8601 start (inclusive)")
	flags.StringVar(&end, "end", "", "ISO8601 end (exclusive)")

	return cmd
}

func runWatch(
	cmd *cobra.Command,
	dbPath string,
	replicaPath string,
	chatID int64,
	debounce string,
	showAttachments bool,
	includeReactions bool,
	jsonOutput bool,
	start string,
	end string,
) error {
	if chatID < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("chat-id must be zero or greater")}
	}

	debounceDuration, err := time.ParseDuration(debounce)
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("invalid debounce duration: %w", err)}
	}
	if debounceDuration < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("debounce must be zero or greater")}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var startFilter *string
	if trimmed := strings.TrimSpace(start); trimmed != "" {
		startFilter = &trimmed
	}
	var endFilter *string
	if trimmed := strings.TrimSpace(end); trimmed != "" {
		endFilter = &trimmed
	}
	var chatIDFilter *int64
	if chatID > 0 {
		chatIDFilter = &chatID
	}

	params := protocol.WatchParams{
		ChatID:               chatIDFilter,
		Start:                startFilter,
		End:                  endFilter,
		DebounceMilliseconds: int(debounceDuration / time.Millisecond),
		IncludeReactions:     includeReactions,
	}

	backend, err := resolveBackendOptions(dbPath, replicaPath)
	if err != nil {
		return &exitCodeError{code: 1, err: err}
	}

	handleEvent := func(event protocol.WatchEvent) error {
		if jsonOutput {
			return output.WriteJSONLine(cmd.OutOrStdout(), event)
		}

		switch event.Event {
		case "message":
			if event.Message == nil {
				return fmt.Errorf("message event missing message payload")
			}
			printWatchMessage(cmd, *event.Message, showAttachments)
			return nil
		case "reaction":
			if event.Reaction == nil {
				return fmt.Errorf("reaction event missing reaction payload")
			}
			printWatchReaction(cmd, *event.Reaction)
			return nil
		default:
			return fmt.Errorf("unknown watch event: %s", event.Event)
		}
	}

	switch backend.kind {
	case backendReplica:
		err = replica.Watch(ctx, backend.path, params, handleEvent)
	default:
		client, startErr := localtransport.Start(ctx, localtransport.Options{
			DBPath: backend.path,
		})
		if startErr != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("watch failed: %w", startErr)}
		}
		defer client.Close()

		err = client.Watch(ctx, params, handleEvent)
	}
	if err != nil && ctx.Err() != nil {
		return nil
	}
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("watch failed: %w", err)}
	}

	return nil
}

func printWatchMessage(cmd *cobra.Command, message protocol.ChatMessage, showAttachments bool) {
	_, _ = fmt.Fprintf(
		cmd.OutOrStdout(),
		"%s [%s] %s: %s\n",
		formatMessageTimestamp(message),
		formatMessageDirection(message),
		formatSenderLabel(message),
		message.Text,
	)

	if len(message.Attachments) == 0 {
		return
	}

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
		return
	}

	_, _ = fmt.Fprintf(
		cmd.OutOrStdout(),
		"  (%d attachment%s)\n",
		len(message.Attachments),
		pluralSuffix(len(message.Attachments)),
	)
}

func printWatchReaction(cmd *cobra.Command, reaction protocol.ReactionEvent) {
	_, _ = fmt.Fprintf(
		cmd.OutOrStdout(),
		"%s [%s] %s %s %s reaction to %s\n",
		formatReactionTimestamp(reaction),
		formatReactionDirection(reaction),
		formatReactionSenderLabel(reaction),
		reaction.Action,
		reaction.Emoji,
		formatReactionTarget(reaction),
	)
}

func formatReactionTimestamp(reaction protocol.ReactionEvent) string {
	if reaction.CreatedAt == nil || *reaction.CreatedAt == "" {
		return "-"
	}

	return *reaction.CreatedAt
}

func formatReactionDirection(reaction protocol.ReactionEvent) string {
	if reaction.FromMe {
		return "sent"
	}

	return "recv"
}

func formatReactionSenderLabel(reaction protocol.ReactionEvent) string {
	if reaction.FromMe {
		if reaction.SenderLabel != nil && *reaction.SenderLabel != "" {
			return *reaction.SenderLabel
		}
		return "Me"
	}
	if reaction.SenderLabel != nil && *reaction.SenderLabel != "" {
		return *reaction.SenderLabel
	}
	if reaction.Sender != "" {
		return reaction.Sender
	}

	return "-"
}

func formatReactionTarget(reaction protocol.ReactionEvent) string {
	target := strings.TrimSpace(reaction.TargetGUID)
	if target == "" {
		return "-"
	}

	return target
}
