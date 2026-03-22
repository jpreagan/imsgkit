# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

- `imsgd sync` to create and maintain a portable, contact-enriched `replica.db` from a source Messages database.
- `imsgctl --db` support for reading either a live Messages `chat.db` or a `replica.db`.

## [0.1.0]

### Added

- Initial public release of `imsgkit`.
- `imsgd`, a read-only macOS helper for exposing Messages data locally.
- `imsgctl health` to verify local Messages database access and helper health.
- `imsgctl chats` to list recent chats with contact-enriched labels where available.
- `imsgctl history` to query chat history, including start and end filtering plus attachment metadata.
- `imsgctl watch` to stream new local message activity, including reactions and optional attachment details.
- Homebrew install support for `imsgd` and `imsgctl`.
