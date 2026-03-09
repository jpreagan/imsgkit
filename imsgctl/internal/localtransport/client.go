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
	DBPath string
}

type Client struct {
	mu     sync.Mutex
	nextID int

	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
}

func Start(ctx context.Context, options Options) (*Client, error) {
	cmd := exec.CommandContext(ctx, "imsgd", "--db", options.DBPath)
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

func (c *Client) Health(ctx context.Context) (protocol.HealthResponse, error) {
	return call[protocol.HealthResponse](ctx, c, protocol.MethodHealth, nil)
}

func (c *Client) ListChats(ctx context.Context, limit int) ([]protocol.ChatSummary, error) {
	return call[[]protocol.ChatSummary](ctx, c, protocol.MethodListChats, protocol.ListChatsParams{
		Limit: limit,
	})
}

func (c *Client) GetHistory(
	ctx context.Context,
	chatID int64,
	limit int,
	start *string,
	end *string,
) ([]protocol.ChatMessage, error) {
	return call[[]protocol.ChatMessage](ctx, c, protocol.MethodGetHistory, protocol.GetHistoryParams{
		ChatID: chatID,
		Limit:  limit,
		Start:  start,
		End:    end,
	})
}

func (c *Client) Watch(
	ctx context.Context,
	params protocol.WatchParams,
	handle func(protocol.WatchEvent) error,
) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return err
	}

	requestID, err := c.sendRequest(protocol.MethodWatch, params)
	if err != nil {
		return err
	}

	if _, err := readResponse[struct{}](ctx, c, requestID); err != nil {
		return err
	}

	for {
		envelope, err := c.readEnvelope(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}

		if envelope.Kind != protocol.KindEvent || envelope.Event == nil {
			return fmt.Errorf("unexpected stream envelope")
		}
		if envelope.Event.RequestID != requestID {
			return fmt.Errorf("event request id mismatch: want %s got %s", requestID, envelope.Event.RequestID)
		}

		event, err := protocol.Decode[protocol.WatchEvent](envelope.Event.Payload)
		if err != nil {
			return fmt.Errorf("decode event: %w", err)
		}

		if err := handle(event); err != nil {
			return err
		}
	}
}

func call[T any](ctx context.Context, c *Client, method string, params any) (T, error) {
	var zero T

	c.mu.Lock()
	defer c.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return zero, err
	}

	requestID, err := c.sendRequest(method, params)
	if err != nil {
		return zero, err
	}

	return readResponse[T](ctx, c, requestID)
}

func (c *Client) sendRequest(method string, params any) (string, error) {
	c.nextID++
	requestID := fmt.Sprintf("%d", c.nextID)

	rawParams, err := protocol.Encode(params)
	if err != nil {
		return "", fmt.Errorf("encode params: %w", err)
	}

	if err := protocol.WriteEnvelope(c.stdin, protocol.Envelope{
		Kind: protocol.KindRequest,
		Request: &protocol.Request{
			ID:     requestID,
			Method: method,
			Params: rawParams,
		},
	}); err != nil {
		return "", fmt.Errorf("write request: %w", err)
	}

	return requestID, nil
}

func readResponse[T any](ctx context.Context, c *Client, requestID string) (T, error) {
	var zero T

	envelope, err := c.readEnvelope(ctx)
	if err != nil {
		return zero, err
	}

	if envelope.Kind != protocol.KindResponse || envelope.Response == nil {
		return zero, fmt.Errorf("unexpected response envelope")
	}

	response := envelope.Response
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

func (c *Client) readEnvelope(ctx context.Context) (protocol.Envelope, error) {
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
		var zero protocol.Envelope
		return zero, ctx.Err()
	case outcome := <-readDone:
		if outcome.err != nil {
			return protocol.Envelope{}, fmt.Errorf("read response: %w", outcome.err)
		}
		return outcome.envelope, nil
	}
}
