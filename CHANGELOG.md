# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Public installer script (`install.sh`) for user-level installation (no sudo), with configurable repo/ref/install path and optional SHA256 verification.
- Integration test suite naming cleanup (`tests/integration.test.sh`).
- Operational trace mode via `--debug` (non-sensitive).
- Explicit sensitive output flag: `--dangerously-print-env`.
- Quiet-by-default successful runs.

### Security
- Hardened output-file handling and Bitwarden session exposure boundaries.
- Added regression coverage for sensitive-path behaviors.
