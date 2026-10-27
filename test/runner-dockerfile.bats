#!/usr/bin/env bats

# runner-dockerfile.bats — Tests for runner.Dockerfile: the Node tarball download
# and the runner start command.
#
# The base image (myoung34/github-runner, Ubuntu 20.04) ships curl 7.68, so the
# download must bound a stalled transfer and retry with options that curl has.

setup() {
  # Repo root (one level up from test/)
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  DOCKERFILE="$ROOT/runner.Dockerfile"
}

# node_curl — the Node tarball curl command, `\` continuations joined.
node_curl() {
  awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' "$DOCKERFILE" \
    | grep -o 'curl [^&]*node-v[^&]*'
}

@test "Node download is a single curl command" {
  run node_curl
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "Node download times out a slow connect and a stalled transfer" {
  run node_curl
  echo "$output" | grep -q -- "--connect-timeout [0-9]"
  echo "$output" | grep -q -- "--speed-limit [0-9].* --speed-time [0-9]"
  echo "$output" | grep -q -- "--max-time [0-9]"
}

@test "Node download retries transient failures" {
  run node_curl
  echo "$output" | grep -q -- "--retry [0-9]"
  echo "$output" | grep -q -- "--retry-delay [0-9]"
  echo "$output" | grep -q -- "--retry-connrefused"
}

@test "Node download avoids --retry-all-errors (curl 7.71+, base image has 7.68)" {
  run grep -c -- "--retry-all-errors" "$DOCKERFILE"
  [ "$output" -eq 0 ]
}

@test "Node download is still checked against its SHA-256" {
  run grep -c 'sha256sum -c -' "$DOCKERFILE"
  [ "$output" -eq 1 ]
}

@test "Runner starts through run.sh so self-updates finish in place" {
  run grep -cx 'CMD \["./run.sh", "--startuptype", "service"\]' "$DOCKERFILE"
  [ "$output" -eq 1 ]
}
