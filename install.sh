#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"
DEFAULT_REPO="leo020588/envexec"
DEFAULT_REF="main"
DEFAULT_BIN_NAME="envexec"

REPO="${ENVEXEC_REPO:-$DEFAULT_REPO}"
REF="${ENVEXEC_REF:-$DEFAULT_REF}"
BIN_NAME="${ENVEXEC_BIN_NAME:-$DEFAULT_BIN_NAME}"
INSTALL_DIR="${ENVEXEC_INSTALL_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
EXPECTED_SHA256="${ENVEXEC_SHA256:-}"

print_help() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Installs envexec into your user environment (no sudo).

Options:
  --repo <owner/repo>     GitHub repository (default: $DEFAULT_REPO)
  --ref <git-ref>         Branch, tag, or commit SHA (default: $DEFAULT_REF)
  --install-dir <path>    Target bin directory (default: \$XDG_BIN_HOME or ~/.local/bin)
  --bin-name <name>       Installed executable name (default: $DEFAULT_BIN_NAME)
  --help                  Show this help

Environment variables (optional):
  ENVEXEC_REPO, ENVEXEC_REF, ENVEXEC_INSTALL_DIR, ENVEXEC_BIN_NAME
  ENVEXEC_SHA256          Expected SHA256 for integrity verification

Examples:
  curl -fsSL https://raw.githubusercontent.com/$DEFAULT_REPO/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/$DEFAULT_REPO/main/install.sh | bash -s -- --ref v1.0.0
  ENVEXEC_INSTALL_DIR="\$HOME/bin" curl -fsSL https://raw.githubusercontent.com/$DEFAULT_REPO/main/install.sh | bash
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

download_to_file() {
  local url=$1
  local file=$2

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$file"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$file" "$url"
    return 0
  fi

  die "either curl or wget is required"
}

sha256_file() {
  local file=$1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return 0
  fi

  die "no SHA256 tool found (sha256sum, shasum, or openssl)"
}

shell_rc_hint() {
  case "${SHELL:-}" in
    */zsh) printf '%s' "~/.zshrc" ;;
    */bash) printf '%s' "~/.bashrc" ;;
    */fish) printf '%s' "~/.config/fish/config.fish" ;;
    *) printf '%s' "your shell profile" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        REPO=$2
        shift 2
        ;;
      --ref)
        [[ $# -ge 2 ]] || die "--ref requires a value"
        REF=$2
        shift 2
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die "--install-dir requires a value"
        INSTALL_DIR=$2
        shift 2
        ;;
      --bin-name)
        [[ $# -ge 2 ]] || die "--bin-name requires a value"
        BIN_NAME=$2
        shift 2
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        die "unexpected argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ -n "${HOME:-}" ]] || die "HOME is not set"
  [[ -n "$REPO" ]] || die "repository must not be empty"
  [[ -n "$REF" ]] || die "ref must not be empty"
  [[ -n "$BIN_NAME" ]] || die "bin name must not be empty"
  [[ -n "$INSTALL_DIR" ]] || die "install dir must not be empty"

  require_command mktemp
  require_command chmod
  require_command mv
  require_command mkdir
  require_command grep

  local source_url="https://raw.githubusercontent.com/$REPO/$REF/bin/envexec.sh"
  local target_path="$INSTALL_DIR/$BIN_NAME"
  local temp_file

  mkdir -p "$INSTALL_DIR"
  [[ -d "$INSTALL_DIR" ]] || die "install directory does not exist: $INSTALL_DIR"
  [[ -w "$INSTALL_DIR" ]] || die "install directory is not writable: $INSTALL_DIR"

  temp_file="$(mktemp "$INSTALL_DIR/.${BIN_NAME}.tmp.XXXXXX")"
  trap 'rm -f -- "$temp_file"' EXIT

  log "Downloading: $source_url"
  download_to_file "$source_url" "$temp_file"

  grep -q "^#!/usr/bin/env bash" "$temp_file" || die "downloaded file does not look like envexec.sh"

  if [[ -n "$EXPECTED_SHA256" ]]; then
    local actual_sha
    actual_sha="$(sha256_file "$temp_file")"
    if [[ "$actual_sha" != "$EXPECTED_SHA256" ]]; then
      die "checksum mismatch for downloaded file"
    fi
  fi

  chmod 0755 "$temp_file"
  mv -f -- "$temp_file" "$target_path"
  trap - EXIT

  log "Installed: $target_path"
  if "$target_path" --help >/dev/null 2>&1; then
    log "Validation: ok"
  else
    die "installed binary failed --help validation"
  fi

  case ":$PATH:" in
    *":$INSTALL_DIR:"*)
      log "Ready: run '$BIN_NAME --help'"
      ;;
    *)
      local rc_file
      rc_file="$(shell_rc_hint)"
      log "Add to PATH:"
      log "  export PATH=\"$INSTALL_DIR:\$PATH\""
      log "Then reload $rc_file and run '$BIN_NAME --help'"
      ;;
  esac
}

main "$@"
