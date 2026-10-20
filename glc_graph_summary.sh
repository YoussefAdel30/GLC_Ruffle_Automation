#!/bin/bash
#
# glc_graph_summary.sh
#
# Run one GLC request.json and print a short text census of the graph:
# node-type counts, per-link breakdowns, and among-input direct/common
# relations (VoiceCall, shared device/user, Line Status values, etc.).
#
# Stdlib Python 3 only. No venv and no pip packages.
#
# Usage:
#   chmod 775 glc_graph_summary.sh glc_graph_summary.py glc_auto.sh
#   ./glc_graph_summary.sh -i request.json
#   ./glc_graph_summary.sh -i request.json -o summary.txt
#   ./glc_graph_summary.sh --response saved_response.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_PY="${SCRIPT_DIR}/glc_graph_summary.py"
DEFAULT_GLC_AUTO="${SCRIPT_DIR}/glc_auto.sh"

INPUT_FILE=""
OUTPUT_FILE=""
RESPONSE_FILE=""
RUN_DIR=""
DATE_FROM=""
DATE_TO=""
TOP_N=8
GLC_AUTO="${GLC_AUTO:-$DEFAULT_GLC_AUTO}"
GLC_RETRIES=3
GLC_RETRY_SLEEP=2

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Take one GLC request JSON, call glc_auto.sh, and print a short graph summary.

Options:
  -i, --input FILE        GLC request JSON (required unless --response is set)
  -o, --output FILE       Write the summary text to FILE (also printed)
  -d, --run-dir DIR       Directory for log and raw response
      --response FILE     Skip the GLC call and summarize this saved response
      --date-from DATE    Override request dateFrom (YYYY/MM/DD HH:MM:SS)
      --date-to DATE      Override request dateTo
      --top-n N           Max rows in top lists (default: ${TOP_N})
      --glc-auto PATH     Path to glc_auto.sh
      --retries N         GLC call retries (default: ${GLC_RETRIES})
  -h, --help              Show this help

Examples:
  $(basename "$0") -i request.json -o summary.txt
  $(basename "$0") -i request.json --date-from '2026/07/15 00:00:00' --date-to '2026/09/01 23:59:59'
  $(basename "$0") --response runs/last/response.json -i request.json
EOF
}

log() {
  local level="$1"
  shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
  echo "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
fail() { log ERROR "$*"; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--input) INPUT_FILE="$2"; shift 2 ;;
      -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
      -d|--run-dir) RUN_DIR="$2"; shift 2 ;;
      --response) RESPONSE_FILE="$2"; shift 2 ;;
      --date-from) DATE_FROM="$2"; shift 2 ;;
      --date-to) DATE_TO="$2"; shift 2 ;;
      --top-n) TOP_N="$2"; shift 2 ;;
      --glc-auto) GLC_AUTO="$2"; shift 2 ;;
      --retries) GLC_RETRIES="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        if [[ -z "$INPUT_FILE" ]]; then
          INPUT_FILE="$1"
          shift
        else
          fail "unexpected argument: $1"
        fi
        ;;
    esac
  done
}

write_request() {
  local src="$1"
  local dest="$2"
  python3 - "$src" "$dest" "${DATE_FROM:-}" "${DATE_TO:-}" <<'PY'
import json
import sys
src, dest, date_from, date_to = sys.argv[1:5]
req = json.load(open(src))
if date_from:
    req["dateFrom"] = date_from
if date_to:
    req["dateTo"] = date_to
with open(dest, "w") as fh:
    json.dump(req, fh, indent=2)
    fh.write("\n")
PY
}

call_glc() {
  local request_file="$1"
  local response_file="$2"
  local attempt=1
  local stderr_file="${response_file}.stderr"
  while [[ "$attempt" -le "$GLC_RETRIES" ]]; do
    log_info "GLC call attempt ${attempt}/${GLC_RETRIES} request=${request_file}"
    set +e
    "$GLC_AUTO" "$request_file" > "$response_file" 2> "$stderr_file"
    local rc=$?
    set -e
    if [[ -s "$stderr_file" ]]; then
      log_info "glc_auto stderr: $(tr '\n' ' ' < "$stderr_file" | cut -c1-400)"
    fi
    if [[ "$rc" -ne 0 ]]; then
      log_warn "glc_auto exited ${rc}"
    elif python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$response_file" 2>/dev/null; then
      log_info "GLC response saved: ${response_file}"
      return 0
    else
      local preview
      preview="$(head -c 240 "$response_file" 2>/dev/null | tr '\n' ' ')"
      log_warn "response is not valid JSON. preview=${preview}"
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -le "$GLC_RETRIES" ]]; then
      sleep "$GLC_RETRY_SLEEP"
    fi
  done
  fail "GLC call failed after ${GLC_RETRIES} attempts"
}

main() {
  parse_args "$@"
  [[ -f "$SUMMARY_PY" ]] || fail "missing ${SUMMARY_PY}"

  if [[ -z "$RUN_DIR" ]]; then
    RUN_DIR="${SCRIPT_DIR}/runs/summary_$(date '+%Y%m%d_%H%M%S')"
  fi
  mkdir -p "$RUN_DIR"
  LOG_FILE="${RUN_DIR}/summary.log"

  local used_request="${RUN_DIR}/request.json"
  local used_response="${RUN_DIR}/response.json"
  local used_summary="${RUN_DIR}/summary.txt"

  log_info "=============================================================="
  log_info "GLC graph summary starting"
  log_info "run_dir=${RUN_DIR}"

  if [[ -n "$RESPONSE_FILE" ]]; then
    [[ -f "$RESPONSE_FILE" ]] || fail "response file not found: $RESPONSE_FILE"
    cp "$RESPONSE_FILE" "$used_response"
    if [[ -n "$INPUT_FILE" ]]; then
      [[ -f "$INPUT_FILE" ]] || fail "request file not found: $INPUT_FILE"
      write_request "$INPUT_FILE" "$used_request"
    else
      echo '{}' > "$used_request"
      log_info "No request JSON; summary will use response roots as inputs"
    fi
  else
    [[ -n "$INPUT_FILE" ]] || fail "request JSON is required (-i). See --help"
    [[ -f "$INPUT_FILE" ]] || fail "request file not found: $INPUT_FILE"
    [[ -x "$GLC_AUTO" || -f "$GLC_AUTO" ]] || fail "glc_auto.sh not found: $GLC_AUTO"
    write_request "$INPUT_FILE" "$used_request"
    call_glc "$used_request" "$used_response"
  fi

  local extra=()
  [[ -n "$DATE_FROM" ]] && extra+=(--date-from "$DATE_FROM")
  [[ -n "$DATE_TO" ]] && extra+=(--date-to "$DATE_TO")

  python3 "$SUMMARY_PY" summarize \
    --request "$used_request" \
    --response "$used_response" \
    --out "$used_summary" \
    --top-n "$TOP_N" \
    "${extra[@]}"

  if [[ -n "$OUTPUT_FILE" ]]; then
    cp "$used_summary" "$OUTPUT_FILE"
    log_info "Wrote summary to ${OUTPUT_FILE}"
  fi
  log_info "summary: ${used_summary}"
  log_info "response: ${used_response}"
  log_info "=============================================================="
  cat "$used_summary"
}

main "$@"
