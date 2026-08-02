#!/usr/bin/env bash
set -euo pipefail

readonly package_path="${PACKAGE_PATH:?PACKAGE_PATH is required}"
readonly package_receipt="${PACKAGE_RECEIPT:?PACKAGE_RECEIPT is required}"
readonly run_poll_tick="${RUN_POLL_TICK:-false}"
readonly strict="${STRICT:-false}"
readonly test_jobs="${TEST_JOBS:-0}"

args=(package verify "$package_path" --json --receipt-out "$package_receipt")

case "$run_poll_tick" in
  true) args+=(--run-poll-tick) ;;
  false) ;;
  *)
    echo "::error::run-poll-tick must be 'true' or 'false'" >&2
    exit 2
    ;;
esac

case "$strict" in
  true) args+=(--strict) ;;
  false) ;;
  *)
    echo "::error::strict must be 'true' or 'false'" >&2
    exit 2
    ;;
esac

if [[ "$test_jobs" != "0" ]]; then
  if [[ ! "$test_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::test-jobs must be zero or a positive integer" >&2
    exit 2
  fi
  export HARN_TEST_JOBS="$test_jobs"
fi

harn "${args[@]}"
