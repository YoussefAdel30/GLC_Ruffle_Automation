#!/bin/bash
#
# glc_ruffle_cron.sh
#
# Production wrapper for glc_filter_clean_msisdns.sh.
# Intended for crontab every minute:
#   * * * * * /FMS/scripts/utilities/glc_automation/glc_ruffle_cron.sh
#
# Scans ruffle/repo for CSV drops, runs the filter, emails the mapped
# user(s), and archives the input file. A lock file prevents overlapping
# runs. Empty-repo logs are deleted at the start of the next run.
#
# Layout (defaults):
#   /FMS/scripts/utilities/glc_automation/glc_ruffle_cron.sh
#   /FMS/scripts/utilities/glc_automation/glc_filter_clean_msisdns.sh
#   /FMS/scripts/utilities/glc_automation/mapper.csv
#   /FMS/scripts/utilities/glc_automation/ruffle/repo
#   /FMS/scripts/utilities/glc_automation/ruffle/archive
#   /FMS/scripts/utilities/glc_automation/ruffle/logs
#
# Override any path with env vars (used by tests):
#   RUFFLE_HOME REPO_DIR ARCHIVE_DIR LOG_DIR LOCK_FILE MAPPER_FILE
#   FILTER_SCRIPT MAILX SMTP_SERVER MAIL_FROM FMS_TEAM FMS_CC
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_PY="${SCRIPT_DIR}/glc_ruffle_jobs.py"
FILTER_SCRIPT="${FILTER_SCRIPT:-${SCRIPT_DIR}/glc_filter_clean_msisdns.sh}"
MAPPER_FILE="${MAPPER_FILE:-${SCRIPT_DIR}/mapper.csv}"

RUFFLE_HOME="${RUFFLE_HOME:-/FMS/scripts/utilities/glc_automation/ruffle}"
REPO_DIR="${REPO_DIR:-${RUFFLE_HOME}/repo}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${RUFFLE_HOME}/archive}"
LOG_DIR="${LOG_DIR:-${RUFFLE_HOME}/logs}"
WORK_DIR="${WORK_DIR:-${RUFFLE_HOME}/work}"
LOCK_FILE="${LOCK_FILE:-${RUFFLE_HOME}/ruffle.lock}"

SMTP_SERVER="${SMTP_SERVER:-10.230.30.32:25}"
MAIL_FROM="${MAIL_FROM:-Anti-Fraud_Notifications_Center@vodafone.com}"
FMS_TEAM="${FMS_TEAM:-yasmin.wanas@vodafone.com.eg,mohamed.abdelrehim@vodafone.com.eg,omar.salah@vodafone.com.eg,Mai.Sheta@vodafone.com.eg,youssef.adel@vodafone.com.eg}"
FMS_CC="${FMS_CC:-Youssef.amr1@vodafone.com.eg,abdallah.ibrahim@vodafone.com.eg,bassant.mahmoud2@vodafone.com.eg,bassant.saad@vodafone.com}"
MAILX="${MAILX:-mailx}"

RUN_TS="$(date '+%Y%m%d_%H%M%S')"
RUN_LOG=""

log() {
  local level="$1"
  shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
  echo "$msg" >&2
  if [[ -n "${RUN_LOG:-}" ]]; then
    echo "$msg" >> "$RUN_LOG"
  fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

fail() {
  log_error "$@"
  exit 1
}

ensure_dirs() {
  mkdir -p "$REPO_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$WORK_DIR"
}

clean_empty_logs() {
  local f
  local old_nullglob
  old_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  for f in "$LOG_DIR"/empty_*.log; do
    rm -f "$f"
  done
  eval "$old_nullglob"
}

list_repo_csvs() {
  local f
  local old_nullglob
  old_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  for f in "$REPO_DIR"/*.csv "$REPO_DIR"/*.CSV; do
    [[ -f "$f" ]] || continue
    echo "$f"
  done
  eval "$old_nullglob"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] another ruffle run is still live; exiting" >&2
    exit 0
  fi
}

userid_label() {
  local userids_file="$1"
  python3 "$JOBS_PY" label --userids "$userids_file"
}

send_mail() {
  local to_csv="$1"
  local attach="$2"
  local body="$3"
  local subject="$4"
  local to_args=()
  local addr
  if [[ -n "$to_csv" ]]; then
    IFS=',' read -r -a to_args <<< "$to_csv"
  fi
  if [[ "${#to_args[@]}" -eq 0 ]]; then
    log_warn "no mapped TO addresses; sending to FMS team BCC only"
  fi

  local mail_args=(
    -v
    -s "$subject"
    -r "$MAIL_FROM"
    -S "smtp=$SMTP_SERVER"
    -c "$FMS_CC"
    -b "$FMS_TEAM"
    -a "$attach"
  )

  # Heirloom mailx reads the body from stdin.
  if [[ "${#to_args[@]}" -eq 0 ]]; then
    IFS=',' read -r -a to_args <<< "$FMS_TEAM"
    to_args=("${to_args[0]}")
  fi
  printf '%s\n' "$body" | "$MAILX" "${mail_args[@]}" "${to_args[@]}"
}

process_csv() {
  local src="$1"
  local base
  base="$(basename "$src")"
  local job_dir="${WORK_DIR}/${RUN_TS}_$$_$(echo "$base" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$job_dir"

  local msisdns_file="${job_dir}/msisdns.txt"
  local userids_file="${job_dir}/userids.txt"
  local emails_file="${job_dir}/emails.txt"
  local missing_file="${job_dir}/missing_userids.txt"
  local raffle_name_file="${job_dir}/raffle_name.txt"
  local filter_dir="${job_dir}/filter"
  local attach="${job_dir}/ruffle_result.csv"

  log_info "Parsing drop file ${src}"
  python3 "$JOBS_PY" parse --csv "$src" --msisdns-out "$msisdns_file" --userids-out "$userids_file" --raffle-name-out "$raffle_name_file"
  python3 "$JOBS_PY" map --mapper "$MAPPER_FILE" --userids "$userids_file" --emails-out "$emails_file" --missing-out "$missing_file"

  local userids emails missing n_in raffle_name
  userids="$(tr '\n' ',' < "$userids_file" | sed 's/,$//')"
  emails="$(tr '\n' ',' < "$emails_file" | sed 's/,$//')"
  missing="$(tr '\n' ',' < "$missing_file" | sed 's/,$//')"
  raffle_name="$(tr -d '\n\r' < "$raffle_name_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$raffle_name" ]] || raffle_name="unknown"
  n_in="$(wc -l < "$msisdns_file" | tr -d ' ')"
  [[ -s "$msisdns_file" ]] || n_in=0
  local label
  label="$(userid_label "$userids_file")"
  local mail_subject="FMS Raffle Results || ${raffle_name} || ${RUN_TS}"

  log_info "File ${base} userids=${userids:-none} emails=${emails:-none} msisdns=${n_in} raffle_name=${raffle_name}"
  if [[ -n "$missing" ]]; then
    log_warn "Unmapped user ids (not in mapper.csv): ${missing}"
  fi

  if [[ "$n_in" -eq 0 ]]; then
    log_warn "No MSISDNs in ${base}; archiving without a filter run"
    : > "${job_dir}/empty_remaining.txt"
    : > "${job_dir}/empty_excluded.txt"
    echo "msisdn|step|reason|detail" > "${job_dir}/empty_excluded.txt"
    python3 "$JOBS_PY" attachment \
      --input-file "$msisdns_file" \
      --remaining-file "${job_dir}/empty_remaining.txt" \
      --excluded-file "${job_dir}/empty_excluded.txt" \
      --out "$attach"
  else
    log_info "Running filter on ${n_in} MSISDN(s) from ${base}"
    mkdir -p "$filter_dir"
    "$FILTER_SCRIPT" \
      -i "$msisdns_file" \
      -o "${job_dir}/filter_report.txt" \
      -d "$filter_dir" \
      > "${job_dir}/filter_stdout.txt"
    log_info "Filter run_dir listing: $(ls -1 "$filter_dir" 2>/dev/null | tr '\n' ' ')"
    python3 "$JOBS_PY" attachment \
      --input-file "$msisdns_file" \
      --remaining-file "${filter_dir}/clean_msisdns.txt" \
      --excluded-file "${filter_dir}/excluded.txt" \
      --report-file "${job_dir}/filter_report.txt" \
      --out "$attach"
  fi
  local attach_rows
  attach_rows="$(python3 -c "import csv,sys; print(max(0,len(list(csv.reader(open(sys.argv[1]))))-1))" "$attach")"
  log_info "Attachment ${attach} data_rows=${attach_rows}"
  if [[ "$n_in" -gt 0 && "$attach_rows" -eq 0 ]]; then
    log_error "Attachment is header-only; rebuilding from filter report"
    python3 "$JOBS_PY" attachment \
      --input-file "$msisdns_file" \
      --remaining-file "${filter_dir}/clean_msisdns.txt" \
      --excluded-file "${filter_dir}/excluded.txt" \
      --report-file "${job_dir}/filter_report.txt" \
      --out "$attach"
  fi

  local remain_n excl_n
  remain_n=0
  excl_n=0
  if [[ -f "${filter_dir}/clean_msisdns.txt" ]]; then
    remain_n="$(wc -l < "${filter_dir}/clean_msisdns.txt" | tr -d ' ')"
    [[ -s "${filter_dir}/clean_msisdns.txt" ]] || remain_n=0
  fi
  if [[ -f "${filter_dir}/excluded.txt" ]]; then
    excl_n="$(tail -n +2 "${filter_dir}/excluded.txt" | wc -l | tr -d ' ')"
  fi

  local result_name="ruffle_result_${RUN_TS}_${label}.csv"
  local result_copy="${job_dir}/${result_name}"
  cp "$attach" "$result_copy"

  local body
  body="Hello,

This is an automated notification from FMS.

User ID: ${userids:-unknown}
Raffle: ${raffle_name}
Input file: ${base}
Input MSISDNs: ${n_in}
Filtered MSISDNs: ${remain_n}
Excluded MSISDNs: ${excl_n}

Regards,
FMS Team"

  log_info "Sending mail subject=${mail_subject} TO=${emails:-none} CC=${FMS_CC} BCC=${FMS_TEAM} attach=${result_name}"
  send_mail "$emails" "$result_copy" "$body" "$mail_subject"
  log_info "Mail sent for ${base}"

  local archived="${ARCHIVE_DIR}/ruffle_${RUN_TS}_${label}.csv"
  if [[ "$base" != ruffle.csv && "$base" != ruffle.CSV ]]; then
    local stem="${base%.*}"
    archived="${ARCHIVE_DIR}/${stem}_${RUN_TS}_${label}.csv"
  fi
  mv "$src" "$archived"
  log_info "Archived ${base} -> ${archived}"
}

main() {
  [[ -f "$JOBS_PY" ]] || fail "missing helper: $JOBS_PY"
  [[ -f "$FILTER_SCRIPT" ]] || fail "missing filter script: $FILTER_SCRIPT"
  [[ -f "$MAPPER_FILE" ]] || fail "missing mapper file: $MAPPER_FILE"

  ensure_dirs
  acquire_lock
  clean_empty_logs

  local files=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    files+=("$line")
  done < <(list_repo_csvs)

  if [[ "${#files[@]}" -eq 0 ]]; then
    RUN_LOG="${LOG_DIR}/empty_${RUN_TS}.log"
    : > "$RUN_LOG"
    log_info "repo is empty; nothing to process"
    exit 0
  fi

  RUN_LOG="${LOG_DIR}/run_${RUN_TS}.log"
  : > "$RUN_LOG"
  log_info "ruffle cron starting files=${#files[@]}"
  log_info "repo=${REPO_DIR}"
  log_info "mapper=${MAPPER_FILE}"

  local src
  for src in "${files[@]}"; do
    if ! process_csv "$src"; then
      log_error "Failed processing ${src}; file left in repo for the next run"
    fi
  done

  log_info "ruffle cron finished"
}

main "$@"
