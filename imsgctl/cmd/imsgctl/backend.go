package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/spf13/pflag"
	_ "modernc.org/sqlite"
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

func addBackendFlags(flags *pflag.FlagSet, dbPath *string) {
	flags.StringVar(dbPath, "db", "", "path to Messages database")
}

func replicaDBExamplePath() string {
	homeDirectory, _ := os.UserHomeDir()
	return replicaDBExamplePathFor(runtime.GOOS, homeDirectory, os.Getenv("XDG_DATA_HOME"))
}

func replicaDBExamplePathFor(goos string, homeDirectory string, xdgDataHome string) string {
	return shellEscapePath(
		abbreviateHomePath(defaultReplicaDBPathFor(goos, homeDirectory, xdgDataHome), homeDirectory),
	)
}

func resolveBackendOptions(dbPath string) (backendOptions, error) {
	trimmedDBPath := strings.TrimSpace(dbPath)
	if trimmedDBPath == "" {
		homeDirectory, _ := os.UserHomeDir()
		return resolveDefaultBackendOptionsFor(runtime.GOOS, homeDirectory, os.Getenv("XDG_DATA_HOME"))
	}

	resolvedPath := expandPath(trimmedDBPath)
	kind, err := detectBackendKind(resolvedPath)
	if err != nil {
		return backendOptions{}, err
	}

	return backendOptions{
		kind: kind,
		path: resolvedPath,
	}, nil
}

func resolveDefaultBackendOptionsFor(goos string, homeDirectory string, xdgDataHome string) (backendOptions, error) {
	replicaPath := defaultReplicaDBPathFor(goos, homeDirectory, xdgDataHome)

	info, err := os.Stat(replicaPath)
	if err == nil {
		if info.IsDir() {
			return backendOptions{}, fmt.Errorf("default replica db path is a directory: %s", replicaPath)
		}

		kind, err := detectBackendKind(replicaPath)
		if err != nil {
			return backendOptions{}, err
		}
		if kind != backendReplica {
			return backendOptions{}, fmt.Errorf("default replica db path is not a replica database: %s", replicaPath)
		}

		return backendOptions{
			kind: backendReplica,
			path: replicaPath,
		}, nil
	}
	if err != nil && !os.IsNotExist(err) {
		return backendOptions{}, fmt.Errorf("stat db path: %w", err)
	}

	if goos == "darwin" {
		return backendOptions{
			kind: backendSource,
			path: expandPath(defaultChatDBPath),
		}, nil
	}

	return backendOptions{
		kind: backendReplica,
		path: replicaPath,
	}, nil
}

func detectBackendKind(path string) (backendKind, error) {
	trimmedPath := strings.TrimSpace(path)
	if trimmedPath == "" {
		return "", fmt.Errorf("db path is required")
	}

	info, err := os.Stat(trimmedPath)
	if err != nil {
		if os.IsNotExist(err) {
			return backendSource, nil
		}
		return "", fmt.Errorf("stat db path: %w", err)
	}
	if info.IsDir() {
		return backendSource, nil
	}

	replica, err := isReplicaDatabase(trimmedPath)
	if err != nil {
		return "", err
	}
	if replica {
		return backendReplica, nil
	}

	return backendSource, nil
}

func isReplicaDatabase(path string) (bool, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return false, fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	var metadataTable int
	err = db.QueryRow(
		`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata'`,
	).Scan(&metadataTable)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, nil
	}

	var schemaVersion string
	err = db.QueryRow(
		`SELECT value FROM metadata WHERE key = 'schema_version'`,
	).Scan(&schemaVersion)
	if err == nil {
		return schemaVersion == "1", nil
	}
	if err == sql.ErrNoRows {
		return false, nil
	}
	if strings.Contains(err.Error(), "unable to open database file") {
		return false, fmt.Errorf("open db: %w", err)
	}

	return false, nil
}

func defaultReplicaDBPathFor(goos string, homeDirectory string, xdgDataHome string) string {
	if goos == "darwin" {
		if homeDirectory == "" {
			return "./replica.db"
		}
		return filepath.Join(homeDirectory, "Library", "Application Support", "imsgkit", "replica.db")
	}

	if filepath.IsAbs(xdgDataHome) {
		return filepath.Join(xdgDataHome, "imsgkit", "replica.db")
	}

	if homeDirectory == "" {
		return "./replica.db"
	}

	return filepath.Join(homeDirectory, ".local", "share", "imsgkit", "replica.db")
}

func abbreviateHomePath(path string, homeDirectory string) string {
	if path == "" || homeDirectory == "" {
		return path
	}

	cleanPath := filepath.Clean(path)
	cleanHome := filepath.Clean(homeDirectory)
	if cleanPath == cleanHome {
		return "~"
	}

	homePrefix := cleanHome + string(os.PathSeparator)
	if strings.HasPrefix(cleanPath, homePrefix) {
		return filepath.Join("~", strings.TrimPrefix(cleanPath, homePrefix))
	}

	return cleanPath
}

func shellEscapePath(path string) string {
	return strings.ReplaceAll(path, " ", "\\ ")
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
