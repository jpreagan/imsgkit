package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jpreagan/imsgkit/imsgctl/internal/localtransport"
	"github.com/jpreagan/imsgkit/imsgctl/internal/output"
	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
	"github.com/jpreagan/imsgkit/imsgctl/internal/replica"
	"github.com/spf13/cobra"
)

const (
	defaultChatDBPath = "~/Library/Messages/chat.db"
	healthTimeout     = 10 * time.Second
)

func newHealthCommand() *cobra.Command {
	var dbPath string
	var replicaPath string
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "health",
		Short: "Check local source or replica database access",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runHealth(cmd, dbPath, replicaPath, jsonOutput)
		},
	}

	flags := cmd.Flags()
	addBackendFlags(flags, &dbPath, &replicaPath)
	flags.BoolVar(&jsonOutput, "json", false, "emit JSON output")

	return cmd
}

func runHealth(cmd *cobra.Command, dbPath string, replicaPath string, jsonOutput bool) error {
	backend, err := resolveBackendOptions(dbPath, replicaPath)
	if err != nil {
		return &exitCodeError{code: 1, err: err}
	}

	var health protocol.HealthResponse
	switch backend.kind {
	case backendReplica:
		health, err = replica.Health(backend.path)
		if err != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("health failed: %w", err)}
		}
	default:
		ctx, cancel := context.WithTimeout(context.Background(), healthTimeout)
		defer cancel()

		client, err := localtransport.Start(ctx, localtransport.Options{
			DBPath: backend.path,
		})
		if err != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("health failed: %w", err)}
		}
		defer client.Close()

		health, err = client.Health(ctx)
		if err != nil {
			return &exitCodeError{code: 1, err: fmt.Errorf("health failed: %w", err)}
		}
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
