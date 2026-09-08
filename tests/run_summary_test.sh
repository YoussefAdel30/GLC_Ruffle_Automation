#!/bin/bash
# Local tests for glc_graph_summary.py (no FMS / no network).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chmod 775 "$ROOT/glc_graph_summary.sh" "$ROOT/glc_graph_summary.py"

echo "=== summary selftest ==="
python3 "$ROOT/glc_graph_summary.py" selftest

echo "=== summarize line-status fixture ==="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 "$ROOT/glc_graph_summary.py" summarize \
  --request "$ROOT/tests/fixtures/summary_line_status_request.json" \
  --response "$ROOT/tests/fixtures/summary_line_status_response.json" \
  --out "$tmp/line.txt"
cat "$tmp/line.txt"
grep -q "3 MSISDN nodes" "$tmp/line.txt"
grep -q "2 Line Status nodes" "$tmp/line.txt"
grep -q "There are 2 different Line Status nodes" "$tmp/line.txt"
grep -q "Fraud" "$tmp/line.txt"
if grep -q "linkTypeId" "$tmp/line.txt"; then
  echo "unexpected linkTypeId in business report" >&2
  exit 1
fi

echo "=== summarize voicecall fixture ==="
python3 "$ROOT/glc_graph_summary.py" summarize \
  --request "$ROOT/tests/fixtures/summary_voicecall_request.json" \
  --response "$ROOT/tests/fixtures/summary_voicecall_response.json" \
  --out "$tmp/voice.txt"
cat "$tmp/voice.txt"
grep -q "VoiceCall" "$tmp/voice.txt"
grep -q "Direct links between starting numbers" "$tmp/voice.txt"
grep -q "201111111111 -> 201222222222" "$tmp/voice.txt"
grep -q "201999999999" "$tmp/voice.txt"

echo "=== wrapper --response path ==="
"$ROOT/glc_graph_summary.sh" \
  -i "$ROOT/tests/fixtures/summary_voicecall_request.json" \
  --response "$ROOT/tests/fixtures/summary_voicecall_response.json" \
  -o "$tmp/wrap.txt" \
  -d "$tmp/run" \
  > "$tmp/stdout.txt"
grep -q "VoiceCall" "$tmp/stdout.txt"
grep -q "VoiceCall" "$tmp/wrap.txt"

echo "=== GUI JS summarizer vs Python ==="
chmod 775 "$ROOT/tests/run_gui_summary_test.sh"
"$ROOT/tests/run_gui_summary_test.sh"

echo "summary_tests_ok"
