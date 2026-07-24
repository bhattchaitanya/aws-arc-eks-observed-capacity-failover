#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${LAB_ROOT}/config.env"
STATE_DIR="${LAB_ROOT}/.state"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  cp "${LAB_ROOT}/config.env.example" "${CONFIG_FILE}"
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
mkdir -p "${STATE_DIR}"

export AWS_PAGER=""

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

assert_account() {
  local actual_account
  actual_account="$(aws sts get-caller-identity --query Account --output text)"
  if [[ "${actual_account}" != "${ACCOUNT_ID}" ]]; then
    echo "Refusing to continue: expected account ${ACCOUNT_ID}, got ${actual_account}" >&2
    exit 1
  fi
}

cluster_context() {
  case "$1" in
    "${PRIMARY_REGION}") echo "arc-west" ;;
    "${STANDBY_REGION}") echo "arc-east" ;;
    *) echo "Unknown region: $1" >&2; return 1 ;;
  esac
}

cluster_name() {
  case "$1" in
    "${PRIMARY_REGION}") echo "${PRIMARY_CLUSTER}" ;;
    "${STANDBY_REGION}") echo "${STANDBY_CLUSTER}" ;;
    *) echo "Unknown region: $1" >&2; return 1 ;;
  esac
}

wait_for_command() {
  local attempts="$1"
  local interval="$2"
  shift 2
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    fi
    sleep "${interval}"
  done
  return 1
}
