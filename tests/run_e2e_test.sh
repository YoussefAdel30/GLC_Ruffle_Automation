#!/bin/bash
# End-to-end test of glc_filter_clean_msisdns.sh using mock GLC responses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

chmod 775 "$ROOT/glc_filter_clean_msisdns.sh" "$ROOT/tests/mock_glc_auto.sh" "$ROOT/glc_graph_parse.py"

echo "=== parser selftest ==="
python3 "$ROOT/glc_graph_parse.py" selftest

echo "=== real-sample relation parse ==="
rel="$(python3 "$ROOT/glc_graph_parse.py" relations --response "$ROOT/tests/fixtures/sample_msisdn_user.json" --from-type 1 --to-type 1001)"
if [[ "$rel" != "201066257228|ADELY1" ]]; then
  echo "FAIL: expected 201066257228|ADELY1 got: $rel" >&2
  exit 1
fi
excl="$(python3 "$ROOT/glc_graph_parse.py" exclude-if-related --response "$ROOT/tests/fixtures/sample_msisdn_user.json" --from-type 1 --to-type 1001)"
if [[ "$excl" != "201066257228|ADELY1" ]]; then
  echo "FAIL: exclude-if-related got: $excl" >&2
  exit 1
fi
echo "real_sample_ok"

echo "=== e2e filter test ==="
"$ROOT/glc_filter_clean_msisdns.sh" \
  --glc-auto "$ROOT/tests/mock_glc_auto.sh" \
  --request-types "$ROOT/request_types" \
  --batch-size 3 \
  --slow-batch-size 2 \
  -i "$ROOT/tests/fixtures/input_msisdns.txt" \
  -o "$TMP/report.txt" \
  -d "$TMP/run" \
  > "$TMP/stdout.txt"

echo "--- report stdout ---"
cat "$TMP/stdout.txt"
echo "--- remaining ---"
cat "$TMP/run/clean_msisdns.txt"
echo "--- excluded ---"
cat "$TMP/run/excluded.txt"
echo "--- log (tail) ---"
tail -n 20 "$TMP/run/filter.log"

python3 - "$TMP/run/clean_msisdns.txt" "$TMP/run/excluded.txt" "$TMP/stdout.txt" "$TMP/report.txt" "$ROOT/tests/fixtures/input_msisdns.txt" "$TMP/run/responses" "$TMP/run/filter.log" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timedelta

clean_path, excluded_path, stdout_path, report_path, input_path, resp_dir, log_path = sys.argv[1:8]
clean = [ln.strip() for ln in open(clean_path) if ln.strip()]
report = open(stdout_path).read()
report_file = open(report_path).read()
log_text = open(log_path).read()
excluded = {}
for ln in open(excluded_path):
    ln = ln.strip()
    if not ln or ln.startswith("msisdn|"):
        continue
    msisdn, step, reason, detail = ln.split("|", 3)
    excluded[msisdn] = (step, reason, detail)

input_msisdns = []
seen = set()
for ln in open(input_path):
    item = ln.strip()
    if not item or item.startswith("#"):
        continue
    if item not in seen:
        seen.add(item)
        input_msisdns.append(item)

expected_clean = ["201666666666", "201777777777"]
expected_excluded = {
    "201066257228": "1-msisdn_user",
    "201033008757": "2-wallet_profile",
    "201111111111": "3-wallet_status",
    "201222222222": "4-line_status",
    "201333333333": "5-msisdn_device_id_user",
    "201555555555": "7-user_sub_sub_user",
}

errors = []
if clean != expected_clean:
    errors.append("clean mismatch: got %s expected %s" % (clean, expected_clean))
if "201444444444" in clean:
    errors.append("probe-only device sibling 201444444444 must not enter remaining")
for msisdn, step in expected_excluded.items():
    if msisdn not in excluded:
        errors.append("missing exclusion for %s" % msisdn)
    elif excluded[msisdn][0] != step:
        errors.append("exclusion step for %s: got %s expected %s" % (msisdn, excluded[msisdn][0], step))
extra = set(excluded) - set(expected_excluded)
if extra:
    errors.append("unexpected exclusions: %s" % sorted(extra))
if "201033008757" in excluded and "Credit Only Consumer" not in excluded["201033008757"][2]:
    errors.append("wallet profile exclusion missing Credit Only Consumer: %s" % (excluded["201033008757"],))
if "201222222222" in excluded:
    if excluded["201222222222"][1] != "suspension_reason":
        errors.append("step 4 reason should be suspension_reason: %s" % (excluded["201222222222"],))
    if "Fraud IRSF" not in excluded["201222222222"][2]:
        errors.append("step 4 should match Fraud IRSF: %s" % (excluded["201222222222"],))
if "201333333333" in excluded:
    if excluded["201333333333"][1] != "linked_id_user":
        errors.append("step 5 linked-id-user reason mismatch: %s" % (excluded["201333333333"],))
    if "201444444444" not in excluded["201333333333"][2]:
        errors.append("step 5 walk-back detail should mention extra 201444444444: %s" % (excluded["201333333333"],))
if report != report_file:
    errors.append("stdout report differs from -o report file")
if "FAILED BATCHES" in report:
    errors.append("happy-path report should not list failed batches: %s" % report[-400:])
if "----- REMAINING MSISDNs (2) -----" not in report:
    errors.append("report missing remaining header: %s" % report[:400])
if "not in input" in report or "remaining_added_via_device" in report:
    errors.append("report must not grow remaining with device siblings: %s" % report[:800])
for msisdn in expected_clean:
    remaining_section = report.split("----- EXCLUDED INPUT MSISDNs")[0]
    if msisdn not in remaining_section:
        errors.append("remaining msisdn %s missing from report remaining section" % msisdn)
for msisdn in input_msisdns:
    if msisdn in expected_clean:
        continue
    if msisdn not in report:
        errors.append("excluded input %s missing from report" % msisdn)
    else:
        if excluded[msisdn][0] not in report:
            errors.append("excluded input %s missing step in report" % msisdn)
if "hop set msisdn-device-msisdn=" not in log_text:
    errors.append("log missing hop-set size for msisdn-device-msisdn")
if "expanded working set" in log_text:
    errors.append("log still expands remaining after device lookup")
if "FILTER GROUP 2 / STEP 6:" in log_text:
    errors.append("id_user must stay inside step 5, not a separate remaining-growing step")
remaining_counts = [int(n) for n in re.findall(r" remaining=(\d+) ", log_text)]
if remaining_counts:
    prev = remaining_counts[0]
    for n in remaining_counts[1:]:
        if n > prev:
            errors.append("remaining count increased in log: %s" % remaining_counts)
            break
        prev = n

expected_from = (datetime.now() - timedelta(days=45)).strftime("%Y/%m/%d 00:00:00")
expected_to = datetime.now().strftime("%Y/%m/%d 23:59:59")
req_files = [
    os.path.join(resp_dir, name)
    for name in os.listdir(resp_dir)
    if name.endswith(".request.json")
]
if not req_files:
    errors.append("no GLC request JSON files found to check analysis dates")
for path in req_files:
    with open(path) as fh:
        req = json.load(fh)
    if req.get("dateFrom") != expected_from or req.get("dateTo") != expected_to:
        errors.append(
            "request %s has dateFrom=%s dateTo=%s expected %s .. %s"
            % (path, req.get("dateFrom"), req.get("dateTo"), expected_from, expected_to)
        )

if errors:
    raise SystemExit("E2E FAILED:\n- " + "\n- ".join(errors))
print("e2e_ok")
print("clean=%s" % ",".join(clean))
print("excluded=%s" % ",".join("%s:%s" % (k, v[0]) for k, v in sorted(excluded.items())))
PY

echo "=== e2e retry responseCode 103 then succeed ==="
RETRY_DIR="$TMP/retry"
mkdir -p "$RETRY_DIR"
GLC_RETRY_SLEEP=0 \
GLC_MOCK_FAIL_LINK=535 \
GLC_MOCK_FAIL_CODE=103 \
GLC_MOCK_FAIL_TIMES=2 \
GLC_MOCK_FAIL_NODE=201033008757 \
GLC_MOCK_FAIL_MSG="mock truncated" \
GLC_MOCK_STATE="$RETRY_DIR/mock-state" \
"$ROOT/glc_filter_clean_msisdns.sh" \
  --glc-auto "$ROOT/tests/mock_glc_auto.sh" \
  --request-types "$ROOT/request_types" \
  --batch-size 3 \
  --slow-batch-size 2 \
  --retries 3 \
  -i "$ROOT/tests/fixtures/input_msisdns.txt" \
  -o "$RETRY_DIR/report.txt" \
  -d "$RETRY_DIR/run" \
  > "$RETRY_DIR/stdout.txt"

python3 - "$RETRY_DIR/run/excluded.txt" "$RETRY_DIR/run/filter.log" "$RETRY_DIR/report.txt" <<'PY'
import re
import sys
excluded_path, log_path, report_path = sys.argv[1:4]
excluded = {}
for ln in open(excluded_path):
    ln = ln.strip()
    if not ln or ln.startswith("msisdn|"):
        continue
    msisdn, step, reason, detail = ln.split("|", 3)
    excluded[msisdn] = step
log_text = open(log_path).read()
report = open(report_path).read()
errors = []
if excluded.get("201033008757") != "2-wallet_profile":
    errors.append("103 then success should still exclude wallet profile: %s" % excluded.get("201033008757"))
attempts = re.findall(r"GLC call \[step2_wallet_profile/batch1\] attempt (\d+)/3", log_text)
if attempts != ["1", "2", "3"]:
    errors.append("expected 3 attempts for 103 retries, got %s" % attempts)
if "responseCode=103" not in log_text:
    errors.append("log should show responseCode=103 before retry")
if "FAILED BATCHES" in report:
    errors.append("successful retry should not list failed batches")
if errors:
    raise SystemExit("RETRY E2E FAILED:\n- " + "\n- ".join(errors))
print("retry_103_then_success_ok")
PY

echo "=== e2e persistent responseCode 103 listed in final report ==="
FAIL_DIR="$TMP/fail"
mkdir -p "$FAIL_DIR"
GLC_RETRY_SLEEP=0 \
GLC_MOCK_FAIL_LINK=535 \
GLC_MOCK_FAIL_CODE=103 \
GLC_MOCK_FAIL_ALWAYS=1 \
GLC_MOCK_FAIL_NODE=201033008757 \
GLC_MOCK_FAIL_MSG="search truncated" \
GLC_MOCK_STATE="$FAIL_DIR/mock-state" \
"$ROOT/glc_filter_clean_msisdns.sh" \
  --glc-auto "$ROOT/tests/mock_glc_auto.sh" \
  --request-types "$ROOT/request_types" \
  --batch-size 3 \
  --slow-batch-size 2 \
  --retries 3 \
  -i "$ROOT/tests/fixtures/input_msisdns.txt" \
  -o "$FAIL_DIR/report.txt" \
  -d "$FAIL_DIR/run" \
  > "$FAIL_DIR/stdout.txt"

python3 - "$FAIL_DIR/run/clean_msisdns.txt" "$FAIL_DIR/run/excluded.txt" "$FAIL_DIR/report.txt" "$FAIL_DIR/run/failed_batches.jsonl" "$FAIL_DIR/run/filter.log" <<'PY'
import json
import sys
clean_path, excluded_path, report_path, failed_path, log_path = sys.argv[1:6]
clean = [ln.strip() for ln in open(clean_path) if ln.strip()]
excluded = {}
for ln in open(excluded_path):
    ln = ln.strip()
    if not ln or ln.startswith("msisdn|"):
        continue
    msisdn, step, reason, detail = ln.split("|", 3)
    excluded[msisdn] = step
report = open(report_path).read()
failed = [json.loads(ln) for ln in open(failed_path) if ln.strip()]
log_text = open(log_path).read()
errors = []
if "201033008757" in excluded:
    errors.append("failed wallet-profile batch must not exclude 201033008757: %s" % excluded["201033008757"])
if "201033008757" not in clean:
    errors.append("201033008757 should remain after failed wallet-profile batch: %s" % clean)
if "FAILED BATCHES AFTER 3 RETRIES (1)" not in report:
    errors.append("report missing failed-batches header: %s" % report[-800:])
if "These batches failed after 3 retries" not in report:
    errors.append("report should say batches failed after 3 retries")
if "step2_wallet_profile" not in report:
    errors.append("report should name the failed step")
if "code:    103" not in report:
    errors.append("report should show responseCode 103")
if "search truncated" not in report:
    errors.append("report should include warningMsg")
if len(failed) != 1:
    errors.append("expected 1 failed batch record, got %s" % failed)
else:
    row = failed[0]
    if row.get("step") != "step2_wallet_profile" or row.get("batch") != 1:
        errors.append("failed batch identity mismatch: %s" % row)
    if row.get("responseCode") != 103:
        errors.append("failed batch code mismatch: %s" % row)
    if "201033008757" not in (row.get("nodes") or []):
        errors.append("failed batch nodes missing 201033008757: %s" % row)
if "failed after 3 retries: step2_wallet_profile/batch1" not in log_text:
    errors.append("log missing exhausted-retry error for batch1")
if errors:
    raise SystemExit("FAIL-103 E2E FAILED:\n- " + "\n- ".join(errors))
print("persistent_103_report_ok")
PY
