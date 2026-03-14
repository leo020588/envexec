# envexec

Securely load environment variables from Bitwarden/Vaultwarden item notes or local files, then execute a command with that environment.

`envexec` helps you run commands with secrets **without persisting `.env.*` files on disk**.

> **Scope:** `envexec` is primarily for local development on a personal machine. CI/CD use is possible, but not the primary target.

## Quick start

Install (no `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/leo020588/envexec/main/install.sh | bash
```

Load from file and run a command:

```bash
envexec --from-file .env.local -- your-command
```

Load from Bitwarden/Vaultwarden and run a command:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
envexec --from-bw ".env.production" --bw-folder "deploy" -- your-command
```

Prefer this Bitwarden/Vaultwarden flow when you want secrets injected at runtime without creating `.env.*` files on disk.

## Why envexec

- Diskless secret injection for everyday commands
- Quiet by default on successful runs
- Strict env parsing and validation
- Explicit dangerous output mode for env-value printing
- Secure output file write behavior

## Use cases

```bash
# Local app startup from `.env`
envexec --from-file .env.local -- docker compose up -d

# Cloud container deployment with Bitwarden/Vaultwarden secrets
envexec --from-bw ".env.production" --bw-folder "deploy" -- ./scripts/deploy.sh

# One-off admin tasks with temporary credentials
envexec --from-bw ".env.production" --bw-folder "ops" -- ./bin/run-migrations.sh

# Generate parsed env file for file-only tools
envexec --from-bw ".env.staging" --bw-folder "deploy" --write-env /tmp/staging.env

# Troubleshoot loading flow without exposing values
envexec --from-file .env.local --debug -- true
```

## Install options

Pinned ref example:

```bash
curl -fsSL https://raw.githubusercontent.com/leo020588/envexec/main/install.sh | bash -s -- --ref v1.0.0
```

Custom install directory example:

```bash
ENVEXEC_INSTALL_DIR="$HOME/bin" curl -fsSL https://raw.githubusercontent.com/leo020588/envexec/main/install.sh | bash
```

## Command reference

```text
Usage:
  envexec <source> [options] -- <command> [args...]
  envexec <source> [options]

Sources (choose exactly one):
  --from-file <path>
  --from-bw <item-name> [--bw-folder <folder-name>]

Loads environment variables from selected Bitwarden item notes or from file content,
then execs the command so the variables only exist in this process tree.

Requirements:
  BW_SESSION          Must already be set to a valid Bitwarden session key in item mode

Options:
  -h, --help          Show this help text
  --debug             Print operational trace information to stderr (no env values)
  --dangerously-print-env
                      Print each loaded KEY=value pair (sensitive); only allowed when no command is provided
  --from-bw <item>    Read raw env input content from Bitwarden item notes
  --bw-folder <name>  Exact Bitwarden folder name for --from-bw; if omitted, only unfiled items are searched
  --from-file <path>  Read raw env input content from a file instead of Bitwarden item notes
  --write-env <file>  Write the loaded KEY=value pairs to a file
  --write-raw <file>  Write raw input content to a file
```

## Parsing rules

Supported:

- `FOO=bar`
- `FOO='bar'`
- `FOO="bar"`

Rejected:

- `FOO='bar`
- `FOO=bar'`

Behavior:

- trims outer whitespace for unquoted values
- preserves edge whitespace only when inside quotes
- no variable substitution
- no escape-sequence decoding

## Security model

- Successful runs are quiet by default.
- Errors go to `stderr` with non-zero exit.
- `BW_SESSION` is consumed internally in Bitwarden/Vaultwarden mode and not propagated to child commands.
- Sensitive env dumping is explicit (`--dangerously-print-env`) and blocked with command execution.
- Output writes are hardened (symlink rejection, strict permissions).

See [`SECURITY.md`](./SECURITY.md) for reporting and policy details.

## Development

Run the integration suite:

```bash
./tests/integration.test.sh
```

`dev/` contains local-only Vaultwarden/Nginx assets for reproducible testing and is not for production use.

## Project docs

- Contributing: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- Changelog: [`CHANGELOG.md`](./CHANGELOG.md)
- License: [`LICENSE`](./LICENSE)
