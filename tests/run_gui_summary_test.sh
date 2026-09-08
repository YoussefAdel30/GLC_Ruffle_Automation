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

echo "=== JS vs Python user-owns (real GLC shape) ==="
python3 "$ROOT/glc_graph_summary.py" summarize \
  --request "$ROOT/tests/fixtures/summary_user_owns_request.json" \
  --response "$ROOT/tests/fixtures/summary_user_owns_response.json" \
  --out "$tmp/py-owns.txt"
node_summarize \
  "$ROOT/tests/fixtures/summary_user_owns_request.json" \
  "$ROOT/tests/fixtures/summary_user_owns_response.json" \
  "$tmp/js-owns.txt"
diff -u "$tmp/py-owns.txt" "$tmp/js-owns.txt"
grep -F "Owns" "$tmp/js-owns.txt"
grep -F "ADELY1" "$tmp/js-owns.txt"
grep -F "201066257228" "$tmp/js-owns.txt"
grep -F "8 Sep 2026" "$tmp/js-owns.txt"
grep -F "2 nodes, 1 links" "$tmp/js-owns.txt"
if grep -q "%2F" "$tmp/js-owns.txt"; then
  echo "dates still URL-encoded" >&2
  exit 1
fi
if grep -q "GLC network report" "$tmp/js-owns.txt"; then
  echo "report banner title still present" >&2
  exit 1
fi
if grep -qE '^={10,}$' "$tmp/js-owns.txt"; then
  echo "report equals-line banner still present" >&2
  exit 1
fi

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
  if (api.looksLikeGraph({ vertices: [], edges: [{ id: 1 }] })) {
    throw new Error("empty vertices should not look like a graph");
  }
  if (api.looksLikeGraph({ vertices: [], edges: [], nodeTypes: [{ id: 1 }, { id: 1001 }] })) {
    throw new Error("nodeTypes catalog must not count as a graph");
  }
  if (api.looksLikeGraph({ vertices: [], edges: [{ id: "13_x" }], nodeTypes: [{ id: 1 }], responseCode: 0 })) {
    throw new Error("edges without vertices must not count as a graph");
  }
  const emptySearch = { responseCode: 0, vertices: [], edges: [], nodeTypes: [{ id: 1 }] };
  if (api.looksLikeGraph(emptySearch)) {
    throw new Error("empty search result is not a populated graph");
  }
  if (!api.isEmptySearchResult(emptySearch)) {
    throw new Error("empty HTTP search result not detected");
  }
  if (api.formatPeriod("2026%2F09%2F08%2000%3A00%3A00") !== "8 Sep 2026, 00:00:00") {
    throw new Error("formatPeriod failed: " + api.formatPeriod("2026%2F09%2F08%2000%3A00%3A00"));
  }
  if (api.formatPeriod("2026/09/08 23:59:59") !== "8 Sep 2026, 23:59:59") {
    throw new Error("formatPeriod plain date failed");
  }
  const objReq = api.parseRequestBody({
    graphDepth: 1,
    dateFrom: "2026%2F09%2F08%2000%3A00%3A00",
    nodesToSearch: [{ id: "1", nodeType: "1", nodes: "201066257228", text: "MSISDN" }]
  });
  if (!objReq.nodes || objReq.nodes[0].nodes !== "201066257228") {
    throw new Error("object request body not parsed: " + JSON.stringify(objReq));
  }
  if (api.formatPeriod(objReq.dateFrom) !== "8 Sep 2026, 00:00:00") {
    throw new Error("object request date not decoded");
  }
  const nested = api.findGraphIn({
    status: 200,
    body: { responseCode: 0, vertices: [{ nodeName: "201", nodeTypeId: 1 }], edges: [] }
  });
  if (!nested || nested.vertices[0].nodeName !== "201") throw new Error("findGraphIn missed nested body");
  const cyJson = api.parseGraphResponse({
    elements: {
      nodes: [{ data: { id: "1_201000000001", nodeName: "201000000001", nodeTypeId: 1 } }],
      edges: [{ data: { source: "201000000001", target: "Active", linkType: { linkTypeName: "MSISDN-Line Status" } } }]
    }
  });
  if (!cyJson || cyJson.vertices[0].nodeName !== "201000000001") {
    throw new Error("cytoscape json not converted: " + JSON.stringify(cyJson));
  }
  const ownsCy = api.graphFromCyJson({
    elements: {
      nodes: [
        { data: { id: "1001_ADELY1", nodeName: "ADELY1", nodeTypeId: 1001, nodeType: { nodeTypeName: "User" } } },
        { data: { id: "1_201066257228", nodeName: "201066257228", nodeTypeId: 1, nodeType: { nodeTypeName: "MSISDN" } } }
      ],
      edges: [{
        data: {
          source: "1001_ADELY1",
          target: "1_201066257228",
          linkType: { linkTypeId: 13, linkTypeName: "MSISDN-User", alias: "Owns" }
        }
      }]
    }
  });
  if (!ownsCy || ownsCy.vertices.length !== 2 || ownsCy.edges.length !== 1) {
    throw new Error("owns cytoscape not converted: " + JSON.stringify(ownsCy));
  }
  if (ownsCy.edges[0].nodeA.nodeName !== "ADELY1" || ownsCy.edges[0].nodeB.nodeName !== "201066257228") {
    throw new Error("owns cytoscape endpoints missing: " + JSON.stringify(ownsCy.edges[0]));
  }
  const ownsFp = api.graphFingerprint({
    vertices: [
      { nodeName: "ADELY1", nodeTypeId: 1001 },
      { nodeName: "201066257228", nodeTypeId: 1 }
    ],
    edges: [{
      linkTypeID: 13,
      nodeA: { nodeName: "ADELY1", nodeTypeId: 1001 },
      nodeB: { nodeName: "201066257228", nodeTypeId: 1 }
    }]
  });
  const voiceFp = api.graphFingerprint({
    vertices: [
      { nodeName: "201066257228", nodeTypeId: 1 },
      { nodeName: "20100130105", nodeTypeId: 1 }
    ],
    edges: [{
      linkTypeID: 7,
      nodeA: { nodeName: "201066257228", nodeTypeId: 1 },
      nodeB: { nodeName: "20100130105", nodeTypeId: 1 }
    }]
  });
  if (!ownsFp || ownsFp === voiceFp) {
    throw new Error("search fingerprints should differ: " + ownsFp + " vs " + voiceFp);
  }
  const ownsFp2 = api.graphFingerprint({
    vertices: [
      { nodeName: "201066257228", nodeTypeId: 1 },
      { nodeName: "ADELY1", nodeTypeId: 1001 }
    ],
    edges: [{
      linkTypeID: 13,
      nodeA: { nodeName: "ADELY1", nodeTypeId: 1 },
      nodeB: { nodeName: "201066257228", nodeTypeId: 1 }
    }]
  });
  if (ownsFp2.split("||")[0] !== ownsFp.split("||")[0]) {
    throw new Error("fingerprint should not depend on vertex order");
  }
  console.log("xhr_body_ok");
' "$ROOT/custom-glc-summary.js" 

echo "gui_summary_tests_ok"
