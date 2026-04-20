# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `rbw` backend support: `rbw` is now auto-detected and preferred over the official `bw` CLI when both are installed; no session key needed.
- `BW_BACKEND` environment variable to override backend auto-detection (`rbw` or `bw`).
- Public installer script (`install.sh`) for user-level installation (no sudo), with configurable repo/ref/install path and optional SHA256 verification.
- Integration test suite naming cleanup (`tests/integration.test.sh`).
- Operational trace mode via `--debug` (non-sensitive).
- Explicit sensitive output flag: `--dangerously-print-env`.
- Quiet-by-default successful runs.

### Security
- Hardened output-file handling and Bitwarden session exposure boundaries.
- Added regression coverage for sensitive-path behaviors.
- `BW_SESSION` is not propagated to child commands in `bw` mode; `rbw` mode requires no session key at all.
