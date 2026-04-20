# Security Policy

## Supported scope

This project is a Bash CLI for sensitive environment handling. Security issues are treated as high priority.

## Reporting a vulnerability

Please report vulnerabilities privately to the repository owner.
Do **not** open a public issue with exploit details before a fix is available.

Include:
- affected version/commit
- reproduction steps
- expected vs actual behavior
- impact assessment

## Security design highlights

- Quiet-by-default successful runs.
- Explicit dangerous output mode (`--dangerously-print-env`).
- Internalized Bitwarden session handling.
- Strict env parsing with malformed input rejection.
- Secure output-file writing behavior.

## Safe usage guidelines

- Avoid `--dangerously-print-env` in shared terminals/CI logs.
- Use dedicated least-privilege Bitwarden accounts for automation.
- Keep test/dev data non-sensitive and clearly separated from production.
- Rotate any credentials or test artifacts if accidentally exposed.
