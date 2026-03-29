# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

## [0.3.0]

### Added

- Replica sync now mirrors referenced attachments alongside `replica.db` in a sibling `attachments/` directory. [#26](https://github.com/jpreagan/imsgkit/pull/26)

### Changed

- Replica attachment output now shows only the local attachment `path` for the machine reading the replica. [#26](https://github.com/jpreagan/imsgkit/pull/26)
- Replica attachment `missing` is now determined on the machine reading the replica. [#26](https://github.com/jpreagan/imsgkit/pull/26)

## [0.2.0]

### Added

- Portable `replica.db` generation and replica-backed reads in `imsgctl`. [#18](https://github.com/jpreagan/imsgkit/pull/18)
- `imsgd sync` for long-running replica maintenance and remote replica publishing with `sqlite3_rsync`. [#19](https://github.com/jpreagan/imsgkit/pull/19) [#20](https://github.com/jpreagan/imsgkit/pull/20)
- Homebrew service support for running `imsgd sync`. [#20](https://github.com/jpreagan/imsgkit/pull/20)

### Changed

- `imsgctl` now prefers the standard local replica path by default when a valid replica is present, and on macOS falls back to the live Messages database when no replica is available. [#20](https://github.com/jpreagan/imsgkit/pull/20)

## [0.1.0]

### Added

- Initial public release of `imsgkit`.
- `imsgd`, a read-only macOS helper for exposing Messages data locally.
- `imsgctl health` to verify local Messages database access and helper health.
- `imsgctl chats` to list recent chats with contact-enriched labels where available.
- `imsgctl history` to query chat history, including start and end filtering plus attachment metadata.
- `imsgctl watch` to stream new local message activity, including reactions and optional attachment details.
- Homebrew install support for `imsgd` and `imsgctl`.
