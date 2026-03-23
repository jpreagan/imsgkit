# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

- `imsgd sync` can publish a portable, contact-enriched `replica.db` to a remote machine with `sqlite3_rsync`.
- Homebrew service support for running `imsgd sync`.

### Changed

- `imsgctl` now prefers a local `replica.db` by default when one is present, and falls back to the live Messages database on macOS.

## [0.1.0]

### Added

- Initial public release of `imsgkit`.
- `imsgd`, a read-only macOS helper for exposing Messages data locally.
- `imsgctl health` to verify local Messages database access and helper health.
- `imsgctl chats` to list recent chats with contact-enriched labels where available.
- `imsgctl history` to query chat history, including start and end filtering plus attachment metadata.
- `imsgctl watch` to stream new local message activity, including reactions and optional attachment details.
- Homebrew install support for `imsgd` and `imsgctl`.
