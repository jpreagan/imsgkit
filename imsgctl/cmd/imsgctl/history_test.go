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

func TestFormatAttachmentNamePrefersTransferName(t *testing.T) {
	attachment := protocol.AttachmentMeta{
		Filename:     "~/Library/Messages/Attachments/test/photo.heic",
		TransferName: "photo.heic",
		Path:         "/Users/test/Library/Messages/Attachments/test/photo.heic",
	}

	if got := formatAttachmentName(attachment); got != "photo.heic" {
		t.Fatalf("formatAttachmentName() = %q, want %q", got, "photo.heic")
	}
}

func TestFormatAttachmentNameFallsBackToFilenameBase(t *testing.T) {
	attachment := protocol.AttachmentMeta{
		Filename: "~/Library/Messages/Attachments/test/photo.heic",
	}

	if got := formatAttachmentName(attachment); got != "photo.heic" {
		t.Fatalf("formatAttachmentName() = %q, want %q", got, "photo.heic")
	}
}

func TestFormatAttachmentPathPrefersResolvedPath(t *testing.T) {
	attachment := protocol.AttachmentMeta{
		Path: "/tmp/attachments/test/photo.heic",
	}

	if got := formatAttachmentPath(attachment); got != "/tmp/attachments/test/photo.heic" {
		t.Fatalf("formatAttachmentPath() = %q, want %q", got, "/tmp/attachments/test/photo.heic")
	}
}
