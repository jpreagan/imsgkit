package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/spf13/pflag"
)

type backendKind string

const (
	backendSource  backendKind = "source"
	backendReplica backendKind = "replica"
)

type backendOptions struct {
	kind backendKind
	path string
}

func addBackendFlags(flags *pflag.FlagSet, dbPath *string, replicaPath *string) {
	flags.StringVar(dbPath, "db", "", "path to Messages chat.db")
	flags.StringVar(replicaPath, "replica", "", "path to replica.db")

	replicaFlag := flags.Lookup("replica")
	if replicaFlag != nil {
		replicaFlag.NoOptDefVal = defaultReplicaDBPath()
	}
}

func resolveBackendOptions(dbPath string, replicaPath string) (backendOptions, error) {
	trimmedDBPath := strings.TrimSpace(dbPath)
	trimmedReplicaPath := strings.TrimSpace(replicaPath)

	if trimmedDBPath != "" && trimmedReplicaPath != "" {
		return backendOptions{}, fmt.Errorf("--db and --replica are mutually exclusive")
	}

	if trimmedReplicaPath != "" {
		return backendOptions{
			kind: backendReplica,
			path: expandPath(trimmedReplicaPath),
		}, nil
	}

	if trimmedDBPath == "" {
		trimmedDBPath = defaultChatDBPath
	}

	return backendOptions{
		kind: backendSource,
		path: expandPath(trimmedDBPath),
	}, nil
}

func defaultReplicaDBPath() string {
	homeDirectory, err := os.UserHomeDir()
	if err != nil || homeDirectory == "" {
		return "./replica.db"
	}

	if runtime.GOOS == "darwin" {
		return filepath.Join(homeDirectory, "Library", "Application Support", "imsgkit", "replica.db")
	}

	return filepath.Join(homeDirectory, ".local", "share", "imsgkit", "replica.db")
}

func expandPath(path string) string {
	if path == "" {
		return ""
	}
	if path == "~" {
		if homeDirectory, err := os.UserHomeDir(); err == nil {
			return homeDirectory
		}
	}
	if strings.HasPrefix(path, "~/") {
		if homeDirectory, err := os.UserHomeDir(); err == nil {
			return filepath.Join(homeDirectory, path[2:])
		}
	}

	return path
}
