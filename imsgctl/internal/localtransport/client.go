package localtransport

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"sync"

	"github.com/jpreagan/imsgkit/imsgctl/internal/protocol"
)

type Options struct {
	HelperPath string
}

type Client struct {
	mu     sync.Mutex
	nextID int

	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
}

func Start(ctx context.Context, options Options) (*Client, error) {
	helperPath := options.HelperPath
	if helperPath == "" {
		helperPath = "imsgd"
	}

	cmd := exec.CommandContext(ctx, helperPath)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("open stdin: %w", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("open stdout: %w", err)
	}

	cmd.Stderr = io.Discard

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start helper: %w", err)
	}

	client := &Client{
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
	}

	if _, err := client.Handshake(ctx); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("handshake: %w", err)
	}

	return client, nil
}

func (c *Client) Close() error {
	if c == nil {
		return nil
	}

	if c.stdin != nil {
		_ = c.stdin.Close()
	}

	if c.cmd != nil {
		return c.cmd.Wait()
	}

	return nil
}

func (c *Client) Handshake(ctx context.Context) (protocol.HandshakeResponse, error) {
	return call[protocol.HandshakeResponse](ctx, c, protocol.MethodHandshake, nil)
}

func call[T any](ctx context.Context, c *Client, method string, params any) (T, error) {
	var zero T

	c.mu.Lock()
	defer c.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return zero, err
	}

	c.nextID++
	requestID := fmt.Sprintf("%d", c.nextID)

	rawParams, err := protocol.Encode(params)
	if err != nil {
		return zero, fmt.Errorf("encode params: %w", err)
	}

	if err := protocol.WriteEnvelope(c.stdin, protocol.Envelope{
		Kind: protocol.KindRequest,
		Request: &protocol.Request{
			ID:     requestID,
			Method: method,
			Params: rawParams,
		},
	}); err != nil {
		return zero, fmt.Errorf("write request: %w", err)
	}

	type result struct {
		envelope protocol.Envelope
		err      error
	}

	readDone := make(chan result, 1)
	go func() {
		envelope, err := protocol.ReadEnvelope(c.stdout)
		readDone <- result{envelope: envelope, err: err}
	}()

	select {
	case <-ctx.Done():
		return zero, ctx.Err()
	case outcome := <-readDone:
		if outcome.err != nil {
			return zero, fmt.Errorf("read response: %w", outcome.err)
		}

		if outcome.envelope.Kind != protocol.KindResponse || outcome.envelope.Response == nil {
			return zero, fmt.Errorf("unexpected response envelope")
		}

		response := outcome.envelope.Response
		if response.Error != nil {
			return zero, fmt.Errorf("%s: %s", response.Error.Code, response.Error.Message)
		}

		if response.ID != requestID {
			return zero, fmt.Errorf("response id mismatch: want %s got %s", requestID, response.ID)
		}

		value, err := protocol.Decode[T](response.Result)
		if err != nil {
			return zero, fmt.Errorf("decode response: %w", err)
		}

		return value, nil
	}
}
