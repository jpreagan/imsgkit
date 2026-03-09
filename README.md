# imsgkit

`imsgkit` is a read-only CLI for exploring Messages data on your Mac.

It gives you a CLI for inspecting chats, reading message history, and watching new message activity. When Contacts data is available, it shows real names and labels instead of only raw phone numbers and handles.

## Why This Exists

`imsgkit` exists for people who want the useful parts of a Messages CLI without write access.

- Read-only by design.
- Contact-enriched output when Contacts permission is available.
- Structured output for shell use, scripts, and other local tools.

## What It Can Do

- List recent chats.
- Read message history for a chat.
- Filter history by start and end time.
- Include attachment metadata.
- Watch new local message activity as it happens.
- Include reaction events in the watch stream.
- Emit structured JSON output from the CLI.

Replica support is planned, so you can keep your Apple ID on your Mac while giving an agent or another machine read-only access to your Messages data.

## Install

```bash
brew install jpreagan/tap/imsgd
brew install jpreagan/tap/imsgctl
```

## Commands

`imsgctl` starts `imsgd` locally as needed and talks to it over a framed local transport.

Core commands:

- `imsgctl health`
- `imsgctl chats`
- `imsgctl history --chat-id <id>`
- `imsgctl watch`

Useful flags:

- `--json` for machine-readable output
- `--attachments` for attachment details in text output
- `--start` and `--end` for ISO8601 time filtering
- `--reactions` for reaction events in `watch`

## Quick Start

Check local access:

```bash
imsgctl health
```

List recent chats:

```bash
imsgctl chats
imsgctl chats --json
```

Read recent history from a chat:

```bash
imsgctl history --chat-id 42 --limit 20
imsgctl history --chat-id 42 --start 2026-03-01T00:00:00Z --attachments
```

Watch new activity:

```bash
imsgctl watch --chat-id 42 --reactions
imsgctl watch --chat-id 42 --json
```

## Permissions

`imsgkit` reads:

- `~/Library/Messages/chat.db`
- Apple Contacts data through `Contacts.framework`

If Contacts permission is unavailable, `imsgkit` still works, but it falls back to raw identifiers where necessary.

## Development

```bash
swift build
swift test

cd imsgctl
go build ./...
go test ./...
```

## License

[MIT License](LICENSE)
