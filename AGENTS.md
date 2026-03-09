# AGENTS.md

`imsgkit` is a read-only iMessage bridge: `imsgd` reads and enriches Messages data on macOS, and `imsgctl` exposes it through a portable CLI.

## Principles

- Favor simplicity over cleverness.
- Prefer small, composable tools and clear boundaries.
- Follow the UNIX philosophy: do one thing well, keep interfaces explicit, make output easy to pipe and inspect.

## Architecture

- `imsgd` is the macOS-native, source-side helper.
- `imsgctl` is the user-facing CLI and stable consumption surface.

## Swift

- Write idiomatic Swift, not C/Go written in Swift syntax.
- Prefer small types, focused functions, and straightforward control flow.
- Use Apple frameworks where they are the right boundary; do not reimplement platform behavior unnecessarily.
- Keep SQLite access conservative and read-only where intended.

## Go

- Write idiomatic Go, not Java/TypeScript written in Go syntax.
- Prefer simple structs, explicit errors, and flat control flow.
- Avoid unnecessary abstractions, indirection, and configuration surfaces.
- Keep CLI behavior stable and predictable.

## Testing

- Test behavior, not implementation details.
- Prefer end-to-end or boundary-level tests over mocking internals.
- Add regression tests for real bugs.
- Keep test fixtures small and readable.
- When output is user-facing, test the observable output shape.

## Manual Testing

- Before handoff, manually test against the real `~/Library/Messages/chat.db`.
- Use read-only/manual-observation flows whenever possible.
- For watch work, prefer having the operator generate real events while you observe.
- If sandbox behavior appears to differ from the operator's terminal, treat the operator's terminal as the source of truth for real-world behavior.

## Verification

- Before opening a PR, run the full required quality checks locally.
- Swift: `swift format lint --strict --recursive Sources`, `swift format lint --strict Package.swift`, `swift test`, `swift build -c release`, and `./.build/release/imsgd version`.
- Go: `gofmt -l .` must be empty, then run `go vet ./...`, `go test ./...`, and `go build ./...` from `imsgctl/`.
- Run targeted checks while iterating, but finish with the full suite.
- Verify the actual CLI behavior affected by the change, not just the automated checks.

## Git

- PR titles: Conventional Commits `type(scope): description` (lowercase).
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`
- Commits: plain lowercase; no conventional format requirement.
- Do not push or open PRs until approved by the user.

## Versioning

- `imsgd` and `imsgctl` have separate semver tracks.
- The framed protocol version is separate from binary versions.
- Bump the protocol version whenever the protocol surface or wire behavior changes.

## Release

- Release `imsgctl` with tags like `imsgctl/vX.Y.Z`.
- Release `imsgd` with tags like `imsgd/vX.Y.Z`.
- Do not use plain `vX.Y.Z` tags for repo releases.
- `imsgctl` releases run through GoReleaser behind a thin wrapper workflow.
- `imsgd` releases run through the dedicated macOS workflow and rendered Homebrew formula.
- Both release tracks publish GitHub assets and update `jpreagan/homebrew-tap`.

## Changelog

- Use Keep a Changelog format. User-facing changes only.
  - Sections: Added, Changed, Deprecated, Removed, Fixed, Security
