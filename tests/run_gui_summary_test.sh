#!/bin/bash
# Compare the GUI JS summarizer with the Python report (same fixtures).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node_summarize() {
  local req="$1"
  local resp="$2"
  local out="$3"
  node -e '
    const fs = require("fs");
    const api = require(process.argv[1]);
    const req = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const data = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
    process.stdout.write(api.buildSummary(req, data));
  ' "$ROOT/custom-glc-summary.js" "$req" "$resp" > "$out"
}

echo "=== JS vs Python line-status ==="
python3 "$ROOT/glc_graph_summary.py" summarize \
  --request "$ROOT/tests/fixtures/summary_line_status_request.json" \
  --response "$ROOT/tests/fixtures/summary_line_status_response.json" \
  --out "$tmp/py-line.txt"
node_summarize \
  "$ROOT/tests/fixtures/summary_line_status_request.json" \
  "$ROOT/tests/fixtures/summary_line_status_response.json" \
  "$tmp/js-line.txt"
diff -u "$tmp/py-line.txt" "$tmp/js-line.txt"

echo "=== JS vs Python voicecall ==="
python3 "$ROOT/glc_graph_summary.py" summarize \
  --request "$ROOT/tests/fixtures/summary_voicecall_request.json" \
  --response "$ROOT/tests/fixtures/summary_voicecall_response.json" \
  --out "$tmp/py-voice.txt"
node_summarize \
  "$ROOT/tests/fixtures/summary_voicecall_request.json" \
  "$ROOT/tests/fixtures/summary_voicecall_response.json" \
  "$tmp/js-voice.txt"
diff -u "$tmp/py-voice.txt" "$tmp/js-voice.txt"

echo "=== parseRequestBody FormData-like JSON string ==="
node -e '
  const api = require(process.argv[1]);
  const body = JSON.stringify({
    graphDepth: 1,
    dateFrom: "2026/07/15 00:00:00",
    dateTo: "2026/09/01 23:59:59",
    nodesToSearch: [{ id: "1", nodeType: "1", nodes: "201000000001", text: "MSISDN" }]
  });
  const req = api.parseRequestBody(body);
  if (!req.nodes || req.nodes[0].nodes !== "201000000001") {
    throw new Error("nodesToSearch not parsed: " + JSON.stringify(req));
  }
  if (!api.isSearchUrl("/graphviewer/service/search/searchByNodes")) {
    throw new Error("search URL not detected");
  }
  console.log("parseRequestBody_ok");
' "$ROOT/custom-glc-summary.js"

echo "=== empty / json XHR body handling ==="
node -e '
  const api = require(process.argv[1]);
  if (api.parseGraphResponse("") !== null) throw new Error("empty string should not throw");
  if (api.parseGraphResponse("   ") !== null) throw new Error("blank string should not throw");
  const obj = { responseCode: 0, vertices: [{ nodeName: "1" }], edges: [] };
  const parsed = api.parseGraphResponse(JSON.stringify(obj));
  if (!parsed.vertices || parsed.vertices.length !== 1) throw new Error("string JSON not parsed");
  const already = api.parseGraphResponse(obj);
  if (already !== obj && already.vertices[0].nodeName !== "1") throw new Error("object passthrough failed");
  const wrapped = api.parseGraphResponse({ data: obj });
  if (!wrapped.vertices) throw new Error("wrapped data.vertices not unwrapped");
  const xhrJson = { responseType: "json", response: obj, responseText: "" };
  const raw = api.readXhrBody(xhrJson);
  if (!raw || !raw.vertices) throw new Error("readXhrBody missed json response object");
  if (!api.looksLikeGraph(obj)) throw new Error("looksLikeGraph failed");
  console.log("xhr_body_ok");
' "$ROOT/custom-glc-summary.js" 

echo "gui_summary_tests_ok"
