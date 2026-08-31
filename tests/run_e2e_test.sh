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
    "201333333333": "6-id_user",
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
    if excluded["201333333333"][1] != "shared_device_id_has_user":
        errors.append("step 6 shared-device reason mismatch: %s" % (excluded["201333333333"],))
    if "201444444444" not in excluded["201333333333"][2]:
        errors.append("step 6 shared-device detail should mention extra 201444444444: %s" % (excluded["201333333333"],))
if report != report_file:
    errors.append("stdout report differs from -o report file")
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
if "step5 remaining set unchanged" not in log_text:
    errors.append("log missing remaining-set-unchanged message after device lookup")
if "expanded working set" in log_text:
    errors.append("log still expands remaining after device lookup")
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
