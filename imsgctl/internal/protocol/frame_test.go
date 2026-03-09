package protocol

import (
	"bytes"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	t.Parallel()

	var buffer bytes.Buffer
	envelope := Envelope{
		Kind: KindRequest,
		Request: &Request{
			ID:     "1",
			Method: MethodHandshake,
		},
	}

	if err := WriteEnvelope(&buffer, envelope); err != nil {
		t.Fatalf("write envelope: %v", err)
	}

	decoded, err := ReadEnvelope(&buffer)
	if err != nil {
		t.Fatalf("read envelope: %v", err)
	}

	if decoded.Kind != KindRequest {
		t.Fatalf("kind mismatch: got %q", decoded.Kind)
	}

	if decoded.Request == nil || decoded.Request.Method != MethodHandshake {
		t.Fatalf("request mismatch: %#v", decoded.Request)
	}
}

func TestEventEnvelopeRoundTrip(t *testing.T) {
	t.Parallel()

	var buffer bytes.Buffer
	payload, err := Encode(WatchEvent{
		Event: "reaction",
		Reaction: &ReactionEvent{
			ID:         42,
			TargetGUID: "message-101",
			Type:       "love",
			Emoji:      "❤️",
			Action:     "added",
		},
	})
	if err != nil {
		t.Fatalf("encode payload: %v", err)
	}

	envelope := Envelope{
		Kind: KindEvent,
		Event: &Event{
			RequestID: "7",
			Payload:   payload,
		},
	}

	if err := WriteEnvelope(&buffer, envelope); err != nil {
		t.Fatalf("write envelope: %v", err)
	}

	decoded, err := ReadEnvelope(&buffer)
	if err != nil {
		t.Fatalf("read envelope: %v", err)
	}

	if decoded.Kind != KindEvent {
		t.Fatalf("kind mismatch: got %q", decoded.Kind)
	}
	if decoded.Event == nil || decoded.Event.RequestID != "7" {
		t.Fatalf("event mismatch: %#v", decoded.Event)
	}

	event, err := Decode[WatchEvent](decoded.Event.Payload)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}

	if event.Reaction == nil || event.Reaction.TargetGUID != "message-101" {
		t.Fatalf("watch event mismatch: %#v", event)
	}
}
