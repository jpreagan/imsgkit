package main

import (
	"reflect"
	"testing"
)

func TestNormalizeReplicaFlagArgsPreservesBareReplicaFlag(t *testing.T) {
	args := []string{"history", "--replica", "--chat-id", "6"}
	got := normalizeReplicaFlagArgs(args)

	if !reflect.DeepEqual(got, args) {
		t.Fatalf("normalizeReplicaFlagArgs() = %#v, want %#v", got, args)
	}
}

func TestNormalizeReplicaFlagArgsRewritesSpaceSeparatedReplicaPath(t *testing.T) {
	args := []string{"history", "--replica", "/tmp/replica.db", "--chat-id", "6"}
	want := []string{"history", "--replica=/tmp/replica.db", "--chat-id", "6"}

	got := normalizeReplicaFlagArgs(args)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalizeReplicaFlagArgs() = %#v, want %#v", got, want)
	}
}
