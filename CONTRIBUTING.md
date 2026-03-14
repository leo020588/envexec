# Contributing

Thanks for contributing to `envexec`.

## Development setup

- Bash environment (Linux/macOS/WSL)
- Node.js (used by test helpers)
- For full integration tests: Docker, Bitwarden CLI (`bw`), `jq`

## Test commands

Primary integration suite:

```bash
./tests/integration.test.sh
```

Quick checks:

```bash
bash -n bin/envexec.sh tests/integration.test.sh install.sh
node --check tests/helpers/test.js
```

## Project conventions

- Keep successful CLI runs quiet.
- Keep dangerous behaviors explicit and opt-in.
- Prefer explicit errors over silent fallbacks.
- Maintain strict env parsing semantics.
- Preserve security-focused defaults.

## Pull request guidelines

- Describe behavior changes and rationale.
- Add/update tests for behavior changes.
- Keep commits focused and minimal.
- Update README/SECURITY docs when user-facing behavior changes.
