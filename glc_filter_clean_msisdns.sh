#!/bin/bash
#
# glc_filter_clean_msisdns.sh
#
# Filter a list of MSISDNs through sequential GLC relation checks and print
# the remaining (clean) MSISDNs.
#
# Usage:
#   chmod 775 glc_filter_clean_msisdns.sh
#   ./glc_filter_clean_msisdns.sh -i msisdns.txt
#   ./glc_filter_clean_msisdns.sh -i msisdns.txt -o clean.txt --date-from "2026/08/01 00:00:00" --date-to "2026/08/31 23:59:59"
#
# Input file format: one MSISDN per line. Blank lines and # comments are ignored.
#
# Pipeline
#   Step 1 (filter group 1)
#     1) msisdn_user          exclude MSISDNs that have a User
#     2) msisdn_wallet_profile exclude wallet_profile = Credit Only Consumer
#     3) msisdn_wallet_status  exclude wallet_status = Suspended or Barred
#     4) msisdn_line_status    exclude line_status = Suspended or Barred
#                              (override with --line-status-exclude; empty = log only)
#   Step 2 (filter group 2)
#     5) msisdn_device then device_msisdn
#        working set becomes original MSISDNs that had no device
#        UNION all MSISDNs found on those devices
#     6) msisdn_id then id_user
#        exclude MSISDNs whose ID is linked to a User
#   Step 3 (filter group 3)
#     7) user_sub and sub_user (batched, default 30)
#        exclude any input MSISDN that has any relation
#
# Logs every GLC call, mapping, exclusion reason, and remaining count.
# Raw responses are stored under the run directory for debugging.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_PY="${SCRIPT_DIR}/glc_graph_parse.py"
DEFAULT_GLC_AUTO="${SCRIPT_DIR}/glc_auto.sh"
DEFAULT_REQUEST_TYPES="${SCRIPT_DIR}/request_types"

MSISDN_TYPE=1
USER_TYPE=1001
DEVICE_TYPE=1000
ID_TYPE=1003
WALLET_PROFILE_TYPE=1321
WALLET_STATUS_TYPE=1141
LINE_STATUS_TYPE=1160

INPUT_FILE=""
OUTPUT_FILE=""
RUN_DIR=""
DATE_FROM=""
DATE_TO=""
BATCH_SIZE=50
SLOW_BATCH_SIZE=30
GLC_AUTO="${GLC_AUTO:-$DEFAULT_GLC_AUTO}"
REQUEST_TYPES="${REQUEST_TYPES:-$DEFAULT_REQUEST_TYPES}"
WALLET_PROFILE_EXCLUDE="Credit Only Consumer"
WALLET_STATUS_EXCLUDE="Suspended,Barred"
LINE_STATUS_EXCLUDE="Suspended,Barred"
GLC_RETRIES=3
GLC_RETRY_SLEEP=2

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [MSISDN_FILE]

Filter MSISDNs through GLC relation checks. Remaining clean MSISDNs are
printed to stdout and written to the run directory.

Options:
  -i, --input FILE             MSISDN list (one per line). Use - for stdin.
  -o, --output FILE            Also write clean MSISDNs to FILE
  -d, --run-dir DIR            Directory for logs and raw GLC responses
      --date-from DATE         Override dateFrom in every GLC request
      --date-to DATE           Override dateTo in every GLC request
      --batch-size N           Batch size for normal GLC calls (default: ${BATCH_SIZE})
      --slow-batch-size N      Batch size for user_sub/sub_user (default: ${SLOW_BATCH_SIZE})
      --glc-auto PATH          Path to glc_auto.sh
      --request-types DIR      Path to request_types directory
      --wallet-profile-exclude LIST
                               Comma-separated wallet profiles to exclude
                               (default: ${WALLET_PROFILE_EXCLUDE})
      --wallet-status-exclude LIST
                               Comma-separated wallet statuses to exclude
                               (default: ${WALLET_STATUS_EXCLUDE})
      --line-status-exclude LIST
                               Comma-separated line statuses to exclude
                               (default: ${LINE_STATUS_EXCLUDE}; empty = log only)
      --retries N              GLC call retries on invalid JSON (default: ${GLC_RETRIES})
  -h, --help                   Show this help

Examples:
  $(basename "$0") -i msisdns.txt
  $(basename "$0") -i msisdns.txt -o clean.txt --slow-batch-size 30
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

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

fail() {
  log_error "$@"
  exit 1
}

count_lines() {
  local f="$1"
  if [[ ! -s "$f" ]]; then
    echo 0
  else
    wc -l < "$f" | tr -d ' '
  fi
}

preview_list() {
  local f="$1"
  local n
  n="$(count_lines "$f")"
  if [[ "$n" -eq 0 ]]; then
    echo "(none)"
    return
  fi
  if [[ "$n" -le 15 ]]; then
    tr '\n' ',' < "$f" | sed 's/,$//'
  else
    local head_items
    head_items="$(head -n 8 "$f" | tr '\n' ',' | sed 's/,$//')"
    echo "${head_items},... (${n} total)"
  fi
}

ensure_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    : > "$f"
  fi
}

python_parse() {
  python3 "$PARSE_PY" "$@"
}

load_msisdns() {
  local src="$1"
  local dest="$2"
  if [[ "$src" == "-" ]]; then
    python_parse unique --nodes-file - --out "$dest"
  else
    [[ -f "$src" ]] || fail "input file not found: $src"
    python_parse unique --nodes-file "$src" --out "$dest"
  fi
}

record_exclusion() {
  local msisdn="$1"
  local step="$2"
  local reason="$3"
  local detail="${4:-}"
  printf '%s|%s|%s|%s\n' "$msisdn" "$step" "$reason" "$detail" >> "$EXCLUDED_FILE"
  log_info "EXCLUDE ${msisdn}  step=${step}  reason=${reason}  detail=${detail}"
}

apply_exclusions() {
  local current="$1"
  local exclude_list="$2"
  local dest="$3"
  python3 - "$current" "$exclude_list" "$dest" <<'PY'
import sys
current_path, exclude_path, dest_path = sys.argv[1:4]
def read_items(path):
    items = []
    try:
        with open(path) as fh:
            for line in fh:
                item = line.strip()
                if item:
                    items.append(item)
    except IOError:
        pass
    return items
exclude = set(read_items(exclude_path))
kept = [item for item in read_items(current_path) if item not in exclude]
with open(dest_path, "w") as fh:
    if kept:
        fh.write("\n".join(kept) + "\n")
PY
}

merge_unique() {
  local dest="$1"
  shift
  python3 - "$dest" "$@" <<'PY'
import sys
dest = sys.argv[1]
seen = set()
out = []
for path in sys.argv[2:]:
    try:
        fh = open(path)
    except IOError:
        continue
    with fh:
        for line in fh:
            item = line.strip()
            if item and item not in seen:
                seen.add(item)
                out.append(item)
with open(dest, "w") as fh:
    if out:
        fh.write("\n".join(out) + "\n")
PY
}

subtract_list() {
  local current="$1"
  local remove="$2"
  local dest="$3"
  apply_exclusions "$current" "$remove" "$dest"
}

build_request_file() {
  local template="$1"
  local nodes_file="$2"
  local out="$3"
  local extra=()
  if [[ -n "$DATE_FROM" ]]; then
    extra+=(--date-from "$DATE_FROM")
  fi
  if [[ -n "$DATE_TO" ]]; then
    extra+=(--date-to "$DATE_TO")
  fi
  python_parse build-request \
    --template "$template" \
    --nodes-file "$nodes_file" \
    --out "$out" \
    "${extra[@]}"
}

call_glc() {
  local request_file="$1"
  local response_file="$2"
  local label="$3"
  local attempt=1
  local stderr_file="${response_file}.stderr"

  while [[ "$attempt" -le "$GLC_RETRIES" ]]; do
    log_info "GLC call [${label}] attempt ${attempt}/${GLC_RETRIES} request=${request_file}"
    set +e
    "$GLC_AUTO" "$request_file" > "$response_file" 2> "$stderr_file"
    local rc=$?
    set -e
    if [[ -s "$stderr_file" ]]; then
      log_debug "glc_auto stderr (${label}): $(tr '\n' ' ' < "$stderr_file" | cut -c1-400)"
    fi
    if [[ "$rc" -ne 0 ]]; then
      log_warn "glc_auto exited ${rc} for ${label}"
    elif python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$response_file" 2>/dev/null; then
      local summary
      summary="$(python_parse summary --response "$response_file")"
      log_info "GLC response [${label}] ${summary}"
      return 0
    else
      local preview
      preview="$(head -c 240 "$response_file" 2>/dev/null | tr '\n' ' ')"
      log_warn "GLC response [${label}] is not valid JSON. preview=${preview}"
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -le "$GLC_RETRIES" ]]; then
      sleep "$GLC_RETRY_SLEEP"
    fi
  done
  fail "GLC call failed after ${GLC_RETRIES} attempts: ${label}"
}

split_batches() {
  local src="$1"
  local dest_dir="$2"
  local size="$3"
  mkdir -p "$dest_dir"
  rm -f "$dest_dir"/batch_*
  if [[ ! -s "$src" ]]; then
    return 0
  fi
  python3 - "$src" "$dest_dir" "$size" <<'PY'
import os
import sys

src, dest, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = []
with open(src) as fh:
    for line in fh:
        item = line.strip()
        if item:
            lines.append(item)
if not lines:
    sys.exit(0)
batch = 0
for i in range(0, len(lines), size):
    batch += 1
    path = os.path.join(dest, "batch_%03d" % batch)
    chunk = lines[i:i + size]
    with open(path, "w") as fh:
        fh.write("\n".join(chunk) + "\n")
PY
}

run_batched_glc() {
  local template_name="$1"
  local nodes_file="$2"
  local batch_size="$3"
  local step_tag="$4"
  local combined_response="$5"

  local template="${REQUEST_TYPES}/${template_name}"
  [[ -f "$template" ]] || fail "missing request template: $template"

  local n
  n="$(count_lines "$nodes_file")"
  if [[ "$n" -eq 0 ]]; then
    log_info "Skipping ${step_tag}: no input nodes"
    echo '{"vertices":[],"edges":[],"responseCode":0}' > "$combined_response"
    return 0
  fi

  local batch_dir="${RESP_DIR}/${step_tag}_batches"
  split_batches "$nodes_file" "$batch_dir" "$batch_size"
  local batch_files=()
  local f
  local old_nullglob
  old_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  for f in "$batch_dir"/batch_*; do
    batch_files+=("$f")
  done
  eval "$old_nullglob"

  if [[ "${#batch_files[@]}" -eq 0 ]]; then
    log_warn "No batches created for ${step_tag}; treating as empty response"
    echo '{"vertices":[],"edges":[],"responseCode":0}' > "$combined_response"
    return 0
  fi

  log_info "Running ${step_tag} using ${template_name} on ${n} node(s) in ${#batch_files[@]} batch(es) of up to ${batch_size}"
  log_debug "${step_tag} nodes: $(preview_list "$nodes_file")"

  local responses=()
  local i=0
  for f in "${batch_files[@]}"; do
    i=$((i + 1))
    local req="${RESP_DIR}/${step_tag}_batch$(printf '%03d' "$i").request.json"
    local resp="${RESP_DIR}/${step_tag}_batch$(printf '%03d' "$i").response.json"
    build_request_file "$template" "$f" "$req"
    log_debug "${step_tag} batch ${i} size=$(count_lines "$f") request=${req}"
    call_glc "$req" "$resp" "${step_tag}/batch${i}"
    responses+=("$resp")
  done

  python3 - "$combined_response" "${responses[@]}" <<'PY'
import json, sys
out_path = sys.argv[1]
merged = {
    "vertices": [],
    "edges": [],
    "rootNodes": [],
    "responseCode": 0,
    "warningMsg": None,
}
seen_v = set()
seen_e = set()
codes = []
warnings = []
for path in sys.argv[2:]:
    with open(path) as fh:
        data = json.load(fh)
    codes.append(data.get("responseCode"))
    if data.get("warningMsg"):
        warnings.append(str(data.get("warningMsg")))
    for v in data.get("vertices") or []:
        key = v.get("id") or v.get("nodeId") or json.dumps(v, sort_keys=True)
        if key in seen_v:
            continue
        seen_v.add(key)
        merged["vertices"].append(v)
    for e in data.get("edges") or []:
        key = e.get("id") or e.get("linkID") or e.get("linkKey") or json.dumps(e, sort_keys=True)
        if key in seen_e:
            continue
        seen_e.add(key)
        merged["edges"].append(e)
    for r in data.get("rootNodes") or []:
        merged["rootNodes"].append(r)
if any(c not in (0, None) for c in codes):
    merged["responseCode"] = next(c for c in codes if c not in (0, None))
if warnings:
    merged["warningMsg"] = " | ".join(warnings)
with open(out_path, "w") as fh:
    json.dump(merged, fh)
    fh.write("\n")
PY
  log_info "Merged ${step_tag} response: $(python_parse summary --response "$combined_response")"
}

dump_related() {
  local response="$1"
  local from_type="$2"
  local to_type="$3"
  local candidates="$4"
  python_parse related-dump \
    --response "$response" \
    --from-type "$from_type" \
    --to-type "$to_type" \
    --candidates "$candidates"
}

finish_step() {
  local step_name="$1"
  local remaining="$2"
  log_info "----- ${step_name} remaining=$(count_lines "$remaining") : $(preview_list "$remaining")"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--input) INPUT_FILE="$2"; shift 2 ;;
      -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
      -d|--run-dir) RUN_DIR="$2"; shift 2 ;;
      --date-from) DATE_FROM="$2"; shift 2 ;;
      --date-to) DATE_TO="$2"; shift 2 ;;
      --batch-size) BATCH_SIZE="$2"; shift 2 ;;
      --slow-batch-size) SLOW_BATCH_SIZE="$2"; shift 2 ;;
      --glc-auto) GLC_AUTO="$2"; shift 2 ;;
      --request-types) REQUEST_TYPES="$2"; shift 2 ;;
      --wallet-profile-exclude) WALLET_PROFILE_EXCLUDE="$2"; shift 2 ;;
      --wallet-status-exclude) WALLET_STATUS_EXCLUDE="$2"; shift 2 ;;
      --line-status-exclude) LINE_STATUS_EXCLUDE="$2"; shift 2 ;;
      --retries) GLC_RETRIES="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) fail "unknown option: $1" ;;
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

main() {
  parse_args "$@"

  [[ -n "$INPUT_FILE" ]] || fail "input MSISDN file is required (see --help)"
  [[ -f "$PARSE_PY" ]] || fail "missing parser helper: $PARSE_PY"
  [[ -x "$GLC_AUTO" || -f "$GLC_AUTO" ]] || fail "glc_auto.sh not found: $GLC_AUTO"
  [[ -d "$REQUEST_TYPES" ]] || fail "request_types directory not found: $REQUEST_TYPES"

  if [[ -z "$RUN_DIR" ]]; then
    RUN_DIR="${SCRIPT_DIR}/runs/$(date '+%Y%m%d_%H%M%S')"
  fi
  mkdir -p "$RUN_DIR"
  RESP_DIR="${RUN_DIR}/responses"
  mkdir -p "$RESP_DIR"

  LOG_FILE="${RUN_DIR}/filter.log"
  EXCLUDED_FILE="${RUN_DIR}/excluded.txt"
  REMAINING="${RUN_DIR}/remaining.txt"
  CURRENT="${RUN_DIR}/current_msisdns.txt"
  CLEAN_FILE="${RUN_DIR}/clean_msisdns.txt"
  : > "$EXCLUDED_FILE"
  echo "msisdn|step|reason|detail" > "$EXCLUDED_FILE"

  log_info "=============================================================="
  log_info "GLC clean-MSISDN filter starting"
  log_info "run_dir=${RUN_DIR}"
  log_info "glc_auto=${GLC_AUTO}"
  log_info "request_types=${REQUEST_TYPES}"
  log_info "batch_size=${BATCH_SIZE} slow_batch_size=${SLOW_BATCH_SIZE}"
  log_info "date_from=${DATE_FROM:-'(from templates)'} date_to=${DATE_TO:-'(from templates)'}"
  log_info "wallet_profile_exclude=${WALLET_PROFILE_EXCLUDE}"
  log_info "wallet_status_exclude=${WALLET_STATUS_EXCLUDE}"
  log_info "line_status_exclude=${LINE_STATUS_EXCLUDE:-'(log only, no exclude)'}"
  log_info "=============================================================="

  load_msisdns "$INPUT_FILE" "$CURRENT"
  cp "$CURRENT" "${RUN_DIR}/input_msisdns.txt"
  log_info "Loaded $(count_lines "$CURRENT") unique MSISDN(s) from ${INPUT_FILE}: $(preview_list "$CURRENT")"
  [[ "$(count_lines "$CURRENT")" -gt 0 ]] || fail "no MSISDNs found in input"

  # ------------------------------------------------------------------
  # STEP 1: msisdn_user  (exclude if a User is linked)
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 1 / STEP 1: msisdn_user =========="
  local resp1="${RESP_DIR}/step1_msisdn_user.json"
  run_batched_glc "msisdn_user.json" "$CURRENT" "$BATCH_SIZE" "step1_msisdn_user" "$resp1"
  dump_related "$resp1" "$MSISDN_TYPE" "$USER_TYPE" "$CURRENT" > "${RUN_DIR}/step1_msisdn_user_map.txt"
  while IFS='|' read -r msisdn users || [[ -n "${msisdn:-}" ]]; do
    [[ -n "$msisdn" ]] || continue
    log_debug "step1 mapping ${msisdn} -> users=[${users}]"
  done < "${RUN_DIR}/step1_msisdn_user_map.txt"

  local excl1="${RUN_DIR}/step1_exclude.txt"
  : > "$excl1"
  python_parse exclude-if-related \
    --response "$resp1" \
    --from-type "$MSISDN_TYPE" \
    --to-type "$USER_TYPE" \
    --candidates "$CURRENT" > "${RUN_DIR}/step1_exclude.raw"
  while IFS='|' read -r msisdn users || [[ -n "${msisdn:-}" ]]; do
    [[ -n "$msisdn" ]] || continue
    echo "$msisdn" >> "$excl1"
    record_exclusion "$msisdn" "1-msisdn_user" "has_user" "$users"
  done < "${RUN_DIR}/step1_exclude.raw"
  apply_exclusions "$CURRENT" "$excl1" "$REMAINING"
  cp "$REMAINING" "$CURRENT"
  finish_step "STEP 1 msisdn_user" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 2: msisdn_wallet_profile
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 1 / STEP 2: msisdn_wallet_profile =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 1; skipping remaining steps"
  else
    local resp2="${RESP_DIR}/step2_msisdn_wallet_profile.json"
    run_batched_glc "msisdn_wallet_profile.json" "$CURRENT" "$BATCH_SIZE" "step2_wallet_profile" "$resp2"
    dump_related "$resp2" "$MSISDN_TYPE" "$WALLET_PROFILE_TYPE" "$CURRENT" > "${RUN_DIR}/step2_wallet_profile_map.txt"
    while IFS='|' read -r msisdn profiles || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      log_debug "step2 mapping ${msisdn} -> wallet_profile=[${profiles:-none}]"
    done < "${RUN_DIR}/step2_wallet_profile_map.txt"

    local excl2="${RUN_DIR}/step2_exclude.txt"
    : > "$excl2"
    python_parse exclude-if-value \
      --response "$resp2" \
      --from-type "$MSISDN_TYPE" \
      --to-type "$WALLET_PROFILE_TYPE" \
      --match-values "$WALLET_PROFILE_EXCLUDE" \
      --candidates "$CURRENT" > "${RUN_DIR}/step2_exclude.raw"
    while IFS='|' read -r msisdn matched allv || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      echo "$msisdn" >> "$excl2"
      record_exclusion "$msisdn" "2-wallet_profile" "wallet_profile" "matched=${matched};all=${allv}"
    done < "${RUN_DIR}/step2_exclude.raw"
    apply_exclusions "$CURRENT" "$excl2" "$REMAINING"
    cp "$REMAINING" "$CURRENT"
  fi
  finish_step "STEP 2 msisdn_wallet_profile" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 3: msisdn_wallet_status
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 1 / STEP 3: msisdn_wallet_status =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 2; skipping remaining steps"
  else
    local resp3="${RESP_DIR}/step3_msisdn_wallet_status.json"
    run_batched_glc "msisdn_wallet_status.json" "$CURRENT" "$BATCH_SIZE" "step3_wallet_status" "$resp3"
    dump_related "$resp3" "$MSISDN_TYPE" "$WALLET_STATUS_TYPE" "$CURRENT" > "${RUN_DIR}/step3_wallet_status_map.txt"
    while IFS='|' read -r msisdn statuses || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      log_debug "step3 mapping ${msisdn} -> wallet_status=[${statuses:-none}]"
    done < "${RUN_DIR}/step3_wallet_status_map.txt"

    local excl3="${RUN_DIR}/step3_exclude.txt"
    : > "$excl3"
    python_parse exclude-if-value \
      --response "$resp3" \
      --from-type "$MSISDN_TYPE" \
      --to-type "$WALLET_STATUS_TYPE" \
      --match-values "$WALLET_STATUS_EXCLUDE" \
      --candidates "$CURRENT" > "${RUN_DIR}/step3_exclude.raw"
    while IFS='|' read -r msisdn matched allv || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      echo "$msisdn" >> "$excl3"
      record_exclusion "$msisdn" "3-wallet_status" "wallet_status" "matched=${matched};all=${allv}"
    done < "${RUN_DIR}/step3_exclude.raw"
    apply_exclusions "$CURRENT" "$excl3" "$REMAINING"
    cp "$REMAINING" "$CURRENT"
  fi
  finish_step "STEP 3 msisdn_wallet_status" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 4: msisdn_line_status
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 1 / STEP 4: msisdn_line_status =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 3; skipping remaining steps"
  else
    local resp4="${RESP_DIR}/step4_msisdn_line_status.json"
    run_batched_glc "msisdn_line_status.json" "$CURRENT" "$BATCH_SIZE" "step4_line_status" "$resp4"
    dump_related "$resp4" "$MSISDN_TYPE" "$LINE_STATUS_TYPE" "$CURRENT" > "${RUN_DIR}/step4_line_status_map.txt"
    while IFS='|' read -r msisdn statuses || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      log_debug "step4 mapping ${msisdn} -> line_status=[${statuses:-none}]"
    done < "${RUN_DIR}/step4_line_status_map.txt"

    local excl4="${RUN_DIR}/step4_exclude.txt"
    : > "$excl4"
    if [[ -n "$LINE_STATUS_EXCLUDE" ]]; then
      python_parse exclude-if-value \
        --response "$resp4" \
        --from-type "$MSISDN_TYPE" \
        --to-type "$LINE_STATUS_TYPE" \
        --match-values "$LINE_STATUS_EXCLUDE" \
        --candidates "$CURRENT" > "${RUN_DIR}/step4_exclude.raw"
      while IFS='|' read -r msisdn matched allv || [[ -n "${msisdn:-}" ]]; do
        [[ -n "$msisdn" ]] || continue
        echo "$msisdn" >> "$excl4"
        record_exclusion "$msisdn" "4-line_status" "line_status" "matched=${matched};all=${allv}"
      done < "${RUN_DIR}/step4_exclude.raw"
    else
      log_info "line-status exclude list is empty; logging statuses only (no exclusions)"
    fi
    apply_exclusions "$CURRENT" "$excl4" "$REMAINING"
    cp "$REMAINING" "$CURRENT"
  fi
  finish_step "STEP 4 msisdn_line_status" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 5: msisdn_device -> device_msisdn (expand working set)
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 2 / STEP 5: msisdn_device + device_msisdn =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 4; skipping remaining steps"
  else
    local resp5a="${RESP_DIR}/step5a_msisdn_device.json"
    run_batched_glc "msisdn_device.json" "$CURRENT" "$BATCH_SIZE" "step5a_msisdn_device" "$resp5a"
    dump_related "$resp5a" "$MSISDN_TYPE" "$DEVICE_TYPE" "$CURRENT" > "${RUN_DIR}/step5a_msisdn_device_map.txt"
    while IFS='|' read -r msisdn devices || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      log_debug "step5a mapping ${msisdn} -> devices=[${devices:-none}]"
    done < "${RUN_DIR}/step5a_msisdn_device_map.txt"

    python_parse relations \
      --response "$resp5a" \
      --from-type "$MSISDN_TYPE" \
      --to-type "$DEVICE_TYPE" \
      --candidates "$CURRENT" | awk -F'|' 'NF>=2{print $2}' | python_parse unique --nodes-file - --out "${RUN_DIR}/step5_devices.txt"

    python_parse exclude-if-related \
      --response "$resp5a" \
      --from-type "$MSISDN_TYPE" \
      --to-type "$DEVICE_TYPE" \
      --candidates "$CURRENT" | awk -F'|' '{print $1}' | python_parse unique --nodes-file - --out "${RUN_DIR}/step5_msisdns_with_device.txt"

    subtract_list "$CURRENT" "${RUN_DIR}/step5_msisdns_with_device.txt" "${RUN_DIR}/step5_msisdns_without_device.txt"
    log_info "step5 devices found=$(count_lines "${RUN_DIR}/step5_devices.txt"): $(preview_list "${RUN_DIR}/step5_devices.txt")"
    log_info "step5 MSISDNs with device=$(count_lines "${RUN_DIR}/step5_msisdns_with_device.txt")"
    log_info "step5 MSISDNs without device (kept as-is)=$(count_lines "${RUN_DIR}/step5_msisdns_without_device.txt"): $(preview_list "${RUN_DIR}/step5_msisdns_without_device.txt")"

    local resp5b="${RESP_DIR}/step5b_device_msisdn.json"
    if [[ "$(count_lines "${RUN_DIR}/step5_devices.txt")" -eq 0 ]]; then
      log_info "No devices found; skipping device_msisdn and keeping current MSISDNs"
      echo '{"vertices":[],"edges":[],"responseCode":0}' > "$resp5b"
      : > "${RUN_DIR}/step5_device_msisdns.txt"
    else
      run_batched_glc "device_msisdn.json" "${RUN_DIR}/step5_devices.txt" "$BATCH_SIZE" "step5b_device_msisdn" "$resp5b"
      python_parse relations \
        --response "$resp5b" \
        --from-type "$DEVICE_TYPE" \
        --to-type "$MSISDN_TYPE" \
        > "${RUN_DIR}/step5b_device_msisdn_map.txt"
      while IFS='|' read -r device msisdn || [[ -n "${device:-}" ]]; do
        [[ -n "$device" ]] || continue
        log_debug "step5b mapping device ${device} -> msisdn=${msisdn}"
      done < "${RUN_DIR}/step5b_device_msisdn_map.txt"
      awk -F'|' 'NF>=2{print $2}' "${RUN_DIR}/step5b_device_msisdn_map.txt" \
        | python_parse unique --nodes-file - --out "${RUN_DIR}/step5_device_msisdns.txt"
      log_info "step5 MSISDNs from devices=$(count_lines "${RUN_DIR}/step5_device_msisdns.txt"): $(preview_list "${RUN_DIR}/step5_device_msisdns.txt")"
    fi

    local before_count
    before_count="$(count_lines "$CURRENT")"
    merge_unique "$REMAINING" \
      "${RUN_DIR}/step5_msisdns_without_device.txt" \
      "${RUN_DIR}/step5_device_msisdns.txt"
    cp "$REMAINING" "$CURRENT"
    log_info "step5 expanded working set from ${before_count} to $(count_lines "$CURRENT") MSISDN(s)"
  fi
  finish_step "STEP 5 device expansion" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 6: msisdn_id -> id_user  (exclude MSISDN whose ID has a User)
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 2 / STEP 6: msisdn_id + id_user =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 5; skipping remaining steps"
  else
    local resp6a="${RESP_DIR}/step6a_msisdn_id.json"
    run_batched_glc "msisdn_id.json" "$CURRENT" "$BATCH_SIZE" "step6a_msisdn_id" "$resp6a"
    python_parse relations \
      --response "$resp6a" \
      --from-type "$MSISDN_TYPE" \
      --to-type "$ID_TYPE" \
      --candidates "$CURRENT" > "${RUN_DIR}/step6a_msisdn_id_map.txt"
    while IFS='|' read -r msisdn ident || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      log_debug "step6a mapping ${msisdn} -> id=${ident}"
    done < "${RUN_DIR}/step6a_msisdn_id_map.txt"

    awk -F'|' 'NF>=2{print $2}' "${RUN_DIR}/step6a_msisdn_id_map.txt" \
      | python_parse unique --nodes-file - --out "${RUN_DIR}/step6_ids.txt"
    log_info "step6 IDs found=$(count_lines "${RUN_DIR}/step6_ids.txt"): $(preview_list "${RUN_DIR}/step6_ids.txt")"

    local resp6b="${RESP_DIR}/step6b_id_user.json"
    if [[ "$(count_lines "${RUN_DIR}/step6_ids.txt")" -eq 0 ]]; then
      log_info "No IDs found; skipping id_user (no exclusions from this step)"
      echo '{"vertices":[],"edges":[],"responseCode":0}' > "$resp6b"
      : > "${RUN_DIR}/step6b_id_user_map.txt"
    else
      run_batched_glc "id_user.json" "${RUN_DIR}/step6_ids.txt" "$BATCH_SIZE" "step6b_id_user" "$resp6b"
      python_parse relations \
        --response "$resp6b" \
        --from-type "$ID_TYPE" \
        --to-type "$USER_TYPE" \
        --candidates "${RUN_DIR}/step6_ids.txt" > "${RUN_DIR}/step6b_id_user_map.txt"
      while IFS='|' read -r ident user || [[ -n "${ident:-}" ]]; do
        [[ -n "$ident" ]] || continue
        log_debug "step6b mapping id ${ident} -> user=${user}"
      done < "${RUN_DIR}/step6b_id_user_map.txt"
    fi

    local excl6="${RUN_DIR}/step6_exclude.txt"
    : > "$excl6"
    python_parse exclude-via-hop \
      --first-map "${RUN_DIR}/step6a_msisdn_id_map.txt" \
      --second-map "${RUN_DIR}/step6b_id_user_map.txt" \
      --candidates "$CURRENT" > "${RUN_DIR}/step6_exclude.raw"
    while IFS='|' read -r msisdn detail || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      echo "$msisdn" >> "$excl6"
      record_exclusion "$msisdn" "6-id_user" "id_has_user" "$detail"
    done < "${RUN_DIR}/step6_exclude.raw"
    apply_exclusions "$CURRENT" "$excl6" "$REMAINING"
    cp "$REMAINING" "$CURRENT"
  fi
  finish_step "STEP 6 msisdn_id/id_user" "$CURRENT"

  # ------------------------------------------------------------------
  # STEP 7: user_sub + sub_user (slow, batched)
  # ------------------------------------------------------------------
  log_info "========== FILTER GROUP 3 / STEP 7: user_sub + sub_user =========="
  if [[ "$(count_lines "$CURRENT")" -eq 0 ]]; then
    log_info "No MSISDNs left after step 6; skipping step 7"
  else
    local resp7a="${RESP_DIR}/step7a_user_sub.json"
    local resp7b="${RESP_DIR}/step7b_sub_user.json"
    run_batched_glc "user_sub.json" "$CURRENT" "$SLOW_BATCH_SIZE" "step7a_user_sub" "$resp7a"
    run_batched_glc "sub_user.json" "$CURRENT" "$SLOW_BATCH_SIZE" "step7b_sub_user" "$resp7b"

    python_parse has-relation --response "$resp7a" --candidates "$CURRENT" > "${RUN_DIR}/step7_user_sub_hits.txt"
    python_parse has-relation --response "$resp7b" --candidates "$CURRENT" > "${RUN_DIR}/step7_sub_user_hits.txt"
    log_info "step7 user_sub related MSISDNs=$(count_lines "${RUN_DIR}/step7_user_sub_hits.txt"): $(preview_list "${RUN_DIR}/step7_user_sub_hits.txt")"
    log_info "step7 sub_user related MSISDNs=$(count_lines "${RUN_DIR}/step7_sub_user_hits.txt"): $(preview_list "${RUN_DIR}/step7_sub_user_hits.txt")"

    local excl7="${RUN_DIR}/step7_exclude.txt"
    merge_unique "$excl7" "${RUN_DIR}/step7_user_sub_hits.txt" "${RUN_DIR}/step7_sub_user_hits.txt"
    while IFS= read -r msisdn || [[ -n "${msisdn:-}" ]]; do
      [[ -n "$msisdn" ]] || continue
      local why=""
      if grep -qxF "$msisdn" "${RUN_DIR}/step7_user_sub_hits.txt"; then
        why="user_sub"
      fi
      if grep -qxF "$msisdn" "${RUN_DIR}/step7_sub_user_hits.txt"; then
        if [[ -n "$why" ]]; then
          why="${why},sub_user"
        else
          why="sub_user"
        fi
      fi
      record_exclusion "$msisdn" "7-user_sub_sub_user" "has_relation" "$why"
    done < "$excl7"
    apply_exclusions "$CURRENT" "$excl7" "$REMAINING"
    cp "$REMAINING" "$CURRENT"
  fi
  finish_step "STEP 7 user_sub/sub_user" "$CURRENT"

  cp "$CURRENT" "$CLEAN_FILE"
  local clean_count
  clean_count="$(count_lines "$CLEAN_FILE")"
  local excluded_count
  excluded_count="$(tail -n +2 "$EXCLUDED_FILE" | wc -l | tr -d ' ')"

  log_info "=============================================================="
  log_info "DONE  clean_msisdns=${clean_count}  excluded=${excluded_count}"
  log_info "clean file: ${CLEAN_FILE}"
  log_info "excluded file: ${EXCLUDED_FILE}"
  log_info "log file: ${LOG_FILE}"
  log_info "clean MSISDNs: $(preview_list "$CLEAN_FILE")"
  log_info "=============================================================="

  if [[ -n "$OUTPUT_FILE" ]]; then
    cp "$CLEAN_FILE" "$OUTPUT_FILE"
    log_info "Wrote clean MSISDNs to ${OUTPUT_FILE}"
  fi

  if [[ "$clean_count" -gt 0 ]]; then
    cat "$CLEAN_FILE"
  fi
}

main "$@"
