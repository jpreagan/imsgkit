package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/jpreagan/imsgkit/imsgctl/internal/replica"
	"github.com/spf13/cobra"
)

const chatListTimeout = 10 * time.Second

func newChatsCommand() *cobra.Command {
	var dbPath string
	var replicaPath string
	var jsonOutput bool
	var limit int

	cmd := &cobra.Command{
		Use:   "chats",
		Short: "List chats from the source or replica database",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runChats(cmd, dbPath, replicaPath, jsonOutput, limit)
		},
	}

	flags := cmd.Flags()
	addBackendFlags(flags, &dbPath, &replicaPath)
	flags.BoolVar(&jsonOutput, "json", false, "emit JSONL output")
	flags.IntVar(&limit, "limit", 20, "maximum chats to return")

	return cmd
}

func runChats(cmd *cobra.Command, dbPath string, replicaPath string, jsonOutput bool, limit int) error {
	if limit < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("limit must be zero or greater")}
	}

	backend, err := resolveBackendOptions(dbPath, replicaPath)
	if err != nil {
		return &exitCodeError{code: 1, err: err}
	}

	var chats []protocol.ChatSummary
	switch backend.kind {
	case backendReplica:
		chats, err = replica.ListChats(backend.path, limit)
	default:
		ctx, cancel := context.WithTimeout(context.Background(), chatListTimeout)
		defer cancel()

		client, startErr := localtransport.Start(ctx, localtransport.Options{
			DBPath: backend.path,
		})
		if startErr != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("list chats failed: %w", startErr)}
		}
		defer client.Close()

		chats, err = client.ListChats(ctx, limit)
	}
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("list chats failed: %w", err)}
	}

	if jsonOutput {
		for _, chat := range chats {
			if err := output.WriteJSONLine(cmd.OutOrStdout(), chat); err != nil {
				return &exitCodeError{code: 1, err: fmt.Errorf("write json: %w", err)}
			}
		}
		return nil
	}

	for _, chat := range chats {
		_, _ = fmt.Fprintf(
			cmd.OutOrStdout(),
			"[%d] %s last=%s\n",
			chat.ID,
			formatChatName(chat),
			formatLastMessage(chat),
		)
	}

	return nil
}

func formatLastMessage(chat protocol.ChatSummary) string {
	if chat.LastMessageAt == nil || *chat.LastMessageAt == "" {
		return "-"
	}

	return *chat.LastMessageAt
}

func formatChatName(chat protocol.ChatSummary) string {
	label := strings.TrimSpace(chat.Label)
	identifier := strings.TrimSpace(chat.Identifier)

	switch {
	case label == "":
		if identifier == "" {
			return "-"
		}
		return fmt.Sprintf(" (%s)", identifier)
	case identifier == "":
		return label
	case label == identifier:
		return identifier
	case strings.Contains(label, identifier):
		return label
	default:
		return fmt.Sprintf("%s (%s)", label, identifier)
	}
}
