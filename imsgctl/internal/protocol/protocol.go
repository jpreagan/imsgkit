package protocol

import "encoding/json"

const (
	ProtocolVersion = "0.1.0"
	ServerName      = "imsgd"

	KindRequest  = "request"
	KindResponse = "response"
	KindEvent    = "event"

	MethodHandshake  = "Handshake"
	MethodHealth     = "Health"
	MethodListChats  = "ListChats"
	MethodGetHistory = "GetHistory"
	MethodWatch      = "Watch"
)

type Envelope struct {
	Kind     string    `json:"kind"`
	Request  *Request  `json:"request,omitempty"`
	Response *Response `json:"response,omitempty"`
	Event    *Event    `json:"event,omitempty"`
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

type Event struct {
	RequestID string          `json:"request_id"`
	Payload   json.RawMessage `json:"payload"`
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

type ListChatsParams struct {
	Limit int `json:"limit"`
}

type GetHistoryParams struct {
	ChatID int64   `json:"chat_id"`
	Limit  int     `json:"limit"`
	Start  *string `json:"start,omitempty"`
	End    *string `json:"end,omitempty"`
}

type WatchParams struct {
	ChatID               *int64  `json:"chat_id,omitempty"`
	Start                *string `json:"start,omitempty"`
	End                  *string `json:"end,omitempty"`
	DebounceMilliseconds int     `json:"debounce_milliseconds"`
	IncludeReactions     bool    `json:"include_reactions"`
}

type ChatSummary struct {
	ID               int64    `json:"id"`
	Service          string   `json:"service"`
	Identifier       string   `json:"identifier"`
	Label            string   `json:"label"`
	ContactName      *string  `json:"contact_name"`
	ParticipantCount int      `json:"participant_count"`
	Participants     []string `json:"participants"`
	LastMessageAt    *string  `json:"last_message_at"`
	MessageCount     int      `json:"message_count"`
}

type ChatMessage struct {
	ID                   int64            `json:"id"`
	ChatID               int64            `json:"chat_id"`
	GUID                 string           `json:"guid"`
	ReplyToGUID          *string          `json:"reply_to_guid"`
	ThreadOriginatorGUID *string          `json:"thread_originator_guid"`
	Sender               string           `json:"sender"`
	SenderName           *string          `json:"sender_name"`
	SenderLabel          *string          `json:"sender_label"`
	FromMe               bool             `json:"from_me"`
	Text                 string           `json:"text"`
	CreatedAt            *string          `json:"created_at"`
	Service              string           `json:"service"`
	DestinationCallerID  *string          `json:"destination_caller_id"`
	Attachments          []AttachmentMeta `json:"attachments"`
	Reactions            []ReactionMeta   `json:"reactions"`
}

type AttachmentMeta struct {
	Filename     string `json:"filename"`
	TransferName string `json:"transfer_name"`
	UTI          string `json:"uti"`
	MimeType     string `json:"mime_type"`
	TotalBytes   int64  `json:"total_bytes"`
	IsSticker    bool   `json:"is_sticker"`
	OriginalPath string `json:"original_path"`
	Missing      bool   `json:"missing"`
}

type ReactionMeta struct {
	ID        int64   `json:"id"`
	Type      string  `json:"type"`
	Emoji     string  `json:"emoji"`
	Sender    string  `json:"sender"`
	FromMe    bool    `json:"is_from_me"`
	CreatedAt *string `json:"created_at"`
}

type WatchEvent struct {
	Event    string         `json:"event"`
	Message  *ChatMessage   `json:"message,omitempty"`
	Reaction *ReactionEvent `json:"reaction,omitempty"`
}

type ReactionEvent struct {
	ID                  int64   `json:"id"`
	GUID                string  `json:"guid"`
	ChatID              int64   `json:"chat_id"`
	TargetGUID          string  `json:"target_guid"`
	Sender              string  `json:"sender"`
	SenderName          *string `json:"sender_name"`
	SenderLabel         *string `json:"sender_label"`
	FromMe              bool    `json:"from_me"`
	Type                string  `json:"type"`
	Emoji               string  `json:"emoji"`
	Action              string  `json:"action"`
	CreatedAt           *string `json:"created_at"`
	Service             string  `json:"service"`
	DestinationCallerID *string `json:"destination_caller_id"`
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
