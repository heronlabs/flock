#!/usr/bin/env bats

# sizing.bats — Tests for scripts/sizing.sh
#
# Explicit --cpus/--memory skip detection entirely. Detection tests put a mock
# `docker` (and `nproc`) first on PATH, so the real Docker daemon and host
# size never leak into the expected values.

# $stderr is assigned by bats' `run --separate-stderr`.
# shellcheck disable=SC2154

bats_require_minimum_version 1.5.0

setup() {
  # Repo root (one level up from test/)
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SIZING="$ROOT/scripts/sizing.sh"

  TMP_DIR="$(mktemp -d)"
  MOCK_DIR="$TMP_DIR/bin"
  mkdir -p "$MOCK_DIR"
  PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

# mock_docker OUTPUT [EXIT] — `docker` that prints OUTPUT and exits with EXIT.
mock_docker() {
  cat >"$MOCK_DIR/docker" <<MOCKEOF
#!/bin/bash
echo "$1"
exit ${2:-0}
MOCKEOF
  chmod +x "$MOCK_DIR/docker"
}

# mock_nproc COUNT — `nproc` that prints COUNT.
mock_nproc() {
  cat >"$MOCK_DIR/nproc" <<MOCKEOF
#!/bin/bash
echo "$1"
MOCKEOF
  chmod +x "$MOCK_DIR/nproc"
}

# expect_pool RUNNERS CPUS MEMORY — stdout is exactly the three KEY=value lines.
expect_pool() {
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'RUNNERS=%s\nRUNNER_CPUS=%s\nRUNNER_MEMORY=%s' "$1" "$2" "$3")" ]
}

# ---------------------------------------------------------------------------
# Formula
# ---------------------------------------------------------------------------

@test "12 CPUs and 16 GiB give the 3 / 3 / 3G preset" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16
  expect_pool 3 3 3G
}

@test "1 CPU and 4 GiB give the 1 / 1 / 3G preset" {
  run --separate-stderr "$SIZING" --cpus 1 --memory 4
  expect_pool 1 1 3G
}

@test "2 CPUs and 8 GiB give one runner of 2 CPUs" {
  run --separate-stderr "$SIZING" --cpus 2 --memory 8
  expect_pool 1 2 3G
}

@test "8 CPUs and 8 GiB give two runners" {
  run --separate-stderr "$SIZING" --cpus 8 --memory 8
  expect_pool 2 3 3G
}

@test "16 CPUs and 32 GiB give four runners" {
  run --separate-stderr "$SIZING" --cpus 16 --memory 32
  expect_pool 4 3 3G
}

@test "summary on stderr shows inputs, reserve and pool" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16
  [ "$status" -eq 0 ]
  echo "$stderr" | grep -q "12 CPUs (--cpus), 16 GiB (--memory)"
  echo "$stderr" | grep -q "Host reserve: *3 CPUs, 4 GiB"
  echo "$stderr" | grep -q "3 x 3 CPUs / 3G = 9 CPUs, 9 GiB"
}

# ---------------------------------------------------------------------------
# Overrides
# ---------------------------------------------------------------------------

@test "--reserve-cpus 0 gives every CPU to the runners" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --reserve-cpus 0
  expect_pool 4 3 3G
}

@test "--reserve-memory keeps more memory for the host" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --reserve-memory 8
  expect_pool 2 3 3G
}

@test "--cpus-per-runner sets a smaller CPU target" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --cpus-per-runner 2
  expect_pool 4 2 3G
}

@test "--memory-per-runner sets a larger memory target" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --memory-per-runner 6
  expect_pool 2 3 6G
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

@test "1 CPU and 2 GiB is too small" {
  run --separate-stderr "$SIZING" --cpus 1 --memory 2
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "host too small"
}

@test "a reserve as large as the host is too small" {
  run --separate-stderr "$SIZING" --cpus 4 --memory 16 --reserve-cpus 4
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q "host too small"
}

@test "non-numeric --cpus is rejected" {
  run --separate-stderr "$SIZING" --cpus abc --memory 16
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q -- "--cpus expects a whole number"
}

@test "unknown memory unit is rejected" {
  run --separate-stderr "$SIZING" --cpus 4 --memory 16TB
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q -- "--memory expects whole GiB"
}

@test "--cpus 0 is rejected" {
  run --separate-stderr "$SIZING" --cpus 0 --memory 16
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q -- "--cpus must be at least 1"
}

@test "--memory-per-runner below 2 GiB is rejected" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --memory-per-runner 1
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q -- "--memory-per-runner must be at least 2"
}

@test "an option without its value is rejected" {
  run --separate-stderr "$SIZING" --memory 16 --cpus
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q -- "--cpus requires a value"
}

@test "an unknown option is rejected" {
  run --separate-stderr "$SIZING" --threads 4
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q "unknown option '--threads'"
}

@test "--help prints usage and exits 0" {
  run "$SIZING" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Usage: scripts/sizing.sh"
}

# ---------------------------------------------------------------------------
# Input parsing
# ---------------------------------------------------------------------------

@test "--memory accepts G, GB and GiB suffixes in any case" {
  for mem in 16G 16GB 16gb 16GiB; do
    run --separate-stderr "$SIZING" --cpus 12 --memory "$mem"
    expect_pool 3 3 3G
  done
}

@test "leading zeros are read as decimal" {
  run --separate-stderr "$SIZING" --cpus 08 --memory 08
  expect_pool 2 3 3G
}

# ---------------------------------------------------------------------------
# Auto-detection
# ---------------------------------------------------------------------------

@test "detects CPUs and memory from docker info" {
  mock_docker "12 17179869184"
  run --separate-stderr "$SIZING"
  expect_pool 3 3 3G
  echo "$stderr" | grep -q "12 CPUs (docker info), 16 GiB (docker info)"
}

@test "detected memory rounds up to 16 GiB on a 16 GB host" {
  mock_docker "12 16624349184"
  run --separate-stderr "$SIZING"
  expect_pool 3 3 3G
  echo "$stderr" | grep -q "16 GiB (docker info)"
}

@test "detected memory rounds up to 4 GiB on a 4 GB VPS" {
  mock_docker "1 4080218931"
  run --separate-stderr "$SIZING"
  expect_pool 1 1 3G
  echo "$stderr" | grep -q "4 GiB (docker info)"
}

@test "--cpus wins over the detected CPU count" {
  mock_docker "99 17179869184"
  run --separate-stderr "$SIZING" --cpus 12
  expect_pool 3 3 3G
  echo "$stderr" | grep -q "12 CPUs (--cpus), 16 GiB (docker info)"
}

@test "falls back to nproc when docker info fails" {
  mock_docker "Cannot connect to the Docker daemon" 1
  mock_nproc 12
  run --separate-stderr "$SIZING" --memory 16
  expect_pool 3 3 3G
  echo "$stderr" | grep -q "docker info is unavailable"
  echo "$stderr" | grep -q "12 CPUs (host)"
}

@test "falls back to the host memory when docker info fails" {
  mock_docker "" 1
  run --separate-stderr "$SIZING" --cpus 12
  [ "$status" -eq 0 ]
  echo "$stderr" | grep -q "GiB (host)"
  echo "$output" | grep -q "^RUNNER_MEMORY=[0-9][0-9]*G$"
}

# ---------------------------------------------------------------------------
# --write
# ---------------------------------------------------------------------------

@test "--write replaces existing keys and leaves other lines untouched" {
  cat >"$TMP_DIR/.env" <<'EOF'
# token
ACCESS_TOKEN=ghp_secret_value
ORG_NAME=acme
RUNNERS=9
RUNNER_CPUS=9
# capacity
RUNNER_MEMORY=9G
RUNNER_LABELS=self-hosted,linux,docker,test
EOF
  run --separate-stderr "$SIZING" --write "$TMP_DIR/.env" --cpus 12 --memory 16
  expect_pool 3 3 3G
  [ "$(cat "$TMP_DIR/.env")" = "$(cat <<'EOF'
# token
ACCESS_TOKEN=ghp_secret_value
ORG_NAME=acme
RUNNERS=3
RUNNER_CPUS=3
# capacity
RUNNER_MEMORY=3G
RUNNER_LABELS=self-hosted,linux,docker,test
EOF
)" ]
}

@test "--write appends missing keys after a last line without newline" {
  printf 'ACCESS_TOKEN=ghp_secret_value\nORG_NAME=acme\nRUNNERS=9' >"$TMP_DIR/.env"
  run --separate-stderr "$SIZING" --cpus 1 --memory 4 --write "$TMP_DIR/.env"
  expect_pool 1 1 3G
  [ "$(cat "$TMP_DIR/.env")" = "$(printf 'ACCESS_TOKEN=ghp_secret_value\nORG_NAME=acme\nRUNNERS=1\nRUNNER_CPUS=1\nRUNNER_MEMORY=3G')" ]
}

@test "--write never prints the access token" {
  printf 'ACCESS_TOKEN=ghp_secret_value\nORG_NAME=acme\n' >"$TMP_DIR/.env"
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --write "$TMP_DIR/.env"
  [ "$status" -eq 0 ]
  [ "$(echo "$output$stderr" | grep -c "ghp_secret_value")" -eq 0 ]
}

@test "--write without FILE updates the .env next to docker-compose.yml" {
  mkdir -p "$TMP_DIR/repo/scripts" "$TMP_DIR/elsewhere"
  cp "$SIZING" "$TMP_DIR/repo/scripts/sizing.sh"
  printf 'ORG_NAME=acme\n' >"$TMP_DIR/repo/.env"
  cd "$TMP_DIR/elsewhere" || return
  run --separate-stderr "$TMP_DIR/repo/scripts/sizing.sh" --cpus 12 --memory 16 --write
  expect_pool 3 3 3G
  grep -q "^RUNNERS=3$" "$TMP_DIR/repo/.env"
  [ ! -e "$TMP_DIR/elsewhere/.env" ]
}

@test "--write to a missing file fails and creates nothing" {
  run --separate-stderr "$SIZING" --cpus 12 --memory 16 --write "$TMP_DIR/missing.env"
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q "cp .env.example .env"
  [ -z "$(find "$TMP_DIR" -name 'missing.env*')" ]
}
