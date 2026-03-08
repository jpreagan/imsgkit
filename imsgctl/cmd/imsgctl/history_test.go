package main

import (
	"testing"

	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
)

func TestFormatSenderLabelUsesSelfLabelForOutboundMessages(t *testing.T) {
	label := "Local User (+12125559999)"
	message := protocol.ChatMessage{
		Sender:      "+12125550100",
		SenderLabel: &label,
		FromMe:      true,
	}

	if got := formatSenderLabel(message); got != label {
		t.Fatalf("formatSenderLabel() = %q, want %q", got, label)
	}
}

func TestFormatSenderLabelFallsBackToMeForOutboundMessages(t *testing.T) {
	message := protocol.ChatMessage{
		Sender: "+12125550100",
		FromMe: true,
	}

	if got := formatSenderLabel(message); got != "Me" {
		t.Fatalf("formatSenderLabel() = %q, want %q", got, "Me")
	}
}

func TestFormatSenderLabelUsesSenderLabelForInboundMessages(t *testing.T) {
	label := "Jane Doe (+12125550100)"
	message := protocol.ChatMessage{
		Sender:      "+12125550100",
		SenderLabel: &label,
	}

	if got := formatSenderLabel(message); got != label {
		t.Fatalf("formatSenderLabel() = %q, want %q", got, label)
	}
}
