package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const MaxFrameSize = 16 << 20

func WriteEnvelope(w io.Writer, envelope Envelope) error {
	payload, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("marshal envelope: %w", err)
	}

	if len(payload) > MaxFrameSize {
		return fmt.Errorf("frame too large: %d", len(payload))
	}

	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))

	if _, err := w.Write(header[:]); err != nil {
		return fmt.Errorf("write frame header: %w", err)
	}

	if _, err := w.Write(payload); err != nil {
		return fmt.Errorf("write frame payload: %w", err)
	}

	return nil
}

func ReadEnvelope(r io.Reader) (Envelope, error) {
	var envelope Envelope
	var header [4]byte

	if _, err := io.ReadFull(r, header[:]); err != nil {
		return envelope, err
	}

	size := binary.BigEndian.Uint32(header[:])
	if size == 0 {
		return envelope, errors.New("invalid empty frame")
	}

	if size > MaxFrameSize {
		return envelope, fmt.Errorf("frame too large: %d", size)
	}

	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return envelope, err
	}

	if err := json.Unmarshal(payload, &envelope); err != nil {
		return envelope, fmt.Errorf("decode envelope: %w", err)
	}

	return envelope, nil
}
