package protocol

import "encoding/json"

const (
	ProtocolVersion = "0.1.0"
	ServerName      = "imsgd"

	KindRequest  = "request"
	KindResponse = "response"

	MethodHandshake = "Handshake"
	MethodHealth    = "Health"
)

type Envelope struct {
	Kind     string    `json:"kind"`
	Request  *Request  `json:"request,omitempty"`
	Response *Response `json:"response,omitempty"`
}

type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *RPCError       `json:"error,omitempty"`
}

type RPCError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type HandshakeResponse struct {
	ProtocolVersion string   `json:"protocol_version"`
	ServerName      string   `json:"server_name"`
	ServerVersion   string   `json:"server_version"`
	ReadOnly        bool     `json:"read_only"`
	Capabilities    []string `json:"capabilities"`
}

type HealthResponse struct {
	OK              bool   `json:"ok"`
	ReadOnly        bool   `json:"read_only"`
	DBPath          string `json:"db_path"`
	DBExists        bool   `json:"db_exists"`
	CanReadDB       bool   `json:"can_read_db"`
	SQLiteOpenOK    bool   `json:"sqlite_open_ok"`
	ProtocolVersion string `json:"protocol_version"`
	ServerVersion   string `json:"server_version"`
}

func Encode(value any) (json.RawMessage, error) {
	if value == nil {
		return nil, nil
	}

	payload, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}

	return json.RawMessage(payload), nil
}

func Decode[T any](raw json.RawMessage) (T, error) {
	var value T
	if len(raw) == 0 || string(raw) == "null" {
		return value, nil
	}

	err := json.Unmarshal(raw, &value)
	return value, err
}
