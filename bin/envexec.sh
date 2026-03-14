#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# envexec
#   Purpose: Load environment variables from Bitwarden/Vaultwarden item notes or local files,
#            then execute a command with that environment.
#   Version: unreleased
#   Repository: https://github.com/leo020588/envexec
# ------------------------------------------------------------------------------

set -euo pipefail

SCRIPT_NAME="${0##*/}"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME <source> [options] -- <command> [args...]
  $SCRIPT_NAME <source> [options]

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

Examples:
  $SCRIPT_NAME --from-file .env.local -- your-command
  $SCRIPT_NAME --from-bw ".env.production" --bw-folder deploy -- your-command
  $SCRIPT_NAME --from-bw ".env.production" --bw-folder deploy --write-env /tmp/prod.env
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

debug_log() {
  [[ "$DEBUG" == "true" ]] || return 0
  printf '%s\n' "$*" >&2
}

DEBUG=false
DANGEROUSLY_PRINT_ENV=false
BW_FOLDER=""
BW_CLI_SESSION=""
FROM_BW=""
FROM_FILE=""
COMMAND_ARGS=()
RAW_CONTENT=""
WRITE_ENV_FILE=""
WRITE_RAW_FILE=""

bw_prepare_context() {
  local status_json
  local bw_status
  local server_url

  require_command bw
  require_command jq
  bw_require_session

  status_json="$(bw status)" || die "failed to query Bitwarden CLI status"
  bw_status="$(bw_parse_status_field status "$status_json")"
  server_url="$(bw_parse_status_field serverUrl "$status_json")"

  debug_log "Bitwarden server: ${server_url:-<not configured>}"

  if [[ "$bw_status" == "unauthenticated" ]]; then
    die "Bitwarden CLI is not logged in; run 'bw login' first"
  fi

  bw_sync_cache
}

bw_sync_cache() {
  local output
  debug_log "Syncing Bitwarden cache"

  if ! output="$(BW_SESSION="$BW_CLI_SESSION" bw --nointeraction sync 2>&1)"; then
    bw_handle_failure "failed to sync Bitwarden cache" "$output"
  fi
}

bw_load_item_notes() {
  local item_name=$1
  local bw_folder=$2
  local folders_json
  local folder_id
  local items_json

  debug_log "Resolving Bitwarden item: name='$item_name' folder='${bw_folder:-<unfiled>}'"

  if [[ -n "$bw_folder" ]]; then
    if ! folders_json="$(bw_read "listing folders" list folders --search "$bw_folder")"; then
      exit 1
    fi
    if ! folder_id="$(bw_extract_folder_id "$bw_folder" "$folders_json")"; then
      exit 1
    fi
    if ! items_json="$(bw_read "listing items in folder '$bw_folder'" list items --folderid "$folder_id" --search "$item_name")"; then
      exit 1
    fi
  else
    if ! items_json="$(bw_read "listing unfiled items" list items --folderid null --search "$item_name")"; then
      exit 1
    fi
  fi

  if ! RAW_CONTENT="$(bw_extract_item_notes "$item_name" "$items_json")"; then
    exit 1
  fi

  debug_log "Loaded raw content from Bitwarden item"
}

bw_read() {
  local description=$1
  shift
  local output

  if ! output="$(BW_SESSION="$BW_CLI_SESSION" bw --nointeraction "$@" 2>&1)"; then
    bw_handle_failure "$description" "$output"
    return 1
  fi

  printf '%s' "$output"
}

bw_extract_folder_id() {
  local folder_name=$1
  local json_input=$2
  local match_count

  match_count="$(jq -r --arg name "$folder_name" '[.[] | select(.name == $name)] | length' <<<"$json_input")"

  if [[ "$match_count" == "0" ]]; then
    printf 'error: folder not found: %s\n' "$folder_name" >&2
    return 1
  fi

  if [[ "$match_count" != "1" ]]; then
    printf 'error: multiple folders matched exactly: %s\n' "$folder_name" >&2
    return 1
  fi

  jq -er --arg name "$folder_name" '.[] | select(.name == $name) | .id' <<<"$json_input" \
    || die "folder has no id: $folder_name"
}

bw_extract_item_notes() {
  local item_name=$1
  local json_input=$2
  local match_count

  match_count="$(jq -r --arg name "$item_name" '[.[] | select(.name == $name)] | length' <<<"$json_input")"

  if [[ "$match_count" == "0" ]]; then
    printf 'error: item not found: %s\n' "$item_name" >&2
    return 1
  fi

  if [[ "$match_count" != "1" ]]; then
    printf 'error: multiple items matched exactly: %s\n' "$item_name" >&2
    return 1
  fi

  jq -er --arg name "$item_name" '.[] | select(.name == $name) | .notes' <<<"$json_input" \
    || die "item has no notes: $item_name"
}

bw_parse_status_field() {
  local field=$1
  local json_input=$2
  jq -r --arg field "$field" '.[$field] // ""' <<<"$json_input"
}

bw_require_session() {
  [[ -n "$BW_CLI_SESSION" ]] || die "BW_SESSION is required; unlock Bitwarden first, for example: export BW_SESSION=\"\$(bw unlock --raw)\""
}

bw_handle_failure() {
  local description=$1
  local output=$2

  if grep -qi 'Vault is locked' <<<"$output"; then
    die "vault is locked; make sure to login and export BW_SESSION first"$'\n> bw login\n> export BW_SESSION="$(bw unlock --raw)"'
  fi

  die "$description failed. bw output: $output"
}

parse_args() {
  BW_CLI_SESSION=""
  FROM_BW=""
  BW_FOLDER=""
  FROM_FILE=""
  DEBUG=false
  DANGEROUSLY_PRINT_ENV=false
  COMMAND_ARGS=()
  RAW_CONTENT=""
  WRITE_ENV_FILE=""
  WRITE_RAW_FILE=""

  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dangerously-print-env)
        DANGEROUSLY_PRINT_ENV=true
        shift
        ;;
      --debug)
        DEBUG=true
        shift
        ;;
      --from-bw)
        [[ $# -ge 2 ]] || die "--from-bw requires a value"
        [[ -z "$FROM_BW" ]] || die "--from-bw may only be provided once"
        FROM_BW=$2
        shift 2
        ;;
      --bw-folder)
        [[ $# -ge 2 ]] || die "--bw-folder requires a value"
        [[ -z "$BW_FOLDER" ]] || die "--bw-folder may only be provided once"
        BW_FOLDER=$2
        shift 2
        ;;
      --from-file)
        [[ $# -ge 2 ]] || die "--from-file requires a value"
        [[ -z "$FROM_FILE" ]] || die "--from-file may only be provided once"
        FROM_FILE=$2
        shift 2
        ;;
      --write-env)
        [[ $# -ge 2 ]] || die "--write-env requires a value"
        [[ -z "$WRITE_ENV_FILE" ]] || die "--write-env may only be provided once"
        WRITE_ENV_FILE=$2
        shift 2
        ;;
      --write-raw)
        [[ $# -ge 2 ]] || die "--write-raw requires a value"
        [[ -z "$WRITE_RAW_FILE" ]] || die "--write-raw may only be provided once"
        WRITE_RAW_FILE=$2
        shift 2
        ;;
      --)
        shift
        COMMAND_ARGS=("$@")
        break
        ;;
      *)
        die "unexpected argument: $1"
        ;;
    esac
  done

  if [[ -n "$FROM_FILE" && -n "$FROM_BW" ]]; then
    die "--from-file cannot be combined with --from-bw"
  fi

  if [[ -n "$FROM_FILE" && -n "$BW_FOLDER" ]]; then
    die "--from-file cannot be combined with --bw-folder"
  fi

  if [[ -n "$BW_FOLDER" && -z "$FROM_BW" ]]; then
    die "--bw-folder requires --from-bw"
  fi

  if [[ -z "$FROM_FILE" && -z "$FROM_BW" ]]; then
    die "must provide one source: --from-file <path> or --from-bw <item>"
  fi

  if [[ "$DANGEROUSLY_PRINT_ENV" == "true" && ${#COMMAND_ARGS[@]} -gt 0 ]]; then
    die "warning: --dangerously-print-env cannot be used with a command"
  fi

  if [[ ${#COMMAND_ARGS[@]} -eq 0 && "$DANGEROUSLY_PRINT_ENV" != "true" && -z "$WRITE_ENV_FILE" && -z "$WRITE_RAW_FILE" ]]; then
    usage >&2
    exit 0
  fi
}

load_raw_from_file() {
  local file_path=$1

  debug_log "Reading raw content from file: $file_path"
  [[ -e "$file_path" ]] || die "env file not found: $file_path"
  [[ -f "$file_path" ]] || die "env file is not a regular file: $file_path"
  [[ -r "$file_path" ]] || die "env file is not readable: $file_path"

  RAW_CONTENT="$(<"$file_path")" || die "failed to read env file: $file_path"
}

write_secure_file() {
  local content=$1
  local target_path=$2
  local description=$3
  local target_dir="."
  local target_name=$target_path
  local temp_file=""

  if [[ -z "$target_path" ]]; then
    return 0
  fi

  debug_log "Writing $description: $target_path"

  if [[ "$target_path" == */* ]]; then
    target_dir=${target_path%/*}
    target_name=${target_path##*/}
    [[ -n "$target_dir" ]] || target_dir=/
  fi

  [[ ! -L "$target_path" ]] || die "refusing to write $description to symlink: $target_path"
  [[ ! -e "$target_path" || -f "$target_path" ]] || die "$description path is not a regular file: $target_path"
  [[ -d "$target_dir" ]] || die "$description directory does not exist: $target_dir"
  [[ -w "$target_dir" ]] || die "$description directory is not writable: $target_dir"

  require_command mktemp

  umask 077
  temp_file="$(mktemp "$target_dir/.${target_name}.tmp.XXXXXX")" || die "failed to create temporary $description: $target_path"
  chmod 600 "$temp_file" || {
    rm -f -- "$temp_file"
    die "failed to set permissions on temporary $description: $temp_file"
  }

  if ! printf '%s' "$content" >"$temp_file"; then
    rm -f -- "$temp_file"
    die "failed to write $description: $target_path"
  fi

  if ! mv -fT -- "$temp_file" "$target_path"; then
    rm -f -- "$temp_file"
    die "failed to finalize $description: $target_path"
  fi
}

parse_env_value() {
  local raw_value=$1
  local line_number=$2
  local first_char=""
  local last_char=""

  while [[ "$raw_value" == [[:space:]]* ]]; do
    raw_value=${raw_value#?}
  done

  while [[ "$raw_value" == *[[:space:]] ]]; do
    raw_value=${raw_value%?}
  done

  if [[ -n "$raw_value" ]]; then
    first_char=${raw_value:0:1}
    last_char=${raw_value: -1}
  fi

  if [[ "$first_char" == "'" || "$first_char" == '"' || "$last_char" == "'" || "$last_char" == '"' ]]; then
    if [[ ${#raw_value} -lt 2 ]]; then
      die "malformed line $line_number in input content: unmatched quote"
    fi

    if [[ "$first_char" != "$last_char" ]]; then
      die "malformed line $line_number in input content: unmatched quote"
    fi

    if [[ "$first_char" != "'" && "$first_char" != '"' ]]; then
      die "malformed line $line_number in input content: unmatched quote"
    fi

    printf '%s' "${raw_value:1:${#raw_value}-2}"
    return 0
  fi

  printf '%s' "$raw_value"
}

export_raw_env() {
  local raw_content=$1
  local dangerously_print_env=$2
  local write_env_file=$3
  local line_number=0
  local line
  local key
  local parsed_output=""
  local value
  local exported_count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ "$line" != *=* ]]; then
      die "malformed line $line_number in input content: missing '='"
    fi

    key=${line%%=*}
    value=${line#*=}

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "invalid environment variable name on line $line_number: $key"
    fi

    if ! value="$(parse_env_value "$value" "$line_number")"; then
      exit 1
    fi

    export "$key=$value"
    exported_count=$((exported_count + 1))
    if [[ "$dangerously_print_env" == "true" ]]; then
      printf '%s=%s\n' "$key" "$value" >&2
    fi
    parsed_output+="${key}=${value}"$'\n'
  done <<<"$raw_content"

  write_secure_file "$parsed_output" "$write_env_file" "env file"
  debug_log "Exported environment variables: $exported_count"
}

write_raw_content() {
  local raw_content=$1
  local write_raw_file=$2

  write_secure_file "$raw_content" "$write_raw_file" "raw file"
}

run_target_command() {
  if [[ $# -eq 0 ]]; then
    exit 0
  fi

  exec "$@"
}

main() {
  parse_args "$@"
  BW_CLI_SESSION=${BW_SESSION:-}
  unset BW_SESSION

  if [[ -n "$FROM_FILE" ]]; then
    debug_log "Source mode: from-file"
    load_raw_from_file "$FROM_FILE"
  else
    debug_log "Source mode: from-bw"
    bw_prepare_context
    bw_load_item_notes "$FROM_BW" "$BW_FOLDER"
  fi

  write_raw_content "$RAW_CONTENT" "$WRITE_RAW_FILE"
  export_raw_env "$RAW_CONTENT" "$DANGEROUSLY_PRINT_ENV" "$WRITE_ENV_FILE"
  if [[ ${#COMMAND_ARGS[@]} -gt 0 ]]; then
    debug_log "Executing target command"
  fi
  run_target_command "${COMMAND_ARGS[@]}"
}

main "$@"
