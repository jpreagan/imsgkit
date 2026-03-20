package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

type exitCodeError struct {
	code int
	err  error
}

func (e *exitCodeError) Error() string {
	if e.err == nil {
		return ""
	}

	return e.err.Error()
}

func execute() int {
	rootCmd := newRootCommand()
	rootCmd.SetArgs(normalizeReplicaFlagArgs(os.Args[1:]))

	if err := rootCmd.Execute(); err != nil {
		var exitErr *exitCodeError
		if errors.As(err, &exitErr) {
			if exitErr.err != nil && exitErr.err.Error() != "" {
				_, _ = fmt.Fprintln(os.Stderr, exitErr.err)
			}
			return exitErr.code
		}

		if err.Error() != "" {
			_, _ = fmt.Fprintln(os.Stderr, err)
		}
		return 1
	}

	return 0
}

func normalizeReplicaFlagArgs(args []string) []string {
	normalized := make([]string, 0, len(args))
	for index := 0; index < len(args); index++ {
		argument := args[index]
		if argument == "--replica" && index+1 < len(args) {
			nextArgument := args[index+1]
			if nextArgument != "" && nextArgument[0] != '-' {
				normalized = append(normalized, "--replica="+nextArgument)
				index++
				continue
			}
		}
		normalized = append(normalized, argument)
	}

	return normalized
}

func newRootCommand() *cobra.Command {
	rootCmd := &cobra.Command{
		Use:           "imsgctl",
		SilenceErrors: true,
		SilenceUsage:  true,
		Version:       version,
		CompletionOptions: cobra.CompletionOptions{
			DisableDefaultCmd: true,
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = cmd.Usage()
			return &exitCodeError{code: 1}
		},
	}

	rootCmd.SetOut(os.Stdout)
	rootCmd.SetErr(os.Stderr)
	rootCmd.SetVersionTemplate("{{.Version}}\n")
	rootCmd.AddCommand(
		newChatsCommand(),
		newHealthCommand(),
		newHistoryCommand(),
		newWatchCommand(),
		newVersionCommand(),
	)

	return rootCmd
}

func newVersionCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the imsgctl version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			_, _ = fmt.Fprintln(cmd.OutOrStdout(), version)
			return nil
		},
	}
}
