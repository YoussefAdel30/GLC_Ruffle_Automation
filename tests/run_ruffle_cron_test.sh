#!/bin/bash
# Local tests for the ruffle cron wrapper (no FMS / no SMTP).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

chmod 775 "$ROOT/glc_ruffle_cron.sh" "$ROOT/glc_ruffle_jobs.py" \
  "$ROOT/glc_filter_clean_msisdns.sh" "$ROOT/tests/mock_glc_auto.sh"

echo "=== ruffle jobs selftest ==="
python3 "$ROOT/glc_ruffle_jobs.py" selftest

echo "=== parse sample ruffle.csv ==="
python3 "$ROOT/glc_ruffle_jobs.py" parse \
  --csv "$ROOT/ruffle.csv" \
  --msisdns-out "$TMP/sample_msisdns.txt" \
  --userids-out "$TMP/sample_userids.txt"
if [[ "$(tr -d '\n' < "$TMP/sample_msisdns.txt")" != "201066257228" ]]; then
  echo "sample ruffle.csv should yield 201066257228" >&2
  exit 1
fi
if [[ "$(tr -d '\n' < "$TMP/sample_userids.txt")" != "AdelY1" ]]; then
  echo "sample ruffle.csv should yield AdelY1" >&2
  exit 1
fi

echo "=== map mapper.csv ==="
printf 'AmrY1\nIBRAHIMA67\nNOPE\n' > "$TMP/map_users.txt"
python3 "$ROOT/glc_ruffle_jobs.py" map \
  --mapper "$ROOT/mapper.csv" \
  --userids "$TMP/map_users.txt" \
  --emails-out "$TMP/map_emails.txt" \
  --missing-out "$TMP/map_missing.txt"
if ! grep -qxF "Youssef.amr1@vodafone.com.eg" "$TMP/map_emails.txt"; then
  echo "AmrY1 email missing" >&2
  exit 1
fi
if ! grep -qxF "abdallah.ibrahim@vodafone.com.eg" "$TMP/map_emails.txt"; then
  echo "IBRAHIMA67 email missing" >&2
  exit 1
fi
if ! grep -qxF "NOPE" "$TMP/map_missing.txt"; then
  echo "unmapped userid not reported" >&2
  exit 1
fi

HOME_DIR="$TMP/ruffle"
REPO="$HOME_DIR/repo"
ARCHIVE="$HOME_DIR/archive"
LOGS="$HOME_DIR/logs"
mkdir -p "$REPO" "$ARCHIVE" "$LOGS"

MAILX_BIN="$TMP/fake_mailx"
cat > "$MAILX_BIN" <<'EOF'
#!/bin/bash
out_dir="$(dirname "$0")"
printf '%s\n' "$@" > "$out_dir/mail.args"
cat > "$out_dir/mail.body"
EOF
chmod 775 "$MAILX_BIN"

run_cron() {
  RUFFLE_HOME="$HOME_DIR" \
  REPO_DIR="$REPO" \
  ARCHIVE_DIR="$ARCHIVE" \
  LOG_DIR="$LOGS" \
  LOCK_FILE="$HOME_DIR/ruffle.lock" \
  WORK_DIR="$HOME_DIR/work" \
  MAPPER_FILE="$ROOT/mapper.csv" \
  FILTER_SCRIPT="$ROOT/glc_filter_clean_msisdns.sh" \
  GLC_AUTO="$ROOT/tests/mock_glc_auto.sh" \
  MAILX="$MAILX_BIN" \
  SMTP_SERVER="10.230.30.32:25" \
  FMS_TEAM="yasmin.wanas@vodafone.com.eg,mohamed.abdelrehim@vodafone.com.eg" \
  "$ROOT/glc_ruffle_cron.sh"
}

echo "=== empty repo writes empty log then next run cleans it ==="
run_cron
empty_logs=("$LOGS"/empty_*.log)
if [[ "${#empty_logs[@]}" -ne 1 || ! -f "${empty_logs[0]}" ]]; then
  echo "expected one empty log, got: ${empty_logs[*]:-none}" >&2
  exit 1
fi
if ! grep -q "repo is empty" "${empty_logs[0]}"; then
  echo "empty log missing message" >&2
  exit 1
fi
sleep 1
run_cron
if [[ -f "${empty_logs[0]}" ]]; then
  echo "previous empty log was not cleaned" >&2
  exit 1
fi
empty_logs=("$LOGS"/empty_*.log)
if [[ "${#empty_logs[@]}" -ne 1 ]]; then
  echo "expected a fresh empty log after second empty run" >&2
  exit 1
fi

echo "=== lock prevents a second live instance ==="
exec 8>"$HOME_DIR/ruffle.lock"
flock -n 8
set +e
lock_out="$(run_cron 2>&1)"
lock_rc=$?
set -e
flock -u 8
if [[ "$lock_rc" -ne 0 ]]; then
  echo "locked run should exit 0: $lock_out" >&2
  exit 1
fi
if ! printf '%s\n' "$lock_out" | grep -q "another ruffle run is still live"; then
  echo "lock message missing: $lock_out" >&2
  exit 1
fi

echo "=== process drop CSV, email, archive ==="
cat > "$REPO/ruffle.csv" <<'EOF'
201066257228,AmrY1,Ramadan2026
201666666666,AmrY1,IgnoredLaterName
,
,
EOF
run_cron

if [[ -f "$REPO/ruffle.csv" ]]; then
  echo "processed file should have left repo" >&2
  exit 1
fi
archived=("$ARCHIVE"/ruffle_*_AmrY1.csv)
if [[ "${#archived[@]}" -ne 1 ]]; then
  echo "expected one archived file, got ${archived[*]:-none}" >&2
  ls -la "$ARCHIVE" >&2
  exit 1
fi
if [[ "$(basename "${archived[0]}")" != ruffle_*_AmrY1.csv ]]; then
  echo "archive name should be ruffle_TIMESTAMP_AmrY1.csv: ${archived[0]}" >&2
  exit 1
fi

run_logs=("$LOGS"/run_*.log)
if [[ "${#run_logs[@]}" -lt 1 ]]; then
  echo "missing run log" >&2
  exit 1
fi
if ! grep -q "Mail sent" "${run_logs[-1]}"; then
  echo "run log missing mail sent: $(cat "${run_logs[-1]}")" >&2
  exit 1
fi

if [[ ! -s "$TMP/mail.args" ]]; then
  echo "mailx was not invoked" >&2
  exit 1
fi
args="$(tr '\n' ' ' < "$TMP/mail.args")"
echo "$args" | grep -F -q -- "FMS Raffle Results || Ramadan2026 ||" || { echo "subject missing raffle name: $args" >&2; exit 1; }
echo "$args" | grep -q -- "-r Anti-Fraud_Notifications_Center@vodafone.com" || { echo "from missing: $args" >&2; exit 1; }
echo "$args" | grep -q -- "smtp=10.230.30.32:25" || { echo "smtp missing: $args" >&2; exit 1; }
echo "$args" | grep -q -- "yasmin.wanas@vodafone.com.eg,mohamed.abdelrehim@vodafone.com.eg" || { echo "bcc missing: $args" >&2; exit 1; }
echo "$args" | grep -q -- "Youssef.amr1@vodafone.com.eg" || { echo "to email missing: $args" >&2; exit 1; }
echo "$args" | grep -q -- "-a " || { echo "attachment flag missing: $args" >&2; exit 1; }
if ! grep -q "User ID: AmrY1" "$TMP/mail.body"; then
  echo "mail body missing user id: $(cat "$TMP/mail.body")" >&2
  exit 1
fi
if ! grep -q "Raffle: Ramadan2026" "$TMP/mail.body"; then
  echo "mail body missing raffle name: $(cat "$TMP/mail.body")" >&2
  exit 1
fi

attach="$(python3 - "$TMP/mail.args" <<'PY'
import sys
args = open(sys.argv[1]).read().splitlines()
for i, a in enumerate(args):
    if a == "-a" and i + 1 < len(args):
        print(args[i + 1])
        break
else:
    raise SystemExit("no -a path")
PY
)"
if [[ ! -f "$attach" ]]; then
  echo "attachment missing: $attach" >&2
  exit 1
fi
python3 - "$attach" <<'PY'
import csv
import sys
rows = list(csv.reader(open(sys.argv[1])))
if rows[0] != ["Input MSISDNs", "Filtered Msisdns", "Excluded Msisdns", "Reason of exclusion"]:
    raise SystemExit("bad header: %s" % rows[0])
by = {r[0]: r for r in rows[1:]}
if "201066257228" not in by or by["201066257228"][2] != "201066257228":
    raise SystemExit("201066257228 should be excluded: %s" % rows)
if "has_user" not in by["201066257228"][3]:
    raise SystemExit("exclusion reason missing: %s" % by["201066257228"])
if "201666666666" not in by or by["201666666666"][1] != "201666666666":
    raise SystemExit("201666666666 should remain filtered: %s" % rows)
print("attachment_ok")
PY

echo "=== remaining=0 still fills attachment rows ==="
rm -f "$TMP/mail.args" "$TMP/mail.body"
cat > "$REPO/ruffle.csv" <<'EOF'
201066257228,AmrY1,Ramadan2026
,
,
EOF
run_cron
attach0="$(python3 - "$TMP/mail.args" <<'PY'
import sys
args = open(sys.argv[1]).read().splitlines()
for i, a in enumerate(args):
    if a == "-a" and i + 1 < len(args):
        print(args[i + 1])
        break
else:
    raise SystemExit("no -a path")
PY
)"
python3 - "$attach0" <<'PY'
import csv
import sys
rows = list(csv.reader(open(sys.argv[1])))
if len(rows) < 2:
    raise SystemExit("header-only attachment for remaining=0: %s" % rows)
by = {r[0]: r for r in rows[1:]}
if "201066257228" not in by or by["201066257228"][2] != "201066257228":
    raise SystemExit("excluded msisdn missing from remaining=0 attachment: %s" % rows)
if "has_user" not in by["201066257228"][3]:
    raise SystemExit("reason missing from remaining=0 attachment: %s" % by["201066257228"])
print("remaining0_attachment_ok")
PY

echo "=== two user ids in column 2 go to both emails ==="
cat > "$REPO/ruffle.csv" <<'EOF'
201777777777,AmrY1,Eid2026
201666666666,IBRAHIMA67,IgnoredLaterName
EOF
rm -f "$TMP/mail.args" "$TMP/mail.body"
run_cron
args="$(tr '\n' ' ' < "$TMP/mail.args")"
echo "$args" | grep -q -- "Youssef.amr1@vodafone.com.eg" || { echo "first to missing: $args" >&2; exit 1; }
echo "$args" | grep -q -- "abdallah.ibrahim@vodafone.com.eg" || { echo "second to missing: $args" >&2; exit 1; }
echo "$args" | grep -F -q -- "FMS Raffle Results || Eid2026 ||" || { echo "second mail subject missing Eid2026: $args" >&2; exit 1; }
two_arch=("$ARCHIVE"/ruffle_*_AmrY1_IBRAHIMA67.csv)
if [[ "${#two_arch[@]}" -lt 1 ]]; then
  echo "archive name should include both user ids" >&2
  ls -la "$ARCHIVE" >&2
  exit 1
fi

echo "ruffle_cron_tests_ok"
