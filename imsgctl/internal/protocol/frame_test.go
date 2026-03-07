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
