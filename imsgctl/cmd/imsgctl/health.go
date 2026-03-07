package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/spf13/cobra"
)

const (
	defaultChatDBPath = "~/Library/Messages/chat.db"
	healthTimeout     = 10 * time.Second
)

func newHealthCommand() *cobra.Command {
	var dbPath string
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "health",
		Short: "Check local helper access to Messages",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runHealth(cmd, dbPath, jsonOutput)
		},
	}

	flags := cmd.Flags()
	flags.StringVar(&dbPath, "db", defaultChatDBPath, "path to Messages chat.db")
	flags.BoolVar(&jsonOutput, "json", false, "emit JSON output")

	return cmd
}

func runHealth(cmd *cobra.Command, dbPath string, jsonOutput bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), healthTimeout)
	defer cancel()

	client, err := localtransport.Start(ctx, localtransport.Options{
		DBPath: dbPath,
	})
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("health failed: %w", err)}
	}
	defer client.Close()

	health, err := client.Health(ctx)
	if err != nil {
		return &exitCodeError{code: 1, err: fmt.Errorf("health failed: %w", err)}
	}

	if jsonOutput {
		if err := output.WriteJSON(cmd.OutOrStdout(), health); err != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("write json: %w", err)}
		}
	} else if health.OK {
		_, _ = fmt.Fprintln(cmd.OutOrStdout(), "ok")
	} else {
		_, _ = fmt.Fprintln(cmd.OutOrStdout(), "not ok")
	}

	if !health.OK {
		return &exitCodeError{code: 1}
	}

	return nil
}
