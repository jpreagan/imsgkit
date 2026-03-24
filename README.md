# imsgkit

`imsgkit` is a CLI for reading your Messages data.

On a source Mac, `imsgd` reads Apple Messages data and can keep a portable `replica.db` in sync. On another macOS or Linux machine, `imsgctl` reads that replica locally. The remote machine does not need to sign in to a personal Apple ID.

## What It Can Do

- List recent chats.
- Read message history for a chat.
- Filter history by start and end time.
- Include attachment metadata.
- Watch new message activity, including reactions.
- Emit JSON output for scripts and other tools.

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

By default:

- On macOS, `imsgctl` prefers `~/Library/Application Support/imsgkit/replica.db` when a valid replica is present. Otherwise it falls back to `~/Library/Messages/chat.db`.
- On Linux, `imsgctl` reads `~/.local/share/imsgkit/replica.db`, or `$XDG_DATA_HOME/imsgkit/replica.db` when `XDG_DATA_HOME` is set to an absolute path.

You can always choose a specific database explicitly:

```bash
imsgctl chats --db ~/Library/Application\ Support/imsgkit/replica.db
imsgctl history --db ~/.local/share/imsgkit/replica.db --chat-id 42
```

## Remote Replica Sync

Most users will run `imsgd sync` on a signed-in Mac and `imsgctl` on a different machine.

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

2. Prepare the remote path and make sure `sqlite3_rsync` is installed on the remote machine.

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
