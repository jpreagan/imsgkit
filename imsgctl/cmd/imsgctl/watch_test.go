package main

import (
	"testing"

	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
)

func TestFormatReactionSenderLabelUsesSelfLabelForOutboundReactions(t *testing.T) {
	label := "Local User (+12125559999)"
	reaction := protocol.ReactionEvent{
		Sender:      "+12125550100",
		SenderLabel: &label,
		FromMe:      true,
	}

	if got := formatReactionSenderLabel(reaction); got != label {
		t.Fatalf("formatReactionSenderLabel() = %q, want %q", got, label)
	}
}

func TestFormatReactionSenderLabelFallsBackToSenderForInboundReactions(t *testing.T) {
	reaction := protocol.ReactionEvent{
		Sender: "+12125550100",
	}

	if got := formatReactionSenderLabel(reaction); got != "+12125550100" {
		t.Fatalf("formatReactionSenderLabel() = %q, want %q", got, "+12125550100")
	}
}

func TestFormatReactionTargetFallsBackToDash(t *testing.T) {
	reaction := protocol.ReactionEvent{}

	if got := formatReactionTarget(reaction); got != "-" {
		t.Fatalf("formatReactionTarget() = %q, want %q", got, "-")
	}
}
