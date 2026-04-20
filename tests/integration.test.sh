#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENVEXEC="$ROOT_DIR/bin/envexec.sh"
TEST_JS="$SCRIPT_DIR/helpers/test.js"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
DEV_COMPOSE_FILE="$ROOT_DIR/dev/docker-compose.yml"

BW_ITEM="${BW_ITEM:-.env.testing}"
BW_FOLDER_NAME="${BW_FOLDER_NAME:-testing}"
BW_SERVER_URL="${BW_SERVER_URL:-https://localhost:444}"
BW_EMAIL="${BW_EMAIL:-user@localhost}"
BW_PASSWORD="${BW_PASSWORD:-user@localhost#pass}"
BW_SETUP_ERR=""
RBW_SETUP_ERR=""
AUTO_DOCKER_DOWN="${AUTO_DOCKER_DOWN:-1}"
COMPOSE_STARTED_BY_TEST=0

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
  if [[ "$AUTO_DOCKER_DOWN" == "1" && "$COMPOSE_STARTED_BY_TEST" == "1" ]] && command -v docker >/dev/null 2>&1; then
    docker compose -f "$DEV_COMPOSE_FILE" down >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

TOTAL=0
PASS=0
FAIL=0
SKIP=0

pass() {
  local name=$1
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  printf '✅ PASS: %s\n' "$name"
}

fail() {
  local name=$1
  local detail=$2
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  printf '❌ FAIL: %s\n' "$name"
  if [[ -n "$detail" ]]; then
    printf '   %s\n' "$detail"
  fi
}

skip() {
  local name=$1
  local reason=$2
  TOTAL=$((TOTAL + 1))
  SKIP=$((SKIP + 1))
  printf '⏭️  SKIP: %s\n' "$name"
  if [[ -n "$reason" ]]; then
    printf '   %s\n' "$reason"
  fi
}

safe_name() {
  printf '%s' "$1" | tr -cs '[:alnum:]._-' '_'
}

expect_success() {
  local name=$1
  shift
  local slug
  slug="$(safe_name "$name")"
  local out_file="$TMP_DIR/${slug}.out"
  local err_file="$TMP_DIR/${slug}.err"

  if "$@" >"$out_file" 2>"$err_file"; then
    pass "$name"
    return 0
  fi

  fail "$name" "command failed unexpectedly: $*"
  sed 's/^/   stderr: /' "$err_file"
  return 1
}

expect_failure_contains() {
  local name=$1
  local expected=$2
  shift 2
  local slug
  slug="$(safe_name "$name")"
  local out_file="$TMP_DIR/${slug}.out"
  local err_file="$TMP_DIR/${slug}.err"
  local combined_file="$TMP_DIR/${slug}.combined"

  if "$@" >"$out_file" 2>"$err_file"; then
    fail "$name" "command succeeded unexpectedly: $*"
    return 1
  fi

  cat "$out_file" "$err_file" >"$combined_file"
  if grep -F -- "$expected" "$combined_file" >/dev/null; then
    pass "$name"
    return 0
  fi

  fail "$name" "missing expected text: $expected"
  sed 's/^/   output: /' "$combined_file"
  return 1
}

expect_file_equals() {
  local name=$1
  local expected_file=$2
  local actual_file=$3
  if diff -u "$expected_file" "$actual_file" >"$TMP_DIR/diff.out" 2>&1; then
    pass "$name"
    return 0
  fi
  fail "$name" "file mismatch: $expected_file vs $actual_file"
  sed 's/^/   /' "$TMP_DIR/diff.out"
  return 1
}

expect_file_equals_ignoring_final_newline() {
  local name=$1
  local expected_file=$2
  local actual_file=$3

  if node -e '
const fs = require("fs");
function normalize(buf) {
  if (buf.length > 0 && buf[buf.length - 1] === 10) {
    return buf.subarray(0, buf.length - 1);
  }
  return buf;
}
const left = normalize(fs.readFileSync(process.argv[1]));
const right = normalize(fs.readFileSync(process.argv[2]));
process.exit(Buffer.compare(left, right) === 0 ? 0 : 1);
' "$expected_file" "$actual_file"; then
    pass "$name"
    return 0
  fi

  fail "$name" "content mismatch (ignoring final newline): $expected_file vs $actual_file"
  return 1
}

bw_prepare_session() {
  BW_SETUP_ERR=""
  command -v bw >/dev/null 2>&1 || {
    BW_SETUP_ERR="required command missing: bw"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    BW_SETUP_ERR="required command missing: jq"
    return 1
  }
  command -v docker >/dev/null 2>&1 || {
    BW_SETUP_ERR="required command missing: docker"
    return 1
  }

  if ! docker compose -f "$DEV_COMPOSE_FILE" config -q >/dev/null 2>&1; then
    BW_SETUP_ERR="docker compose config validation failed for $DEV_COMPOSE_FILE"
    return 1
  fi

  local running_services
  running_services="$(docker compose -f "$DEV_COMPOSE_FILE" ps --services --filter status=running 2>/dev/null || true)"
  if ! grep -Fx "vaultwarden" <<<"$running_services" >/dev/null || ! grep -Fx "nginx" <<<"$running_services" >/dev/null; then
    if ! docker compose -f "$DEV_COMPOSE_FILE" up -d >/dev/null 2>&1; then
      BW_SETUP_ERR="failed to start dev compose stack using $DEV_COMPOSE_FILE"
      return 1
    fi
    COMPOSE_STARTED_BY_TEST=1
    running_services="$(docker compose -f "$DEV_COMPOSE_FILE" ps --services --filter status=running 2>/dev/null || true)"
    if ! grep -Fx "vaultwarden" <<<"$running_services" >/dev/null || ! grep -Fx "nginx" <<<"$running_services" >/dev/null; then
      BW_SETUP_ERR="dev compose stack is not fully running (expected: vaultwarden, nginx)"
      return 1
    fi
  fi

  export NODE_TLS_REJECT_UNAUTHORIZED="${NODE_TLS_REJECT_UNAUTHORIZED:-0}"

  local config_err_file
  config_err_file="$(mktemp)"
  if ! bw config server "$BW_SERVER_URL" >/dev/null 2>"$config_err_file"; then
    if grep -F "Logout required before server config update" "$config_err_file" >/dev/null; then
      bw logout >/dev/null 2>&1 || true
      if ! bw config server "$BW_SERVER_URL" >/dev/null 2>>"$config_err_file"; then
        BW_SETUP_ERR="$(cat "$config_err_file")"
        rm -f "$config_err_file"
        return 1
      fi
    else
      BW_SETUP_ERR="$(cat "$config_err_file")"
      rm -f "$config_err_file"
      return 1
    fi
  fi
  rm -f "$config_err_file"

  if ! bw login "$BW_EMAIL" "$BW_PASSWORD" >/dev/null 2>&1; then
    if ! bw login --check >/dev/null 2>&1; then
      BW_SETUP_ERR="bw login failed for $BW_EMAIL"
      return 1
    fi
  fi

  local unlocked_session
  if ! unlocked_session="$(BW_PASSWORD="$BW_PASSWORD" bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null)"; then
    BW_SETUP_ERR="bw unlock failed for $BW_EMAIL"
    return 1
  fi
  BW_SESSION="$unlocked_session"
  export BW_SESSION

  if ! bw --session "$BW_SESSION" sync >/dev/null 2>&1; then
    BW_SETUP_ERR="bw sync failed"
    return 1
  fi

  return 0
}

# Creates a temp dir with a mock rbw script.
# Behavior is controlled by env vars passed to the child process:
#   MOCK_RBW_SYNC_FAIL=1  → rbw sync exits 1
#   MOCK_RBW_GET_FAIL=1   → rbw get exits 1
#   MOCK_RBW_NOTES=<text> → text returned by rbw get --field=notes
make_mock_rbw() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/rbw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  sync)
    [[ "${MOCK_RBW_SYNC_FAIL:-0}" != "1" ]] || { printf 'sync error: vault locked\n' >&2; exit 1; }
    exit 0
    ;;
  get)
    [[ "${MOCK_RBW_GET_FAIL:-0}" != "1" ]] || { printf 'no entry found\n' >&2; exit 1; }
    printf '%s' "${MOCK_RBW_NOTES:-}"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/rbw"
  printf '%s' "$dir"
}

# Checks whether rbw is configured and synced; sets RBW_SETUP_ERR on failure.
rbw_prepare_session() {
  RBW_SETUP_ERR=""
  command -v rbw >/dev/null 2>&1 || {
    RBW_SETUP_ERR="required command missing: rbw"
    return 1
  }
  if ! rbw sync >/dev/null 2>&1; then
    RBW_SETUP_ERR="rbw sync failed (run 'rbw login' and 'rbw unlock' first)"
    return 1
  fi
  if ! rbw get --folder "$BW_FOLDER_NAME" --field=notes "$BW_ITEM" >/dev/null 2>&1; then
    RBW_SETUP_ERR="rbw test item not found: '$BW_ITEM' in folder '$BW_FOLDER_NAME'"
    return 1
  fi
  return 0
}

# Returns a PATH string with rbw's directory filtered out (preserving bw).
# When rbw and bw share a directory, a shadow dir with only bw is prepended.


require_command_exists() {
  local cmd=$1
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "command available: $cmd"
  else
    fail "command available: $cmd" "required command missing: $cmd"
  fi
}

main() {
  require_command_exists bash
  require_command_exists node
  require_command_exists diff
  require_command_exists bw
  require_command_exists jq
  require_command_exists stat

  expect_success "script syntax check" bash -n "$ENVEXEC"
  expect_success "help output" bash "$ENVEXEC" --help
  expect_success "no args prints usage" bash "$ENVEXEC"

  expect_failure_contains "missing source with debug" "must provide one source" \
    bash "$ENVEXEC" --debug
  expect_failure_contains "dangerous print cannot be combined with command" "cannot be used with a command" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --dangerously-print-env -- true
  expect_failure_contains "missing source with dangerous print" "must provide one source" \
    bash "$ENVEXEC" --dangerously-print-env
  expect_failure_contains "unexpected positional argument" "unexpected argument: positional" \
    bash "$ENVEXEC" positional --dangerously-print-env
  expect_failure_contains "from-file and from-bw conflict" "cannot be combined with --from-bw" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --from-bw "$BW_ITEM" --dangerously-print-env
  expect_failure_contains "from-file and bw-folder conflict" "cannot be combined with --bw-folder" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --bw-folder "$BW_FOLDER_NAME" --dangerously-print-env
  expect_failure_contains "bw-folder requires from-bw" "--bw-folder requires --from-bw" \
    bash "$ENVEXEC" --bw-folder "$BW_FOLDER_NAME" --dangerously-print-env

  expect_failure_contains "duplicate from-file" "--from-file may only be provided once" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --from-file "$FIXTURES_DIR/valid.env" --dangerously-print-env
  expect_failure_contains "duplicate from-bw" "--from-bw may only be provided once" \
    bash "$ENVEXEC" --from-bw "$BW_ITEM" --from-bw "$BW_ITEM" --dangerously-print-env
  expect_failure_contains "duplicate bw-folder" "--bw-folder may only be provided once" \
    bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" --bw-folder "$BW_FOLDER_NAME" --dangerously-print-env
  expect_failure_contains "duplicate write-env" "--write-env may only be provided once" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-env "$TMP_DIR/a.env" --write-env "$TMP_DIR/b.env" --dangerously-print-env
  expect_failure_contains "duplicate write-raw" "--write-raw may only be provided once" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-raw "$TMP_DIR/a.raw" --write-raw "$TMP_DIR/b.raw" --dangerously-print-env

  expect_failure_contains "from-file missing file" "env file not found" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/does-not-exist.env" --dangerously-print-env

  mkdir -p "$TMP_DIR/dir-as-file"
  expect_failure_contains "from-file not regular file" "env file is not a regular file" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/dir-as-file" --dangerously-print-env

  cat >"$TMP_DIR/unreadable.env" <<'EOF'
FOO=bar
EOF
  chmod 000 "$TMP_DIR/unreadable.env"
  expect_failure_contains "from-file unreadable file" "env file is not readable" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/unreadable.env" --dangerously-print-env
  chmod 600 "$TMP_DIR/unreadable.env"

  local parsed_env="$TMP_DIR/parsed.env"
  local raw_out="$TMP_DIR/raw.out"
  local preexisting_env="$TMP_DIR/preexisting.env"
  local preexisting_raw="$TMP_DIR/preexisting.raw"
  local symlink_target="$TMP_DIR/symlink-target.txt"
  local symlink_path="$TMP_DIR/symlink.env"
  local debug_stdout="$TMP_DIR/debug.stdout"
  local debug_stderr="$TMP_DIR/debug.stderr"
  local quiet_stdout="$TMP_DIR/quiet.stdout"
  local quiet_stderr="$TMP_DIR/quiet.stderr"
  expect_success "from-file parse/write outputs" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-env "$parsed_env" --write-raw "$raw_out" --dangerously-print-env

  expect_file_equals "write-env matches expected fixture" "$FIXTURES_DIR/valid.expected" "$parsed_env"
  expect_file_equals_ignoring_final_newline "write-raw matches source fixture" "$FIXTURES_DIR/valid.env" "$raw_out"
  if [[ "$(stat -c %a "$parsed_env")" == "600" ]]; then
    pass "write-env uses 0600 permissions"
  else
    fail "write-env uses 0600 permissions" "expected mode 600, got $(stat -c %a "$parsed_env")"
  fi
  if [[ "$(stat -c %a "$raw_out")" == "600" ]]; then
    pass "write-raw uses 0600 permissions"
  else
    fail "write-raw uses 0600 permissions" "expected mode 600, got $(stat -c %a "$raw_out")"
  fi

  : >"$preexisting_env"
  chmod 0644 "$preexisting_env"
  expect_success "write-env hardens existing file permissions" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-env "$preexisting_env" --dangerously-print-env
  if [[ "$(stat -c %a "$preexisting_env")" == "600" ]]; then
    pass "write-env resets existing file to 0600"
  else
    fail "write-env resets existing file to 0600" "expected mode 600, got $(stat -c %a "$preexisting_env")"
  fi

  : >"$preexisting_raw"
  chmod 0644 "$preexisting_raw"
  expect_success "write-raw hardens existing file permissions" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-raw "$preexisting_raw" --dangerously-print-env
  if [[ "$(stat -c %a "$preexisting_raw")" == "600" ]]; then
    pass "write-raw resets existing file to 0600"
  else
    fail "write-raw resets existing file to 0600" "expected mode 600, got $(stat -c %a "$preexisting_raw")"
  fi

  printf 'ORIGINAL\n' >"$symlink_target"
  ln -s "$symlink_target" "$symlink_path"
  expect_failure_contains "write-env rejects symlink path" "refusing to write env file to symlink" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-env "$symlink_path" --dangerously-print-env
  expect_failure_contains "write-raw rejects symlink path" "refusing to write raw file to symlink" \
    bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --write-raw "$symlink_path" --dangerously-print-env

  if bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --dangerously-print-env >"$debug_stdout" 2>"$debug_stderr"; then
    if [[ ! -s "$debug_stdout" ]] && grep -F "BASIC=bar" "$debug_stderr" >/dev/null; then
      pass "dangerous env output goes to stderr"
    else
      fail "dangerous env output goes to stderr" "expected empty stdout and env dump on stderr"
    fi
  else
    fail "dangerous env output goes to stderr" "envexec debug run failed unexpectedly"
  fi

  if bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" -- true >"$quiet_stdout" 2>"$quiet_stderr"; then
    if [[ ! -s "$quiet_stdout" ]] && [[ ! -s "$quiet_stderr" ]]; then
      pass "successful from-file run is quiet by default"
    else
      fail "successful from-file run is quiet by default" "expected empty stdout/stderr"
    fi
  else
    fail "successful from-file run is quiet by default" "envexec from-file run failed unexpectedly"
  fi

  if bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" --debug -- true >"$quiet_stdout" 2>"$quiet_stderr"; then
    if [[ ! -s "$quiet_stdout" ]] && grep -F "Source mode: from-file" "$quiet_stderr" >/dev/null; then
      pass "debug mode prints operational trace information"
    else
      fail "debug mode prints operational trace information" "expected trace logs on stderr only"
    fi
  else
    fail "debug mode prints operational trace information" "envexec debug trace run failed unexpectedly"
  fi

  local expected_env_json
  expected_env_json='{"BASIC":"bar","SINGLE":"bar","DOUBLE":"bar","UNQUOTED_TRIM":"around edges","SINGLE_PAD":"  padded single  ","DOUBLE_PAD":"  padded double  ","EQUALS":"foo=bar=baz","DOUBLE_HASH":"#still-literal","BW_SESSION":""}'
  expect_success "from-file helper validates expected injected variables" \
    env BW_SESSION=ambient-session-value bash "$ENVEXEC" --from-file "$FIXTURES_DIR/valid.env" -- env "EXPECTED_ENV_JSON=$expected_env_json" node "$TEST_JS"

  cat >"$TMP_DIR/bad-missing-equals.env" <<'EOF'
NOT_A_PAIR
EOF
  expect_failure_contains "reject missing equals line" "missing '='" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/bad-missing-equals.env" --dangerously-print-env

  cat >"$TMP_DIR/bad-invalid-key.env" <<'EOF'
1INVALID=value
EOF
  expect_failure_contains "reject invalid variable name" "invalid environment variable name" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/bad-invalid-key.env" --dangerously-print-env

  cat >"$TMP_DIR/bad-unmatched-open.env" <<'EOF'
BAD='value
EOF
  expect_failure_contains "reject unmatched opening quote" "unmatched quote" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/bad-unmatched-open.env" --dangerously-print-env

  cat >"$TMP_DIR/bad-unmatched-tail.env" <<'EOF'
BAD=value'
EOF
  expect_failure_contains "reject unmatched trailing quote" "unmatched quote" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/bad-unmatched-tail.env" --dangerously-print-env

  cat >"$TMP_DIR/spaces.env" <<'EOF'
UNQUOTED=   trim me   
QUOTED='  keep me  '
EOF
  cat >"$TMP_DIR/spaces.expected" <<'EOF'
UNQUOTED=trim me
QUOTED=  keep me  
EOF
  expect_success "whitespace parsing behavior" \
    bash "$ENVEXEC" --from-file "$TMP_DIR/spaces.env" --write-env "$TMP_DIR/spaces.actual" --dangerously-print-env
  expect_file_equals "whitespace expected output" "$TMP_DIR/spaces.expected" "$TMP_DIR/spaces.actual"

  # --------------------------------------------------------------------------
  # rbw mock-based tests (always run; use a fake rbw binary via PATH override)
  # --------------------------------------------------------------------------
  local mock_rbw_dir
  mock_rbw_dir="$(make_mock_rbw)"
  local empty_dir
  empty_dir="$(mktemp -d)"
  local bash_bin
  bash_bin="$(command -v bash)"

  expect_failure_contains "no bw backend in PATH" "no Bitwarden CLI found" \
    env PATH="$empty_dir" "$bash_bin" "$ENVEXEC" --from-bw "myitem" --dangerously-print-env

  local rbw_detect_err="$TMP_DIR/rbw-detect.err"
  if env PATH="$mock_rbw_dir:$PATH" \
         MOCK_RBW_NOTES="DETECT_TEST=1" \
         bash "$ENVEXEC" --from-bw "myitem" --debug -- true \
         >/dev/null 2>"$rbw_detect_err"; then
    if grep -F "Bitwarden backend: rbw" "$rbw_detect_err" >/dev/null; then
      pass "rbw backend selected when rbw is in PATH"
    else
      fail "rbw backend selected when rbw is in PATH" "expected 'Bitwarden backend: rbw' in debug output"
    fi
  else
    fail "rbw backend selected when rbw is in PATH" "command failed unexpectedly"
  fi

  if command -v rbw >/dev/null 2>&1; then
    skip "bw fallback when rbw unavailable" "rbw is installed; bw fallback test not applicable"
  else
    local mock_bw_only_dir
    mock_bw_only_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bw_only_dir/bw"
    chmod +x "$mock_bw_only_dir/bw"
    expect_failure_contains "bw fallback when rbw unavailable" "BW_SESSION is required" \
      env PATH="$mock_bw_only_dir:$PATH" bash "$ENVEXEC" --from-bw "myitem" --dangerously-print-env
  fi

  expect_failure_contains "rbw sync failure is reported" "failed to sync rbw cache" \
    env PATH="$mock_rbw_dir:$PATH" \
        MOCK_RBW_SYNC_FAIL=1 \
        bash "$ENVEXEC" --from-bw "myitem" --dangerously-print-env

  expect_failure_contains "rbw item not found is reported" "failed to get item 'myitem'" \
    env PATH="$mock_rbw_dir:$PATH" \
        MOCK_RBW_GET_FAIL=1 \
        bash "$ENVEXEC" --from-bw "myitem" --dangerously-print-env

  expect_failure_contains "rbw item-not-found includes folder name" "in folder 'myfolder'" \
    env PATH="$mock_rbw_dir:$PATH" \
        MOCK_RBW_GET_FAIL=1 \
        bash "$ENVEXEC" --from-bw "myitem" --bw-folder "myfolder" --dangerously-print-env

  local rbw_write_env="$TMP_DIR/rbw-mock-write.env"
  expect_success "rbw loads notes and exports env vars" \
    env PATH="$mock_rbw_dir:$PATH" \
        MOCK_RBW_NOTES=$'MOCK_A=valueA\nMOCK_B=valueB' \
        bash "$ENVEXEC" --from-bw "myitem" --write-env "$rbw_write_env" -- true
  if [[ -f "$rbw_write_env" ]]; then
    cat >"$TMP_DIR/rbw-mock-expected.env" <<'EOF'
MOCK_A=valueA
MOCK_B=valueB
EOF
    expect_file_equals "rbw mock written env matches expected" \
      "$TMP_DIR/rbw-mock-expected.env" "$rbw_write_env"
  else
    fail "rbw mock written env file exists" "file not found: $rbw_write_env"
  fi

  local rbw_folder_write_env="$TMP_DIR/rbw-folder-write.env"
  expect_success "rbw loads notes with --bw-folder" \
    env PATH="$mock_rbw_dir:$PATH" \
        MOCK_RBW_NOTES=$'FOLDER_VAR=ok' \
        bash "$ENVEXEC" --from-bw "myitem" --bw-folder "myfolder" \
             --write-env "$rbw_folder_write_env" -- true

  local rbw_quiet_out="$TMP_DIR/rbw-quiet.stdout"
  local rbw_quiet_err="$TMP_DIR/rbw-quiet.stderr"
  if env PATH="$mock_rbw_dir:$PATH" \
         MOCK_RBW_NOTES="QUIET_VAR=1" \
         bash "$ENVEXEC" --from-bw "myitem" -- true \
         >"$rbw_quiet_out" 2>"$rbw_quiet_err"; then
    if [[ ! -s "$rbw_quiet_out" ]] && [[ ! -s "$rbw_quiet_err" ]]; then
      pass "successful rbw run is quiet by default"
    else
      fail "successful rbw run is quiet by default" "expected empty stdout/stderr"
    fi
  else
    fail "successful rbw run is quiet by default" "command failed unexpectedly"
  fi

  local rbw_debug_out="$TMP_DIR/rbw-debug.stdout"
  local rbw_debug_err="$TMP_DIR/rbw-debug.stderr"
  if env PATH="$mock_rbw_dir:$PATH" \
         MOCK_RBW_NOTES="TRACE_VAR=1" \
         bash "$ENVEXEC" --from-bw "myitem" --debug -- true \
         >"$rbw_debug_out" 2>"$rbw_debug_err"; then
    if [[ ! -s "$rbw_debug_out" ]] && grep -F "Bitwarden backend: rbw" "$rbw_debug_err" >/dev/null; then
      pass "rbw debug mode prints backend and trace on stderr"
    else
      fail "rbw debug mode prints backend and trace on stderr" "expected trace on stderr only"
    fi
  else
    fail "rbw debug mode prints backend and trace on stderr" "command failed unexpectedly"
  fi

  if bw_prepare_session; then
    pass "bw direct connection setup ($BW_SERVER_URL / $BW_EMAIL)"
    local bw_parsed="$TMP_DIR/bw.parsed.env"
    local bw_raw="$TMP_DIR/bw.raw.out"
    local bw_expected_raw="$TMP_DIR/bw.expected.raw"
    local bw_expected_parsed="$TMP_DIR/bw.expected.parsed"
    local bw_expected_json_file="$TMP_DIR/bw.expected.json"
    local bw_expected_json
    local folders_json
    local folder_count
    local folder_id
    local items_json
    local item_count
    local item_id
    local item_json
    local item_notes

    folders_json="$(bw --session "$BW_SESSION" list folders --search "$BW_FOLDER_NAME")"
    folder_count="$(jq -r --arg name "$BW_FOLDER_NAME" '[.[] | select(.name == $name)] | length' <<<"$folders_json")"
    if [[ "$folder_count" == "1" ]]; then
      pass "bw folder resolved: $BW_FOLDER_NAME"
    else
      fail "bw folder resolved: $BW_FOLDER_NAME" "expected exactly one folder, found $folder_count"
    fi
    folder_id="$(jq -r --arg name "$BW_FOLDER_NAME" '.[] | select(.name == $name) | .id' <<<"$folders_json")"

    items_json="$(bw --session "$BW_SESSION" list items --folderid "$folder_id" --search "$BW_ITEM")"
    item_count="$(jq -r --arg name "$BW_ITEM" '[.[] | select(.name == $name)] | length' <<<"$items_json")"
    if [[ "$item_count" == "1" ]]; then
      pass "bw item resolved: $BW_ITEM"
    else
      fail "bw item resolved: $BW_ITEM" "expected exactly one item, found $item_count"
    fi
    item_id="$(jq -r --arg name "$BW_ITEM" '.[] | select(.name == $name) | .id' <<<"$items_json")"
    item_json="$(bw --session "$BW_SESSION" get item "$item_id")"
    item_notes="$(jq -r '.notes // ""' <<<"$item_json")"
    printf '%s' "$item_notes" >"$bw_expected_raw"

    expect_success "bw source dangerous-print run ($BW_ITEM / $BW_FOLDER_NAME)" \
      env BW_BACKEND=bw bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" --dangerously-print-env
    expect_success "bw source write outputs ($BW_ITEM / $BW_FOLDER_NAME)" \
      env BW_BACKEND=bw bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" --write-env "$bw_parsed" --write-raw "$bw_raw" -- true

    if env BW_BACKEND=bw bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" -- true >"$quiet_stdout" 2>"$quiet_stderr"; then
      if [[ ! -s "$quiet_stdout" ]] && [[ ! -s "$quiet_stderr" ]]; then
        pass "successful bw run is quiet by default"
      else
        fail "successful bw run is quiet by default" "expected empty stdout/stderr"
      fi
    else
      fail "successful bw run is quiet by default" "envexec bw run failed unexpectedly"
    fi

    if env BW_BACKEND=bw bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" --debug -- true >"$quiet_stdout" 2>"$quiet_stderr"; then
      if [[ ! -s "$quiet_stdout" ]] && grep -F "Bitwarden server:" "$quiet_stderr" >/dev/null; then
        pass "debug mode prints informational bw messages"
      else
        fail "debug mode prints informational bw messages" "expected bw info message on stderr only"
      fi
    else
      fail "debug mode prints informational bw messages" "envexec debug bw run failed unexpectedly"
    fi

    if [[ -s "$bw_parsed" ]]; then
      pass "bw parsed output is non-empty"
    else
      fail "bw parsed output is non-empty" "expected $bw_parsed to be non-empty"
    fi

    if [[ -s "$bw_raw" ]]; then
      pass "bw raw output is non-empty"
    else
      fail "bw raw output is non-empty" "expected $bw_raw to be non-empty"
    fi

    expect_file_equals_ignoring_final_newline "bw raw matches direct bw item notes" "$bw_expected_raw" "$bw_raw"
    expect_success "baseline parse from direct bw notes" \
      bash "$ENVEXEC" --from-file "$bw_expected_raw" --write-env "$bw_expected_parsed" --dangerously-print-env
    expect_file_equals "bw parsed matches baseline parse of direct notes" "$bw_expected_parsed" "$bw_parsed"
    node -e '
const fs = require("fs");
const input = fs.readFileSync(process.argv[1], "utf8");
const lines = input.split(/\r?\n/).filter(Boolean);
const out = {};
for (const line of lines) {
  const idx = line.indexOf("=");
  if (idx < 0) continue;
  const key = line.slice(0, idx);
  const value = line.slice(idx + 1);
  out[key] = value;
}
out.BW_SESSION = "";
process.stdout.write(JSON.stringify(out));
' "$bw_expected_parsed" >"$bw_expected_json_file"
    bw_expected_json="$(cat "$bw_expected_json_file")"
    expect_success "bw helper validates expected injected variables" \
      env BW_BACKEND=bw bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" -- env "EXPECTED_ENV_JSON=$bw_expected_json" node "$TEST_JS"
  else
    fail "bw direct connection setup ($BW_SERVER_URL / $BW_EMAIL)" "$BW_SETUP_ERR"
  fi

  # --------------------------------------------------------------------------
  # rbw integration tests (require rbw to be configured for the test vault)
  #
  # These tests run only when rbw can reach the test vault item. They are
  # SKIPPED (not failed) when rbw is absent, sync fails, or the item is not
  # found — which is the normal case when rbw is configured for a personal
  # vault rather than the local dev Vaultwarden instance.
  #
  # To enable: point rbw at the dev Vaultwarden and ensure the test item exists.
  #   rbw config set base_url https://localhost:444
  #   rbw config set email user@localhost
  #   rbw login && rbw unlock
  # Note: rbw uses rustls and does not honour SSL_CERT_FILE; the self-signed
  # dev cert must be trusted at the OS level (e.g. sudo trust anchor / update-ca-certificates).
  # --------------------------------------------------------------------------
  if rbw_prepare_session; then
    pass "rbw connection setup"

    local rbw_parsed="$TMP_DIR/rbw.parsed.env"
    local rbw_raw="$TMP_DIR/rbw.raw.out"

    expect_success "rbw source write outputs ($BW_ITEM / $BW_FOLDER_NAME)" \
      bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" \
           --write-env "$rbw_parsed" --write-raw "$rbw_raw" -- true

    local rbw_int_quiet_out="$TMP_DIR/rbw-int-quiet.stdout"
    local rbw_int_quiet_err="$TMP_DIR/rbw-int-quiet.stderr"
    if bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" -- true \
         >"$rbw_int_quiet_out" 2>"$rbw_int_quiet_err"; then
      if [[ ! -s "$rbw_int_quiet_out" ]] && [[ ! -s "$rbw_int_quiet_err" ]]; then
        pass "successful rbw integration run is quiet"
      else
        fail "successful rbw integration run is quiet" "expected empty stdout/stderr"
      fi
    else
      fail "successful rbw integration run is quiet" "command failed unexpectedly"
    fi

    local rbw_int_debug_out="$TMP_DIR/rbw-int-debug.stdout"
    local rbw_int_debug_err="$TMP_DIR/rbw-int-debug.stderr"
    if bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" --debug -- true \
         >"$rbw_int_debug_out" 2>"$rbw_int_debug_err"; then
      if [[ ! -s "$rbw_int_debug_out" ]] && grep -F "Bitwarden backend: rbw" "$rbw_int_debug_err" >/dev/null; then
        pass "rbw integration debug shows rbw backend"
      else
        fail "rbw integration debug shows rbw backend" "expected 'Bitwarden backend: rbw' on stderr only"
      fi
    else
      fail "rbw integration debug shows rbw backend" "command failed unexpectedly"
    fi

    if [[ -s "$rbw_parsed" ]]; then
      pass "rbw integration parsed output is non-empty"
    else
      fail "rbw integration parsed output is non-empty" "expected $rbw_parsed to be non-empty"
    fi

    if [[ -s "$rbw_raw" ]]; then
      pass "rbw integration raw output is non-empty"
    else
      fail "rbw integration raw output is non-empty" "expected $rbw_raw to be non-empty"
    fi

    local rbw_expected_parsed="$TMP_DIR/rbw.expected.parsed"
    expect_success "rbw baseline parse from raw notes" \
      bash "$ENVEXEC" --from-file "$rbw_raw" --write-env "$rbw_expected_parsed" --dangerously-print-env
    expect_file_equals "rbw parsed matches baseline parse of raw notes" "$rbw_expected_parsed" "$rbw_parsed"

    local rbw_expected_json_file="$TMP_DIR/rbw.expected.json"
    local rbw_expected_json
    node -e '
const fs = require("fs");
const input = fs.readFileSync(process.argv[1], "utf8");
const lines = input.split(/\r?\n/).filter(Boolean);
const out = {};
for (const line of lines) {
  const idx = line.indexOf("=");
  if (idx < 0) continue;
  const key = line.slice(0, idx);
  const value = line.slice(idx + 1);
  out[key] = value;
}
out.BW_SESSION = "";
process.stdout.write(JSON.stringify(out));
' "$rbw_expected_parsed" >"$rbw_expected_json_file"
    rbw_expected_json="$(cat "$rbw_expected_json_file")"
    expect_success "rbw helper validates expected injected variables" \
      bash "$ENVEXEC" --from-bw "$BW_ITEM" --bw-folder "$BW_FOLDER_NAME" \
           -- env "EXPECTED_ENV_JSON=$rbw_expected_json" node "$TEST_JS"
  else
    skip "rbw connection setup" "$RBW_SETUP_ERR"
  fi

  printf '\n'
  printf '========== envexec test summary ==========\n'
  printf 'Total:   %d\n' "$TOTAL"
  printf '✅ Pass: %d\n' "$PASS"
  printf '❌ Fail: %d\n' "$FAIL"
  printf '⏭️  Skip: %d\n' "$SKIP"
  printf '==========================================\n'

  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
