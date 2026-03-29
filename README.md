<div align="center"><img src="assets/logo.png" alt="imsgkit" width="200" /></div>

# imsgkit

Read your Apple Messages from any machine.

`imsgd` runs on your signed-in Mac and keeps a portable `replica.db` in sync. `imsgctl` reads that replica on any other macOS or Linux machine — no Apple ID required on the reading end. Works locally too.

## What It Can Do

- List recent chats.
- Read message history for a chat.
- Filter history by start and end time.
- Include attachment metadata.
- Watch new message activity, including reactions.
- Emit JSON output for scripts and agents.

## Install

Source Mac:

```bash
brew install jpreagan/tap/imsgd
brew install jpreagan/tap/imsgctl
```

Remote machine:

- Install `imsgctl`.
- Install `sqlite3_rsync` if the source Mac will publish a replica here.

## Agent Skill

This repo includes an agent skill for `imsgctl` at `skills/imsgctl`.

Install it from this public repo with:

```bash
npx skills add jpreagan/imsgkit
```

The installed skill helps an agent use `imsgctl` to check access, list chats, inspect message history, include attachment metadata, and watch new activity.

Some agents load new skills only when a session starts. If the skill does not appear immediately, start a new session or refresh skills in the agent runtime.

## Local Use on a Mac

`imsgctl` starts `imsgd` locally as needed for live reads.

```bash
imsgctl health
imsgctl chats
imsgctl history --chat-id 42 --limit 20
imsgctl watch --chat-id 42 --reactions
```

By default, `imsgctl` prefers `~/Library/Application Support/imsgkit/replica.db` when a valid replica is present, otherwise falls back to `~/Library/Messages/chat.db`.

You can always point to a specific database explicitly:

```bash
imsgctl chats --db ~/Library/Messages/chat.db
imsgctl history --db ~/Library/Application\ Support/imsgkit/replica.db --chat-id 42
```

## Remote Replica Sync

Many users will run `imsgd sync` on a signed-in Mac and `imsgctl` on a different machine.

1. Create source-side sync config at `~/Library/Application Support/imsgkit/config.toml`:

```toml
[replica]
publish = "user@remote:~/Library/Application Support/imsgkit/replica.db"
publish_interval_seconds = 5
remote_executable = "/opt/homebrew/bin/sqlite3_rsync"
```

Use an explicit remote path in `publish`.

- macOS remote: `user@remote:~/Library/Application Support/imsgkit/replica.db`
- Linux remote: `user@remote:~/.local/share/imsgkit/replica.db`

2. Prepare the remote path, ensure `sqlite3_rsync` is installed on the remote machine, and confirm the source Mac has SSH access to it.

3. Start sync on the source Mac:

```bash
brew services start imsgd
```

Or run it in the foreground:

```bash
imsgd sync
```

4. Read from the replica on the remote machine:

```bash
imsgctl chats
imsgctl history --chat-id 42 --limit 20
imsgctl watch --chat-id 42 --reactions
```

On Linux, `imsgctl` reads `~/.local/share/imsgkit/replica.db` by default, or `$XDG_DATA_HOME/imsgkit/replica.db` when `XDG_DATA_HOME` is set to an absolute path.

`imsgd sync` also maintains a sibling `attachments/` directory next to `replica.db`, so replica-backed attachment paths reported by `imsgctl` point to files on the consuming machine rather than paths on the source Mac.

## Permissions

On the source Mac, `imsgkit` reads:

- `~/Library/Messages/chat.db`
- Apple Contacts data through `Contacts.framework`

For Messages access on macOS, grant Full Disk Access to whatever is doing the reading:

- If you run `imsgctl` or `imsgd` manually in Terminal, Terminal needs Full Disk Access.
- If you run `imsgd` with `brew services`, the Homebrew-installed `imsgd` binary also needs Full Disk Access, for example `/opt/homebrew/bin/imsgd` on Apple Silicon.
- In System Settings > Privacy & Security > Full Disk Access, add the Homebrew `imsgd` binary. If `/opt` is hard to browse in the file picker, press `Shift+Command+G` and enter the path directly.

If Contacts permission is unavailable, `imsgkit` still works, but falls back to raw identifiers where necessary.

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
