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
  -o "$TMP/clean.txt" \
  -d "$TMP/run" \
  > "$TMP/stdout.txt"

echo "--- clean stdout ---"
cat "$TMP/stdout.txt"
echo "--- excluded ---"
cat "$TMP/run/excluded.txt"
echo "--- log (tail) ---"
tail -n 40 "$TMP/run/filter.log"

python3 - "$TMP/clean.txt" "$TMP/run/excluded.txt" <<'PY'
import sys

clean_path, excluded_path = sys.argv[1:3]
clean = [ln.strip() for ln in open(clean_path) if ln.strip()]
excluded = {}
for ln in open(excluded_path):
    ln = ln.strip()
    if not ln or ln.startswith("msisdn|"):
        continue
    msisdn, step, reason, detail = ln.split("|", 3)
    excluded[msisdn] = (step, reason, detail)

expected_clean = ["201666666666", "201333333333", "201777777777"]
expected_excluded = {
    "201066257228": "1-msisdn_user",
    "201033008757": "2-wallet_profile",
    "201111111111": "3-wallet_status",
    "201222222222": "4-line_status",
    "201444444444": "6-id_user",
    "201555555555": "7-user_sub_sub_user",
}

errors = []
if clean != expected_clean:
    errors.append("clean mismatch: got %s expected %s" % (clean, expected_clean))
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
if errors:
    raise SystemExit("E2E FAILED:\n- " + "\n- ".join(errors))
print("e2e_ok")
print("clean=%s" % ",".join(clean))
print("excluded=%s" % ",".join("%s:%s" % (k, v[0]) for k, v in sorted(excluded.items())))
PY
