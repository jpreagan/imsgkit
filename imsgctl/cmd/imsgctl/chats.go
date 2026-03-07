package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/spf13/cobra"
)

const chatListTimeout = 10 * time.Second

func newChatsCommand() *cobra.Command {
	var dbPath string
	var jsonOutput bool
	var limit int

	cmd := &cobra.Command{
		Use:   "chats",
		Short: "List chats from the Messages database",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runChats(cmd, dbPath, jsonOutput, limit)
		},
	}

	flags := cmd.Flags()
	flags.StringVar(&dbPath, "db", defaultChatDBPath, "path to Messages chat.db")
	flags.BoolVar(&jsonOutput, "json", false, "emit JSON output")
	flags.IntVar(&limit, "limit", 20, "maximum chats to return")

	return cmd
}

func runChats(cmd *cobra.Command, dbPath string, jsonOutput bool, limit int) error {
	if limit < 0 {
		return &exitCodeError{code: 1, err: fmt.Errorf("limit must be zero or greater")}
	}

	ctx, cancel := context.WithTimeout(context.Background(), chatListTimeout)
	defer cancel()

	client, err := localtransport.Start(ctx, localtransport.Options{
		DBPath: dbPath,
	})
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("list chats failed: %w", err)}
	}
	defer client.Close()

	chats, err := client.ListChats(ctx, limit)
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("list chats failed: %w", err)}
	}

	if jsonOutput {
		if err := output.WriteJSON(cmd.OutOrStdout(), chats); err != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("write json: %w", err)}
		}
		return nil
	}

	for _, chat := range chats {
		_, _ = fmt.Fprintf(cmd.OutOrStdout(), "[%d] %s last=%s\n", chat.ChatID, chat.Label, formatLastMessage(chat))
	}

	return nil
}

func formatLastMessage(chat protocol.ChatSummary) string {
	if chat.LastMessageAt == nil || *chat.LastMessageAt == "" {
		return "-"
	}

	return *chat.LastMessageAt
}
