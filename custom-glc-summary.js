/**
 * GLC search report for ERM Link Analysis.
 *
 * Same injection style as custom-delete.js. No Python, no files, no extra login.
 * Hooks the real Ok button (capture phase) so a normal search also captures
 * the searchByNodes response and shows the business report in a dock.
 *
 * Install (extracted webgui.war / @app):
 *   1. Copy this file to:  webgui/@app/custom-glc-summary.js
 *   2. In webgui/@app/index.html, next to custom-delete.js, add:
 *        <script src="/erm/@app/custom-glc-summary.js" defer></script>
 *   3. Repack war/ear, redeploy to JBoss, hard-refresh the browser.
 *
 * Page: /erm/@app/erm/case-manager/linkanalysis
 */
(function (root) {
  "use strict";

  var MSISDN_TYPE_ID = 1;
  var USER_TYPE_ID = 1001;
  var DEVICE_TYPE_ID = 1000;
  var ID_TYPE_ID = 1003;
  var WALLET_PROFILE_TYPE_ID = 1321;
  var WALLET_STATUS_TYPE_ID = 1141;
  var LINE_STATUS_TYPE_ID = 1160;
  var VALUE_TYPE_IDS = {};
  VALUE_TYPE_IDS[WALLET_PROFILE_TYPE_ID] = 1;
  VALUE_TYPE_IDS[WALLET_STATUS_TYPE_ID] = 1;
  VALUE_TYPE_IDS[LINE_STATUS_TYPE_ID] = 1;
  var IDENTITY_TYPE_IDS = {};
  IDENTITY_TYPE_IDS[MSISDN_TYPE_ID] = 1;
  IDENTITY_TYPE_IDS[DEVICE_TYPE_ID] = 1;
  IDENTITY_TYPE_IDS[USER_TYPE_ID] = 1;
  IDENTITY_TYPE_IDS[ID_TYPE_ID] = 1;
  var TOP_N_DEFAULT = 8;
  var SEARCH_MARK = "searchByNodes";
  var WAIT_MS = 20 * 60 * 1000;
  var GENERIC_ALIAS = { "": 1, has: 1, "has a": 1, contains: 1, is: 1, of: 1 };

  function toInt(value, fallback) {
    if (value === null || value === undefined || value === "") return fallback;
    var n = parseInt(value, 10);
    return isNaN(n) ? fallback : n;
  }

  function splitBr(text) {
    return String(text || "").split(/<br\s*\/?>/i);
  }

  function nodeTypeId(node) {
    if (!node) return null;
    if (node.nodeTypeId !== undefined && node.nodeTypeId !== null && node.nodeTypeId !== "") {
      var direct = toInt(node.nodeTypeId, null);
      if (direct !== null) return direct;
    }
    var nt = node.nodeType || {};
    var keys = ["nodeTypeId", "id"];
    for (var i = 0; i < keys.length; i++) {
      if (nt[keys[i]] !== undefined && nt[keys[i]] !== null && nt[keys[i]] !== "") {
        var parsed = toInt(nt[keys[i]], null);
        if (parsed !== null) return parsed;
      }
    }
    return null;
  }

  function knownTypeName(typeId) {
    var names = {};
    names[MSISDN_TYPE_ID] = "MSISDN";
    names[DEVICE_TYPE_ID] = "Device";
    names[USER_TYPE_ID] = "User";
    names[ID_TYPE_ID] = "ID";
    names[WALLET_STATUS_TYPE_ID] = "Wallet Status";
    names[LINE_STATUS_TYPE_ID] = "Line Status";
    names[WALLET_PROFILE_TYPE_ID] = "Wallet Profile";
    if (Object.prototype.hasOwnProperty.call(names, typeId)) return names[typeId];
    return "type-" + typeId;
  }

  function nodeTypeName(node) {
    if (!node) return "Unknown";
    var nt = node.nodeType || {};
    if (nt.nodeTypeName) return String(nt.nodeTypeName).trim();
    return knownTypeName(nodeTypeId(node));
  }

  function nodeName(node) {
    if (!node) return "";
    var keys = ["nodeName", "label"];
    for (var i = 0; i < keys.length; i++) {
      if (node[keys[i]] !== undefined && node[keys[i]] !== null && node[keys[i]] !== "") {
        return String(node[keys[i]]).trim();
      }
    }
    var nodeId = node.nodeId || node.id || "";
    if (typeof nodeId === "string" && nodeId.indexOf("_") >= 0) {
      return nodeId.split("_").slice(1).join("_").trim();
    }
    return String(nodeId).trim();
  }

  function shortName(value, limit) {
    limit = limit || 48;
    var text = splitBr(value)[0].trim();
    if (text.length <= limit) return text;
    return text.slice(0, limit - 3) + "...";
  }

  function lineStatusParts(value) {
    var text = String(value || "").replace(/\r/g, "").trim();
    if (!text) return ["", ""];
    var head = splitBr(text)[0].trim();
    var idx = head.indexOf("_");
    if (idx >= 0) return [head.slice(0, idx).trim(), head.slice(idx + 1).trim()];
    return [head, ""];
  }

  function requestInputs(req) {
    var groups = [];
    if (!req) return groups;
    var list = req.nodes || [];
    for (var i = 0; i < list.length; i++) {
      var group = list[i] || {};
      var typeId = toInt(group.nodeType || group.id, MSISDN_TYPE_ID);
      var values = [];
      var seen = {};
      var raw = String(group.nodes || "").replace(/\r/g, "\n").split("\n");
      for (var j = 0; j < raw.length; j++) {
        var item = raw[j].trim();
        if (item && !seen[item]) {
          seen[item] = 1;
          values.push(item);
        }
      }
      groups.push({
        type_id: typeId,
        type_name: group.text || knownTypeName(typeId),
        values: values
      });
    }
    return groups;
  }

  function inputNameSet(groups) {
    var names = {};
    for (var i = 0; i < groups.length; i++) {
      var vals = groups[i].values || [];
      for (var j = 0; j < vals.length; j++) names[vals[j]] = 1;
    }
    return names;
  }

  function vertices(data) {
    return (data && data.vertices) || [];
  }

  function edges(data) {
    return (data && data.edges) || [];
  }

  function edgeCount(edge) {
    var info = (edge && edge.edgeInfo) || {};
    var n = toInt(info.totalCount, 1);
    return n > 0 ? n : 1;
  }

  function linkMeta(edge) {
    var lt = (edge && edge.linkType) || {};
    var lid = edge.linkTypeID || edge.linkTypeId || lt.linkTypeId || lt.id;
    lid = toInt(lid, lid || 0);
    var name = lt.linkTypeName || lt.alias || ("link-" + lid);
    var alias = lt.alias || "";
    return [lid, String(name), String(alias)];
  }

  function directedNames(edge) {
    var nodeA = edge.nodeA;
    var nodeB = edge.nodeB;
    var direction = toInt(edge.direction, 1);
    if (direction === 2) {
      return [nodeName(nodeB), nodeName(nodeA), nodeTypeId(nodeB), nodeTypeId(nodeA)];
    }
    return [nodeName(nodeA), nodeName(nodeB), nodeTypeId(nodeA), nodeTypeId(nodeB)];
  }

  function classifyLink(typeA, typeB, uniqueDest, nEdges) {
    if (typeA === typeB) return "peer";
    if (VALUE_TYPE_IDS[typeB] || VALUE_TYPE_IDS[typeA]) return "value";
    if (
      !IDENTITY_TYPE_IDS[typeB] &&
      uniqueDest &&
      uniqueDest <= 25 &&
      uniqueDest * 3 < Math.max(nEdges, 1)
    ) {
      return "value";
    }
    return "identity";
  }

  function mostCommon(counter) {
    var items = [];
    for (var key in counter) {
      if (Object.prototype.hasOwnProperty.call(counter, key)) {
        items.push([key, counter[key]]);
      }
    }
    items.sort(function (a, b) {
      if (b[1] !== a[1]) return b[1] - a[1];
      if (a[0] < b[0]) return -1;
      if (a[0] > b[0]) return 1;
      return 0;
    });
    return items;
  }

  function topItems(counter, topN) {
    var items = mostCommon(counter);
    var shown = items.slice(0, topN);
    var rest = items.slice(topN);
    var restN = 0;
    for (var i = 0; i < rest.length; i++) restN += rest[i][1];
    return [shown, rest.length, restN];
  }

  function fmtCounts(pairs) {
    var parts = [];
    for (var i = 0; i < pairs.length; i++) {
      parts.push(pairs[i][1] + " " + shortName(pairs[i][0]));
    }
    if (!parts.length) return "";
    if (parts.length === 1) return parts[0];
    if (parts.length === 2) return parts[0] + " and " + parts[1];
    return parts.slice(0, -1).join(", ") + ", and " + parts[parts.length - 1];
  }

  function friendlyLinkName(name, alias) {
    alias = String(alias || "").trim();
    if (alias && !GENERIC_ALIAS[alias.toLowerCase()]) return alias;
    return name || "Link";
  }

  function coverageLine(linked, total) {
    if (!total) return "  No starting numbers were given.";
    if (linked === total) return "  All " + total + " starting numbers have this link.";
    if (linked === 0) return "  None of the " + total + " starting numbers have this link.";
    return "  " + linked + " of " + total + " starting numbers have this link.";
  }

  function pairWord(n) {
    return n === 1 ? "pair" : "pairs";
  }

  function addCount(counter, key, n) {
    n = n === undefined ? 1 : n;
    counter[key] = (counter[key] || 0) + n;
  }

  function nameSetSize(obj) {
    var n = 0;
    for (var k in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, k)) n++;
    }
    return n;
  }

  function sortedKeys(obj) {
    var keys = [];
    for (var k in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, k)) keys.push(k);
    }
    keys.sort();
    return keys;
  }

  function censusNodes(data, inputNames) {
    var byType = {};
    var vertsAll = vertices(data);
    for (var i = 0; i < vertsAll.length; i++) {
      var v = vertsAll[i];
      var tid = nodeTypeId(v);
      var key = String(tid);
      if (!byType[key]) byType[key] = [];
      byType[key].push(v);
    }
    var rows = [];
    for (var tkey in byType) {
      if (!Object.prototype.hasOwnProperty.call(byType, tkey)) continue;
      var verts = byType[tkey];
      var tidNum = nodeTypeId(verts[0]);
      var names = [];
      var roots = 0;
      var inInput = 0;
      var isolated = 0;
      for (var j = 0; j < verts.length; j++) {
        var nm = nodeName(verts[j]);
        names.push(nm);
        if (verts[j].root || verts[j].highlight) roots++;
        if (inputNames[nm]) inInput++;
        if (toInt(verts[j].neighboursCount, 0) === 0) isolated++;
      }
      rows.push({
        type_id: tidNum,
        type_name: nodeTypeName(verts[0]),
        count: verts.length,
        roots: roots,
        in_input: inInput,
        isolated: isolated,
        names: names
      });
    }
    rows.sort(function (a, b) {
      if (b.count !== a.count) return b.count - a.count;
      return (a.type_id || 0) - (b.type_id || 0);
    });
    return rows;
  }

  function groupEdges(data) {
    var groups = {};
    var order = [];
    var list = edges(data);
    for (var i = 0; i < list.length; i++) {
      var meta = linkMeta(list[i]);
      var key = meta[0] + "\0" + meta[1] + "\0" + meta[2];
      if (!groups[key]) {
        groups[key] = { lid: meta[0], name: meta[1], alias: meta[2], edges: [] };
        order.push(key);
      }
      groups[key].edges.push(list[i]);
    }
    order.sort(function (a, b) {
      if (groups[b].edges.length !== groups[a].edges.length) {
        return groups[b].edges.length - groups[a].edges.length;
      }
      if (groups[a].name < groups[b].name) return -1;
      if (groups[a].name > groups[b].name) return 1;
      return 0;
    });
    return order.map(function (k) {
      return groups[k];
    });
  }

  function summarizeValueLink(kindEdges, inputNames, topN) {
    var valueCounter = {};
    var statusCounter = {};
    var reasonCounter = {};
    var linkedInputs = {};
    var destIsLine = false;
    var destTypeName = "value";
    var rawDests = {};
    var parsedCombos = {};
    for (var i = 0; i < kindEdges.length; i++) {
      var parts = directedNames(kindEdges[i]);
      var src = parts[0];
      var dst = parts[1];
      var typeSrc = parts[2];
      var typeDst = parts[3];
      if (VALUE_TYPE_IDS[typeSrc] && !VALUE_TYPE_IDS[typeDst]) {
        var tmpS = src;
        src = dst;
        dst = tmpS;
        var tmpT = typeSrc;
        typeSrc = typeDst;
        typeDst = tmpT;
      }
      destTypeName = knownTypeName(typeDst);
      rawDests[dst] = 1;
      if (typeDst === LINE_STATUS_TYPE_ID) {
        destIsLine = true;
        var statusReason = lineStatusParts(dst);
        var status = statusReason[0];
        var reason = statusReason[1];
        var label = status || dst;
        addCount(valueCounter, label);
        if (status) addCount(statusCounter, status);
        if (reason) addCount(reasonCounter, reason);
        parsedCombos[JSON.stringify([status || dst, reason])] = 1;
      } else {
        addCount(valueCounter, dst);
        parsedCombos[JSON.stringify([dst, ""])] = 1;
      }
      if (inputNames[src]) linkedInputs[src] = 1;
    }
    var lines = [];
    var shownPack = topItems(valueCounter, topN);
    if (destIsLine && nameSetSize(statusCounter)) {
      var shownS = topItems(statusCounter, topN);
      lines.push(
        "  Status: " +
          fmtCounts(shownS[0]) +
          (shownS[1] ? " and " + shownS[1] + " more" : "") +
          "."
      );
      if (nameSetSize(reasonCounter)) {
        var shownR = topItems(reasonCounter, topN);
        lines.push(
          "  Suspension reasons: " +
            fmtCounts(shownR[0]) +
            (shownR[1] ? " and " + shownR[1] + " more reasons" : "") +
            "."
        );
      }
      lines.push(
        "  There are " +
          nameSetSize(rawDests) +
          " different " +
          destTypeName +
          " nodes. The time on a Suspended label makes each one a separate node."
      );
      lines.push(
        "  If we ignore the time, there are " +
          nameSetSize(parsedCombos) +
          " different statuses."
      );
    } else {
      lines.push(
        "  Values: " +
          fmtCounts(shownPack[0]) +
          (shownPack[1] ? " and " + shownPack[1] + " more (" + shownPack[2] + " links)" : "") +
          "."
      );
      if (nameSetSize(rawDests)) {
        lines.push("  There are " + nameSetSize(rawDests) + " different " + destTypeName + " nodes.");
      }
    }
    if (nameSetSize(inputNames)) {
      lines.push(coverageLine(nameSetSize(linkedInputs), nameSetSize(inputNames)));
    }
    return lines;
  }

  function summarizeIdentityLink(kindEdges, inputNames, topN) {
    var shared = {};
    var linkedInputs = {};
    for (var i = 0; i < kindEdges.length; i++) {
      var parts = directedNames(kindEdges[i]);
      var src = parts[0];
      var dst = parts[1];
      if (inputNames[src]) {
        linkedInputs[src] = 1;
        if (!shared[dst]) shared[dst] = {};
        shared[dst][src] = 1;
      }
      if (inputNames[dst]) {
        linkedInputs[dst] = 1;
        if (!shared[src]) shared[src] = {};
        shared[src][dst] = 1;
      }
    }
    var lines = [coverageLine(nameSetSize(linkedInputs), nameSetSize(inputNames))];
    var common = [];
    for (var name in shared) {
      if (!Object.prototype.hasOwnProperty.call(shared, name)) continue;
      if (inputNames[name]) continue;
      var members = sortedKeys(shared[name]);
      if (members.length >= 2) common.push([name, members]);
    }
    common.sort(function (a, b) {
      if (b[1].length !== a[1].length) return b[1].length - a[1].length;
      if (a[0] < b[0]) return -1;
      if (a[0] > b[0]) return 1;
      return 0;
    });
    if (common.length) {
      lines.push("  Shared nodes (linked to 2 or more starting numbers):");
      for (var c = 0; c < Math.min(topN, common.length); c++) {
        var preview = common[c][1].slice(0, 6).join(", ");
        if (common[c][1].length > 6) preview += ", ...";
        lines.push(
          "    " +
            shortName(common[c][0]) +
            " is linked to " +
            common[c][1].length +
            " starting numbers (" +
            preview +
            ")."
        );
      }
      if (common.length > topN) {
        lines.push("    ... and " + (common.length - topN) + " more shared nodes.");
      }
    } else {
      lines.push("  No node is shared by two or more starting numbers.");
    }
    var isolated = [];
    var allInputs = sortedKeys(inputNames);
    for (var x = 0; x < allInputs.length; x++) {
      if (!linkedInputs[allInputs[x]]) isolated.push(allInputs[x]);
    }
    if (isolated.length) {
      var isoPreview = isolated.slice(0, topN).join(", ");
      var extra = isolated.length <= topN ? "" : " and " + (isolated.length - topN) + " more";
      lines.push("  Starting numbers with no link of this kind: " + isoPreview + extra + ".");
    }
    return lines;
  }

  function summarizePeerLink(kindEdges, inputNames, topN) {
    var direct = [];
    var linkedInputs = {};
    var neighborToInputs = {};
    for (var i = 0; i < kindEdges.length; i++) {
      var parts = directedNames(kindEdges[i]);
      var src = parts[0];
      var dst = parts[1];
      var n = edgeCount(kindEdges[i]);
      var srcIn = !!inputNames[src];
      var dstIn = !!inputNames[dst];
      if (srcIn) linkedInputs[src] = 1;
      if (dstIn) linkedInputs[dst] = 1;
      if (srcIn && dstIn) {
        direct.push([src, dst, n]);
      } else if (srcIn && !dstIn) {
        if (!neighborToInputs[dst]) neighborToInputs[dst] = {};
        neighborToInputs[dst][src] = 1;
      } else if (dstIn && !srcIn) {
        if (!neighborToInputs[src]) neighborToInputs[src] = {};
        neighborToInputs[src][dst] = 1;
      } else {
        if (srcIn) {
          if (!neighborToInputs[dst]) neighborToInputs[dst] = {};
          neighborToInputs[dst][src] = 1;
        }
        if (dstIn) {
          if (!neighborToInputs[src]) neighborToInputs[src] = {};
          neighborToInputs[src][dst] = 1;
        }
      }
    }
    var total = nameSetSize(inputNames);
    var linked = nameSetSize(linkedInputs);
    var lines;
    if (!total) lines = ["  No starting numbers were given."];
    else if (linked === total) lines = ["  All " + total + " starting numbers appear in these links."];
    else if (linked === 0) lines = ["  None of the " + total + " starting numbers appear in these links."];
    else lines = ["  " + linked + " of " + total + " starting numbers appear in these links."];

    if (direct.length) {
      direct.sort(function (a, b) {
        if (b[2] !== a[2]) return b[2] - a[2];
        if (a[0] !== b[0]) return a[0] < b[0] ? -1 : 1;
        if (a[1] < b[1]) return -1;
        if (a[1] > b[1]) return 1;
        return 0;
      });
      lines.push("  Direct links between starting numbers: " + direct.length + " " + pairWord(direct.length) + ".");
      for (var d = 0; d < Math.min(topN, direct.length); d++) {
        var extra = direct[d][2] > 1 ? " (" + direct[d][2] + " times)" : "";
        lines.push("    " + direct[d][0] + " -> " + direct[d][1] + extra);
      }
      if (direct.length > topN) {
        lines.push("    ... and " + (direct.length - topN) + " more direct pairs.");
      }
    } else {
      lines.push("  No direct links between the starting numbers.");
    }

    var common = [];
    for (var name in neighborToInputs) {
      if (!Object.prototype.hasOwnProperty.call(neighborToInputs, name)) continue;
      var members = sortedKeys(neighborToInputs[name]);
      if (members.length >= 2) common.push([name, members]);
    }
    common.sort(function (a, b) {
      if (b[1].length !== a[1].length) return b[1].length - a[1].length;
      if (a[0] < b[0]) return -1;
      if (a[0] > b[0]) return 1;
      return 0;
    });
    if (common.length) {
      lines.push("  Shared outside numbers (2 or more starting numbers link to the same number):");
      for (var c = 0; c < Math.min(topN, common.length); c++) {
        var preview = common[c][1].slice(0, 6).join(", ");
        if (common[c][1].length > 6) preview += ", ...";
        lines.push(
          "    " +
            shortName(common[c][0]) +
            " is linked to " +
            common[c][1].length +
            " starting numbers (" +
            preview +
            ")."
        );
      }
      if (common.length > topN) {
        lines.push("    ... and " + (common.length - topN) + " more shared numbers.");
      }
    } else {
      lines.push("  No shared outside numbers among the starting list.");
    }

    var isolated = [];
    var allInputs = sortedKeys(inputNames);
    for (var x = 0; x < allInputs.length; x++) {
      if (!linkedInputs[allInputs[x]]) isolated.push(allInputs[x]);
    }
    if (isolated.length) {
      var isoPreview = isolated.slice(0, topN).join(", ");
      var extraIso = isolated.length <= topN ? "" : " and " + (isolated.length - topN) + " more";
      lines.push("  Starting numbers with no link of this kind: " + isoPreview + extraIso + ".");
    }
    return lines;
  }

  function buildSummary(req, data, topN) {
    req = req || {};
    data = data || {};
    topN = topN || TOP_N_DEFAULT;
    var groups = requestInputs(req);
    var inputNames = inputNameSet(groups);
    if (!nameSetSize(inputNames)) {
      var verts = vertices(data);
      for (var i = 0; i < verts.length; i++) {
        if (verts[i].root || verts[i].highlight) inputNames[nodeName(verts[i])] = 1;
      }
    }

    var lines = [];

    var dateFrom = formatPeriod(req.dateFrom || "");
    var dateTo = formatPeriod(req.dateTo || "");
    var depthN = toInt(req.graphDepth, null);
    if (dateFrom || dateTo) lines.push("Period: " + dateFrom + " to " + dateTo);
    if (depthN === 1) {
      lines.push("Scope: direct links only (one step from the starting list).");
    } else if (depthN) {
      lines.push("Scope: up to " + depthN + " steps from the starting list.");
    }
    if (groups.length) {
      for (var g = 0; g < groups.length; g++) {
        var preview = groups[g].values.slice(0, 8).join(", ");
        var extra = groups[g].values.length > 8 ? ", ... (" + groups[g].values.length + " in total)" : "";
        lines.push(
          "Starting " + groups[g].type_name + " list (" + groups[g].values.length + "): " + preview + extra
        );
      }
    } else if (nameSetSize(inputNames)) {
      var highlighted = sortedKeys(inputNames);
      extra = highlighted.length > 8 ? ", ... (" + highlighted.length + " in total)" : "";
      lines.push(
        "Starting list from the graph (" + highlighted.length + "): " +
          highlighted.slice(0, 8).join(", ") + extra
      );
    } else {
      lines.push("Starting list: none in the request; using highlighted nodes from the result.");
    }
    lines.push("");

    var code = data.responseCode;
    var warn = data.warningMsg;
    var nNodes = vertices(data).length;
    var nLinks = edges(data).length;
    var result = code === 0 || code === "0" || code === undefined || code === null ? "OK" : "not OK (code " + code + ")";
    var resultLine = "Result: " + result + ". " + nNodes + " nodes, " + nLinks + " links.";
    if (warn) resultLine += " Note: " + warn;
    lines.push(resultLine);
    if (!nNodes && !nLinks) {
      lines.push("");
      lines.push("This search returned no nodes and no links.");
      return lines.join("\n") + "\n";
    }

    lines.push("");
    lines.push("----- NODES -----");
    var rows = censusNodes(data, inputNames);
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r];
      var bits = [];
      if (row.in_input && row.in_input === row.count) {
        bits.push("all " + row.in_input + " were in the starting list");
      } else if (row.in_input) {
        bits.push(row.in_input + " were in the starting list");
      }
      var extraNodes = row.count - row.in_input;
      if (extraNodes > 0 && !VALUE_TYPE_IDS[row.type_id]) bits.push(extraNodes + " extra");
      if (row.isolated) bits.push(row.isolated + " with no links");
      var suffix = bits.length ? " (" + bits.join(", ") + ")" : "";
      var namesBit = "";
      if (
        !VALUE_TYPE_IDS[row.type_id] &&
        row.type_id !== MSISDN_TYPE_ID &&
        row.count <= 8 &&
        row.names &&
        row.names.length
      ) {
        namesBit = ": " + row.names.join(", ");
      }
      lines.push(row.count + " " + row.type_name + " nodes" + suffix + namesBit + ".");
      if (row.type_id === LINE_STATUS_TYPE_ID) {
        lines.push(
          "  These are status labels, not one node per number. If several numbers are Active, they share one Active node. If numbers are Suspended at different times, each time is a separate node."
        );
      } else if (VALUE_TYPE_IDS[row.type_id]) {
        lines.push(
          "  These are shared labels, not one node per number. Several numbers can share the same " +
            row.type_name +
            " node."
        );
      }
    }

    var edgeGroups = groupEdges(data);
    lines.push("");
    lines.push("----- LINKS -----");
    if (!edgeGroups.length) lines.push("There are no links in this result.");
    for (var e = 0; e < edgeGroups.length; e++) {
      var grp = edgeGroups[e];
      var typePairs = {};
      var destNames = {};
      for (var k = 0; k < grp.edges.length; k++) {
        var dn = directedNames(grp.edges[k]);
        addCount(typePairs, String(dn[2]) + "\t" + String(dn[3]));
        destNames[dn[1]] = 1;
      }
      var topPair = mostCommon(typePairs)[0][0].split("\t");
      var ta = topPair[0] === "null" || topPair[0] === "undefined" ? null : toInt(topPair[0], topPair[0]);
      var tb = topPair[1] === "null" || topPair[1] === "undefined" ? null : toInt(topPair[1], topPair[1]);
      var kind = classifyLink(ta, tb, nameSetSize(destNames), grp.edges.length);
      var title = friendlyLinkName(grp.name, grp.alias);
      var nKind = grp.edges.length;
      var linkWord = nKind === 1 ? "link" : "links";
      lines.push("");
      lines.push(title);
      lines.push("  " + nKind + " " + linkWord + " from " + knownTypeName(ta) + " to " + knownTypeName(tb) + ".");
      if (kind === "value") lines = lines.concat(summarizeValueLink(grp.edges, inputNames, topN));
      else if (kind === "peer") lines = lines.concat(summarizePeerLink(grp.edges, inputNames, topN));
      else lines = lines.concat(summarizeIdentityLink(grp.edges, inputNames, topN));
    }

    return lines.join("\n") + "\n";
  }

  function vertexLooksReal(v) {
    if (!v || typeof v !== "object") return false;
    return !!(v.nodeName || v.label || v.nodeId || v.nodeTypeId || v.nodeType);
  }

  function looksLikeGraph(data) {
    if (!data || typeof data !== "object") return false;
    var verts = data.vertices;
    if (!Array.isArray(verts) || !verts.length) return false;
    for (var i = 0; i < verts.length; i++) {
      if (vertexLooksReal(verts[i])) return true;
    }
    return false;
  }

  function isEmptySearchResult(data) {
    if (!data || typeof data !== "object") return false;
    if (!Array.isArray(data.vertices) || data.vertices.length) return false;
    if (Array.isArray(data.edges) && data.edges.length) return false;
    return data.responseCode !== undefined && data.responseCode !== null;
  }

  function findGraphIn(obj, depth, seen) {
    depth = depth || 0;
    seen = seen || [];
    if (!obj || depth > 6 || seen.length > 500) return null;
    if (typeof obj === "string") {
      try {
        obj = JSON.parse(obj);
      } catch (err) {
        return null;
      }
    }
    if (typeof obj !== "object") return null;
    if (typeof Node !== "undefined" && obj instanceof Node) return null;
    if (seen.indexOf(obj) >= 0) return null;
    seen.push(obj);
    try {
      var parsed = parseGraphResponse(obj);
      if (looksLikeGraph(parsed)) return parsed;
    } catch (err) {
      /* continue */
    }
    if (looksLikeGraph(obj)) return obj;
    var keys;
    try {
      keys = Object.keys(obj);
    } catch (err2) {
      return null;
    }
    var prefer = [
      "vertices",
      "edges",
      "body",
      "data",
      "result",
      "graph",
      "graphData",
      "searchResult",
      "lastGraph",
      "cytoscapeData",
      "response"
    ];
    var i;
    for (i = 0; i < prefer.length; i++) {
      if (!Object.prototype.hasOwnProperty.call(obj, prefer[i])) continue;
      var hit = findGraphIn(obj[prefer[i]], depth + 1, seen);
      if (hit) return hit;
    }
    for (i = 0; i < keys.length && i < 80; i++) {
      var key = keys[i];
      var val;
      try {
        val = obj[key];
      } catch (err3) {
        continue;
      }
      if (!val || typeof val === "function") continue;
      var nested = findGraphIn(val, depth + 1, seen);
      if (nested) return nested;
    }
    return null;
  }

  function idTypeAndName(id) {
    var text = String(id == null ? "" : id);
    var m = text.match(/^(\d+)_(.+)$/);
    if (m) return { typeId: toInt(m[1], null), name: m[2] };
    return { typeId: null, name: text };
  }

  function asNodeRecord(d) {
    d = d || {};
    var inner = d.data && typeof d.data === "object" && !d.nodeName ? d.data : d;
    var parsed = idTypeAndName(inner.nodeId || inner.id || d.id);
    var name = inner.nodeName || inner.label || inner.name || d.nodeName || d.label || "";
    if (!name) name = parsed.name;
    return {
      nodeName: String(name || "").trim(),
      nodeTypeId:
        inner.nodeTypeId ||
        d.nodeTypeId ||
        (inner.nodeType && inner.nodeType.nodeTypeId) ||
        parsed.typeId,
      nodeType: inner.nodeType || d.nodeType,
      root: inner.root || d.root,
      highlight: inner.highlight || d.highlight,
      neighboursCount: inner.neighboursCount || d.neighboursCount
    };
  }

  function lookupNode(nodeById, id) {
    if (!nodeById || id == null || id === "") return null;
    return nodeById[id] || nodeById[String(id)] || null;
  }

  function asEdgeRecord(d, nodeById) {
    d = d || {};
    var inner = d.data && typeof d.data === "object" && !d.nodeA ? d.data : d;
    var src = inner.source || d.source;
    var tgt = inner.target || d.target;
    var nodeA = inner.nodeA || d.nodeA || lookupNode(nodeById, src);
    var nodeB = inner.nodeB || d.nodeB || lookupNode(nodeById, tgt);
    if (!nodeA || !nodeTypeId(nodeA)) {
      var srcBits = idTypeAndName(src);
      nodeA = nodeA || {};
      nodeA = {
        nodeName: nodeA.nodeName || nodeA.label || srcBits.name,
        nodeTypeId: nodeTypeId(nodeA) || inner.sourceTypeId || srcBits.typeId,
        nodeType: nodeA.nodeType
      };
    }
    if (!nodeB || !nodeTypeId(nodeB)) {
      var tgtBits = idTypeAndName(tgt);
      nodeB = nodeB || {};
      nodeB = {
        nodeName: nodeB.nodeName || nodeB.label || tgtBits.name,
        nodeTypeId: nodeTypeId(nodeB) || inner.targetTypeId || tgtBits.typeId,
        nodeType: nodeB.nodeType
      };
    }
    return {
      linkTypeID: inner.linkTypeID || inner.linkTypeId || (inner.linkType && inner.linkType.linkTypeId),
      linkType: inner.linkType || d.linkType,
      direction: inner.direction || d.direction,
      edgeInfo: inner.edgeInfo || d.edgeInfo,
      nodeA: nodeA,
      nodeB: nodeB
    };
  }

  function graphFromCyJson(data) {
    if (!data || typeof data !== "object") return null;
    var nodes = [];
    var links = [];
    if (data.elements) {
      if (Array.isArray(data.elements)) {
        for (var i = 0; i < data.elements.length; i++) {
          var el = data.elements[i] || {};
          var group = el.group || (el.data && el.data.source ? "edges" : "nodes");
          if (group === "edges" || group === "edge") links.push(el);
          else nodes.push(el);
        }
      } else {
        nodes = data.elements.nodes || [];
        links = data.elements.edges || [];
      }
    } else if (Array.isArray(data.nodes) || Array.isArray(data.edges)) {
      if (Array.isArray(data.vertices)) return null;
      nodes = data.nodes || [];
      links = data.edges || [];
    } else {
      return null;
    }
    if (!nodes.length) return null;
    var vertices = [];
    var edges = [];
    var nodeById = {};
    for (var n = 0; n < nodes.length; n++) {
      var rawNode = nodes[n] || {};
      var nodeData = rawNode.data || rawNode;
      var rec = asNodeRecord(nodeData);
      vertices.push(rec);
      var ids = [nodeData.id, nodeData.nodeId, rec.nodeName, rawNode.id];
      for (var ii = 0; ii < ids.length; ii++) {
        if (ids[ii] != null && ids[ii] !== "") nodeById[ids[ii]] = rec;
      }
    }
    for (var e = 0; e < links.length; e++) {
      edges.push(asEdgeRecord(links[e].data || links[e], nodeById));
    }
    return { responseCode: 0, vertices: vertices, edges: edges };
  }

  function graphFromCytoscape(cy) {
    if (!cy || typeof cy.nodes !== "function") return null;
    try {
      if (typeof cy.json === "function") {
        var mapped = graphFromCyJson(cy.json());
        if (mapped && looksLikeGraph(mapped)) return mapped;
      }
    } catch (err) {
      /* fall through to nodes()/edges() */
    }
    var vertices = [];
    var edges = [];
    var nodeById = {};
    try {
      cy.nodes().forEach(function (node) {
        var rec = asNodeRecord(node.data() || {});
        vertices.push(rec);
        try {
          if (node.id) nodeById[node.id()] = rec;
        } catch (errId) {
          /* ignore */
        }
        if (rec.nodeName) nodeById[rec.nodeName] = rec;
      });
      cy.edges().forEach(function (edge) {
        edges.push(asEdgeRecord(edge.data() || {}, nodeById));
      });
    } catch (err2) {
      return null;
    }
    if (!looksLikeGraph({ vertices: vertices, edges: edges })) return null;
    return { responseCode: 0, vertices: vertices, edges: edges };
  }

  function parseGraphResponse(raw) {
    var data = raw;
    if (data == null) return data;
    if (typeof data === "string") {
      var trimmed = data.replace(/^\uFEFF/, "").trim();
      if (!trimmed) return null;
      data = JSON.parse(trimmed);
    }
    if (typeof data !== "object") return data;
    if (looksLikeGraph(data)) return data;
    if (data.data && looksLikeGraph(data.data)) return data.data;
    if (data.result && looksLikeGraph(data.result)) return data.result;
    if (data.body && looksLikeGraph(data.body)) return data.body;
    if (data.graph && looksLikeGraph(data.graph)) return data.graph;
    if (data.graphData && looksLikeGraph(data.graphData)) return data.graphData;
    var fromCy = graphFromCyJson(data);
    if (fromCy) return fromCy;
    if (data.body) {
      fromCy = graphFromCyJson(data.body);
      if (fromCy) return fromCy;
    }
    return data;
  }

  function readXhrBody(xhr) {
    var rt = "";
    try {
      rt = xhr.responseType || "";
    } catch (err) {
      rt = "";
    }
    if (rt && rt !== "text") {
      try {
        if (xhr.response != null && xhr.response !== "") return xhr.response;
      } catch (err) {
        /* fall through */
      }
    }
    try {
      if (xhr.responseText) return xhr.responseText;
    } catch (err) {
      /* responseType json: responseText is not readable */
    }
    try {
      if (xhr.response != null && xhr.response !== "") return xhr.response;
    } catch (err2) {
      /* ignore */
    }
    return null;
  }

  function decodeFormValue(value) {
    if (typeof value !== "string") return value;
    var text = value.replace(/\+/g, " ");
    try {
      text = decodeURIComponent(text);
    } catch (err) {
      return value;
    }
    if (text.indexOf("%") >= 0) {
      try {
        text = decodeURIComponent(text);
      } catch (err2) {
        /* keep once-decoded */
      }
    }
    return text;
  }

  function formatPeriod(value) {
    var text = decodeFormValue(String(value || "")).trim();
    if (!text) return "";
    var m = text.match(/^(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/);
    if (!m) return text;
    var months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ];
    var month = months[parseInt(m[2], 10) - 1] || m[2];
    var day = String(parseInt(m[3], 10));
    var out = day + " " + month + " " + m[1];
    if (m[4]) out += ", " + m[4] + ":" + m[5] + ":" + (m[6] || "00");
    return out;
  }

  function applyPair(req, key, value) {
    if (value === undefined || value === null) return;
    if (typeof value === "string") value = decodeFormValue(value);
    if (key === "nodesToSearch" || key === "nodes") {
      if (typeof value === "string") {
        try {
          req.nodes = JSON.parse(value);
        } catch (err) {
          req.nodes = [];
        }
      } else {
        req.nodes = value;
      }
    } else if (key === "graphDepth") req.graphDepth = value;
    else if (key === "dateFrom") req.dateFrom = value;
    else if (key === "dateTo") req.dateTo = value;
    else if (key === "linkTypeCat") req.linkTypeCat = value;
    else if (key === "dispTypes") req.dispTypes = value;
  }

  function applyRequestObject(req, obj) {
    if (!obj || typeof obj !== "object") return;
    applyPair(req, "nodesToSearch", obj.nodesToSearch || obj.nodes);
    applyPair(req, "graphDepth", obj.graphDepth);
    applyPair(req, "dateFrom", obj.dateFrom);
    applyPair(req, "dateTo", obj.dateTo);
    applyPair(req, "linkTypeCat", obj.linkTypeCat);
    applyPair(req, "dispTypes", obj.dispTypes);
  }

  function parseRequestBody(body) {
    var req = {};
    if (!body) return req;
    if (typeof FormData !== "undefined" && body instanceof FormData) {
      if (typeof body.forEach === "function") {
        body.forEach(function (value, key) {
          applyPair(req, key, value);
        });
      }
      return req;
    }
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
      body.forEach(function (value, key) {
        applyPair(req, key, value);
      });
      return req;
    }
    if (typeof body === "string") {
      try {
        var obj = JSON.parse(body);
        if (obj && (obj.nodes || obj.nodesToSearch || obj.graphDepth || obj.dateFrom)) {
          applyRequestObject(req, obj);
          return req;
        }
      } catch (err) {
        /* try form encoding */
      }
      try {
        var params = new URLSearchParams(body);
        params.forEach(function (value, key) {
          applyPair(req, key, value);
        });
      } catch (err2) {
        /* ignore */
      }
      return req;
    }
    if (typeof body === "object") {
      applyRequestObject(req, body);
    }
    return req;
  }

  function isSearchUrl(url) {
    return String(url || "").indexOf(SEARCH_MARK) >= 0;
  }

  var api = {
    buildSummary: buildSummary,
    parseRequestBody: parseRequestBody,
    parseGraphResponse: parseGraphResponse,
    formatPeriod: formatPeriod,
    decodeFormValue: decodeFormValue,
    findGraphIn: findGraphIn,
    graphFromCyJson: graphFromCyJson,
    readXhrBody: readXhrBody,
    isSearchUrl: isSearchUrl,
    looksLikeGraph: looksLikeGraph,
    isEmptySearchResult: isEmptySearchResult
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  root.GlcSummary = api;

  if (typeof document === "undefined") return;

  /* ---------- GUI injector (browser only) ---------- */

  var observer = null;
  var active = false;
  var pending = null;
  var lastSearchReq = {};
  var hooksInstalled = false;
  var summarizeRunning = false;
  var boundOkHost = null;

  function log() {
    var args = Array.prototype.slice.call(arguments);
    args.unshift("[GLC-Summary]");
    if (typeof console !== "undefined" && console.log) console.log.apply(console, args);
  }

  function isLinkAnalysisPage() {
    return window.location.pathname.indexOf("/case-manager/linkanalysis") >= 0;
  }

  function getOkButton() {
    var hosts = document.querySelectorAll("erm-button");
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      var glyph = host.getAttribute("ng-reflect-gliph") || "";
      var btn = host.querySelector("button.k-button, button");
      if (!btn || btn.id === "glcRunAndSummarizeBtn") continue;
      var labelEl = btn.querySelector("span.button-content");
      var label = labelEl ? labelEl.textContent.trim() : "";
      var hasSearch = glyph === "search" || !!btn.querySelector("i.fa-search, .fa-search");
      if (hasSearch && label === "Ok") return btn;
    }
    var all = document.querySelectorAll("button.k-button, button.btn-primary");
    for (var j = 0; j < all.length; j++) {
      var b = all[j];
      if (b.id === "glcRunAndSummarizeBtn") continue;
      var t = b.querySelector("span.button-content");
      var text = t ? t.textContent.trim() : "";
      if (text === "Ok" && b.querySelector(".fa-search")) return b;
    }
    return null;
  }

  function isGlcComponent(cmp) {
    return !!(
      cmp &&
      (typeof cmp.setCytoscapeData === "function" ||
        typeof cmp.searchNodes === "function" ||
        typeof cmp.goSearch === "function")
    );
  }

  function findGlcComponent() {
    if (!window.ng) return null;
    var start = getOkButton();
    if (!start) return null;
    var el = start;
    var hops = 0;
    while (el && hops < 40) {
      try {
        if (typeof window.ng.getOwningComponent === "function") {
          var owner = window.ng.getOwningComponent(el);
          if (isGlcComponent(owner)) return owner;
        }
      } catch (err) {
        /* ignore */
      }
      try {
        if (typeof window.ng.getComponent === "function") {
          var cmp = window.ng.getComponent(el);
          if (isGlcComponent(cmp)) return cmp;
        }
      } catch (err2) {
        /* ignore */
      }
      el = el.parentElement;
      hops++;
    }
    return null;
  }

  function deliverCapture(captured, opts) {
    opts = opts || {};
    if (!pending) return false;
    var data = captured && captured.data;
    try {
      data = parseGraphResponse(data);
    } catch (err) {
      log("skip payload, not JSON yet", err && err.message ? err.message : err);
      return false;
    }
    var populated = looksLikeGraph(data);
    var emptyOk = !!(opts.allowEmpty && isEmptySearchResult(data));
    if (!populated && !emptyOk) {
      log(
        "skip payload, waiting for graph vertices",
        data && typeof data === "object" ? Object.keys(data).slice(0, 12) : typeof data
      );
      return false;
    }
    pending.resolve({
      req: (captured && captured.req) || lastSearchReq || {},
      data: data
    });
    pending = null;
    return true;
  }

  function tapObservable(obs, onNext) {
    if (!obs || typeof obs.subscribe !== "function") return obs;
    if (obs.__glcSummaryTapped) return obs;
    obs.__glcSummaryTapped = true;
    var origSubscribe = obs.subscribe;
    obs.subscribe = function (observerOrNext, error, complete) {
      function notify(value) {
        try {
          onNext(value);
        } catch (err) {
          log("observable tap error", err);
        }
      }
      if (observerOrNext && typeof observerOrNext !== "function") {
        var observer = observerOrNext;
        return origSubscribe.call(this, {
          next: function (value) {
            notify(value);
            if (observer.next) observer.next(value);
          },
          error: function (err) {
            if (observer.error) observer.error(err);
          },
          complete: function () {
            if (observer.complete) observer.complete();
          }
        });
      }
      return origSubscribe.call(
        this,
        function (value) {
          notify(value);
          if (typeof observerOrNext === "function") observerOrNext(value);
        },
        error,
        complete
      );
    };
    return obs;
  }

  function findCy(cmp) {
    if (!cmp || typeof cmp !== "object") return null;
    var names = ["cy", "cytoscape", "cyInstance", "_cy", "cyGraph", "cyObj"];
    var i;
    for (i = 0; i < names.length; i++) {
      try {
        if (cmp[names[i]] && typeof cmp[names[i]].nodes === "function") return cmp[names[i]];
      } catch (err) {
        /* ignore */
      }
    }
    var nested = [
      cmp.cytoscapeWrapper,
      cmp.cyComponent,
      cmp.graphComponent,
      cmp.cytoscapeGraph,
      cmp.cyGraphComponent
    ];
    for (i = 0; i < nested.length; i++) {
      var found = findCy(nested[i]);
      if (found) return found;
    }
    return null;
  }

  function addCy(list, cy) {
    if (cy && typeof cy.nodes === "function" && list.indexOf(cy) < 0) list.push(cy);
  }

  function findCyFromDom() {
    var found = [];
    if (typeof window !== "undefined") addCy(found, window.cy);
    if (!document || !window.ng) return found;
    var sels = document.querySelectorAll(
      "cytoscape-graph, cytoscape-wrapper, app-cytoscape-graph, canvas"
    );
    var i;
    for (i = 0; i < sels.length; i++) {
      var el = sels[i];
      var hops = 0;
      while (el && hops < 10) {
        try {
          if (typeof window.ng.getComponent === "function") {
            addCy(found, findCy(window.ng.getComponent(el)));
          }
        } catch (err) {
          /* ignore */
        }
        try {
          if (typeof window.ng.getOwningComponent === "function") {
            addCy(found, findCy(window.ng.getOwningComponent(el)));
          }
        } catch (err2) {
          /* ignore */
        }
        el = el.parentElement;
        hops++;
      }
    }
    return found;
  }

  function harvestShallow(cmp) {
    if (!cmp || typeof cmp !== "object") return null;
    var keys;
    try {
      keys = Object.keys(cmp);
    } catch (err) {
      return null;
    }
    var i;
    for (i = 0; i < keys.length; i++) {
      var val;
      try {
        val = cmp[keys[i]];
      } catch (err2) {
        continue;
      }
      if (!val || typeof val === "function") continue;
      try {
        var parsed = parseGraphResponse(val);
        if (looksLikeGraph(parsed)) return parsed;
      } catch (err3) {
        /* next */
      }
    }
    return findGraphIn(cmp, 0, []);
  }

  function tryHarvest(cmp) {
    if (!pending) return false;
    if (cmp) {
      var found = harvestShallow(cmp);
      if (found && deliverCapture({ req: lastSearchReq, data: found })) {
        log("harvested graph JSON from GLC component");
        return true;
      }
    }
    var cys = findCyFromDom();
    if (cmp) addCy(cys, findCy(cmp));
    var i;
    for (i = 0; i < cys.length; i++) {
      var fromCy = graphFromCytoscape(cys[i]);
      if (fromCy && looksLikeGraph(fromCy) && deliverCapture({ req: lastSearchReq, data: fromCy })) {
        log(
          "harvested graph from Cytoscape",
          fromCy.vertices.length,
          "nodes",
          fromCy.edges.length,
          "links"
        );
        return true;
      }
    }
    return false;
  }

  function startHarvestLoop(cmp) {
    var started = Date.now();
    var timer = setInterval(function () {
      if (!pending) {
        clearInterval(timer);
        return;
      }
      if (tryHarvest(cmp)) {
        clearInterval(timer);
        return;
      }
      if (Date.now() - started >= WAIT_MS) clearInterval(timer);
    }, 500);
  }

  function urlFromArgs(args) {
    for (var i = 0; i < args.length; i++) {
      if (typeof args[i] === "string" && isSearchUrl(args[i])) return args[i];
    }
    return "";
  }

  function hookGlcComponent(cmp) {
    if (!cmp) return false;
    if (typeof cmp.sendPostRequest === "function" && !cmp.__glcSummarySendHooked) {
      cmp.__glcSummarySendHooked = true;
      var origSend = cmp.sendPostRequest;
      cmp.sendPostRequest = function () {
        var formData = arguments[0];
        var url = urlFromArgs(arguments);
        var result = origSend.apply(this, arguments);
        if (!pending) return result;
        if (url || formData) {
          var parsed = parseRequestBody(formData);
          if (parsed && (parsed.nodes || parsed.graphDepth || parsed.dateFrom)) lastSearchReq = parsed;
        }
        return tapObservable(result, function (value) {
          log(
            "sendPostRequest next",
            typeof value,
            value && typeof value === "object" ? Object.keys(value).slice(0, 12) : ""
          );
          if (deliverCapture({ req: lastSearchReq, data: value }, { allowEmpty: true })) return;
          var nested = findGraphIn(value, 0, []);
          if (nested) deliverCapture({ req: lastSearchReq, data: nested }, { allowEmpty: true });
        });
      };
      log("hooked GLCComponent.sendPostRequest");
    }
    if (typeof cmp.setCytoscapeData === "function" && !cmp.__glcSummaryHooked) {
      cmp.__glcSummaryHooked = true;
      var orig = cmp.setCytoscapeData;
      cmp.setCytoscapeData = function () {
        var result = orig.apply(this, arguments);
        var self = this;
        var arg0 = arguments[0];
        log(
          "setCytoscapeData args",
          arguments.length,
          arg0 == null ? arg0 : typeof arg0
        );
        if (deliverCapture({ req: lastSearchReq, data: arg0 })) return result;
        tryHarvest(self);
        setTimeout(function () {
          tryHarvest(self);
        }, 0);
        setTimeout(function () {
          tryHarvest(self);
        }, 200);
        setTimeout(function () {
          tryHarvest(self);
        }, 600);
        return result;
      };
      log("hooked GLCComponent.setCytoscapeData");
    }
    return true;
  }

  function installHooks() {
    if (hooksInstalled) return;
    hooksInstalled = true;

    function captureFromXhr(xhr, body) {
      var url = xhr.__glcUrl || "";
      var searchBody = false;
      try {
        searchBody =
          typeof FormData !== "undefined" &&
          body &&
          body instanceof FormData &&
          typeof body.has === "function" &&
          (body.has("nodesToSearch") || body.has("linkTypeCat"));
      } catch (err) {
        searchBody = false;
      }
      if (!isSearchUrl(url) && !searchBody) return;
      var req = parseRequestBody(body);
      if (req && (req.nodes || req.dateFrom || req.graphDepth)) lastSearchReq = req;
      if (!pending) return;

      function succeed() {
        if (xhr.readyState !== 4) return;
        var raw = readXhrBody(xhr);
        if (raw == null || raw === "") {
          log(
            "searchByNodes XHR had an empty body (Angular json responseType is normal); waiting for graph data"
          );
          return;
        }
        deliverCapture({ req: req, data: raw }, { allowEmpty: true });
      }

      xhr.addEventListener("readystatechange", function () {
        if (xhr.readyState === 4) setTimeout(succeed, 0);
      });
      xhr.addEventListener("load", function () {
        setTimeout(succeed, 0);
      });
    }

    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      var found = "";
      for (var i = 0; i < arguments.length; i++) {
        if (typeof arguments[i] === "string" && isSearchUrl(arguments[i])) found = arguments[i];
      }
      this.__glcUrl = found || (typeof url === "string" ? url : (url && url.toString()) || "");
      return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function (body) {
      try {
        captureFromXhr(this, body);
      } catch (err) {
        log("xhr hook error", err);
      }
      return origSend.apply(this, arguments);
    };

    if (typeof window.fetch === "function") {
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === "string" ? input : (input && input.url) || "";
        var p = origFetch.apply(this, arguments);
        if (pending && isSearchUrl(url)) {
          var req = parseRequestBody(init && init.body);
          lastSearchReq = req;
          p.then(function (res) {
            return res
              .clone()
              .json()
              .catch(function () {
                return res.clone().text();
              })
              .then(function (body) {
                deliverCapture({ req: req, data: body }, { allowEmpty: true });
              });
          }).catch(function () {
            /* keep waiting for setCytoscapeData */
          });
        }
        return p;
      };
    }
    log("network hooks installed");
  }

  function armCapture(timeoutMs, cmp) {
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(function () {
        if (!pending) return;
        if (tryHarvest(cmp)) return;
        pending = null;
        reject(
          new Error(
            "Timed out waiting for the GLC search (waited 20 minutes). If the graph is still loading, wait for it to finish and click Run and Summarize again."
          )
        );
      }, timeoutMs);
      pending = {
        resolve: function (value) {
          clearTimeout(timer);
          resolve(value);
        },
        reject: function (err) {
          clearTimeout(timer);
          reject(err);
        }
      };
    });
  }

  function ensureDockCss() {
    if (document.getElementById("glcSummaryDockCss")) return;
    var style = document.createElement("style");
    style.id = "glcSummaryDockCss";
    style.textContent = [
      "#glcSummaryDock{position:fixed;right:20px;bottom:20px;z-index:100000;width:460px;height:520px;",
      "display:flex;flex-direction:column;overflow:hidden;border-radius:14px;",
      "background:#0b1220;color:#e5eefc;box-shadow:0 18px 50px rgba(2,8,23,.45),0 0 0 1px rgba(148,163,184,.18);",
      "font-family:Segoe UI,system-ui,-apple-system,sans-serif;transition:width .2s ease,height .2s ease,border-radius .2s ease;}",
      "#glcSummaryDock.is-min{width:252px;height:44px;border-radius:22px;cursor:pointer;}",
      "#glcSummaryDock.is-max{width:min(960px,calc(100vw - 40px));height:calc(100vh - 40px);}",
      "#glcSummaryDock .glc-head{display:flex;align-items:center;gap:10px;padding:0 8px 0 12px;height:48px;flex:0 0 48px;",
      "background:linear-gradient(180deg,#152033,#101a2c);border-bottom:1px solid rgba(148,163,184,.14);user-select:none;}",
      "#glcSummaryDock.is-min .glc-head{border-bottom:none;height:44px;flex-basis:44px;}",
      "#glcSummaryDock .glc-status{position:relative;width:16px;height:16px;flex:0 0 16px;display:inline-flex;align-items:center;justify-content:center;}",
      "#glcSummaryDock .glc-dot{width:10px;height:10px;border-radius:50%;background:#38bdf8;box-shadow:0 0 10px rgba(56,189,248,.8);}",
      "#glcSummaryDock .glc-spinner{width:14px;height:14px;border-radius:50%;border:2px solid rgba(148,163,184,.28);border-top-color:#7dd3fc;",
      "animation:glcSpin .7s linear infinite;box-sizing:border-box;}",
      "#glcSummaryDock.is-loading .glc-dot{display:none;}",
      "#glcSummaryDock:not(.is-loading) .glc-spinner{display:none;}",
      "#glcSummaryDock .glc-badge{position:absolute;top:-2px;right:-2px;width:8px;height:8px;border-radius:50%;background:#ef4444;",
      "box-shadow:0 0 0 2px #0b1220,0 0 8px rgba(239,68,68,.9);display:none;}",
      "#glcSummaryDock.has-unread .glc-badge{display:block;}",
      "@keyframes glcSpin{to{transform:rotate(360deg);}}",
      "#glcSummaryDock .glc-title{flex:1;min-width:0;font-size:13px;font-weight:600;letter-spacing:.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      "#glcSummaryDock .glc-sub{display:block;font-size:10px;font-weight:500;color:#93c5fd;opacity:.9;margin-top:1px;}",
      "#glcSummaryDock .glc-actions{display:flex;align-items:center;gap:4px;}",
      "#glcSummaryDock .glc-iconbtn{appearance:none;border:0;background:transparent;color:#cbd5e1;width:28px;height:28px;border-radius:8px;",
      "display:inline-flex;align-items:center;justify-content:center;cursor:pointer;font-size:14px;line-height:1;padding:0;}",
      "#glcSummaryDock .glc-iconbtn:hover{background:rgba(148,163,184,.16);color:#fff;}",
      "#glcSummaryDock .glc-iconbtn.glc-close:hover{background:#ef4444;color:#fff;}",
      "#glcSummaryDock .glc-copy-label{width:auto;padding:0 8px;font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;}",
      "#glcSummaryDock .glc-copy-label.is-copied{color:#86efac;}",
      "#glcSummaryDock .glc-body{flex:1;min-height:0;overflow:auto;background:#0b1220;}",
      "#glcSummaryDock.is-min .glc-body,#glcSummaryDock.is-min .glc-copy-label,#glcSummaryDock.is-min .glc-sub,#glcSummaryDock.is-min .glc-min{display:none;}",
      "#glcSummaryDock.is-loading .glc-copy-label,#glcSummaryDock.is-loading .glc-max{display:none;}",
      "#glcSummaryDock pre{margin:0;padding:16px 18px 20px;white-space:pre-wrap;word-break:break-word;user-select:text;",
      "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;line-height:1.55;color:#dbeafe;}",
      "#glcSummaryDock .glc-resize{position:absolute;left:0;top:0;width:14px;height:14px;cursor:nwse-resize;display:none;}",
      "#glcSummaryDock:not(.is-min):not(.is-max) .glc-resize{display:block;background:linear-gradient(135deg,transparent 50%,rgba(148,163,184,.5) 50%);border-top-left-radius:14px;}"
    ].join("");
    document.head.appendChild(style);
  }

  function copyReportText(text, btn) {
    function done() {
      if (!btn) return;
      btn.textContent = "Copied";
      btn.classList.add("is-copied");
      setTimeout(function () {
        btn.textContent = "Copy";
        btn.classList.remove("is-copied");
      }, 1400);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done).catch(done);
      return;
    }
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } catch (err) {
      /* ignore */
    }
    ta.remove();
    done();
  }

  function setDockMode(dock, mode) {
    dock.classList.remove("is-min", "is-max");
    if (mode === "min") dock.classList.add("is-min");
    if (mode === "max") dock.classList.add("is-max");
    dock.setAttribute("data-mode", mode);
    dock.style.width = "";
    dock.style.height = "";
    var maxBtn = dock.querySelector(".glc-max");
    if (maxBtn) {
      maxBtn.textContent = mode === "max" ? "❐" : "□";
      maxBtn.title = mode === "max" ? "Restore" : "Maximize";
    }
    var minBtn = dock.querySelector(".glc-min");
    if (minBtn) minBtn.title = mode === "min" ? "Restore" : "Minimize";
  }

  function markDockRead(dock) {
    dock.classList.remove("has-unread");
  }

  function bindDockEvents(dock) {
    if (dock.__glcBound) return;
    dock.__glcBound = true;
    dock.querySelector(".glc-close").addEventListener("click", function (e) {
      e.stopPropagation();
      dock.remove();
    });
    dock.querySelector(".glc-min").addEventListener("click", function (e) {
      e.stopPropagation();
      setDockMode(dock, "min");
    });
    dock.querySelector(".glc-max").addEventListener("click", function (e) {
      e.stopPropagation();
      if (dock.classList.contains("is-loading")) return;
      markDockRead(dock);
      setDockMode(dock, dock.classList.contains("is-max") ? "open" : "max");
    });
    dock.querySelector(".glc-copy-label").addEventListener("click", function (e) {
      e.stopPropagation();
      copyReportText(dock.__reportText || "", e.currentTarget);
    });
    dock.querySelector(".glc-head").addEventListener("click", function () {
      if (dock.classList.contains("is-loading")) return;
      if (dock.classList.contains("is-min")) {
        markDockRead(dock);
        setDockMode(dock, "open");
      }
    });
    var handle = dock.querySelector(".glc-resize");
    handle.addEventListener("mousedown", function (e) {
      if (dock.classList.contains("is-min") || dock.classList.contains("is-max")) return;
      e.preventDefault();
      var startX = e.clientX;
      var startY = e.clientY;
      var startW = dock.offsetWidth;
      var startH = dock.offsetHeight;
      function move(ev) {
        var w = Math.max(320, startW - (ev.clientX - startX));
        var h = Math.max(220, startH - (ev.clientY - startY));
        dock.style.width = w + "px";
        dock.style.height = h + "px";
        dock.style.transition = "none";
      }
      function up() {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
        dock.style.transition = "";
      }
      document.addEventListener("mousemove", move);
      document.addEventListener("mouseup", up);
    });
  }

  function getDock() {
    ensureDockCss();
    var dock = document.getElementById("glcSummaryDock");
    if (dock) return dock;
    dock = document.createElement("div");
    dock.id = "glcSummaryDock";
    dock.setAttribute("role", "dialog");
    dock.setAttribute("aria-label", "GLC network report");
    dock.innerHTML =
      '<div class="glc-resize" title="Resize"></div>' +
      '<div class="glc-head">' +
      '<span class="glc-status"><span class="glc-spinner"></span><span class="glc-dot"></span><span class="glc-badge"></span></span>' +
      '<div class="glc-title"><span class="glc-title-text">GLC network report</span><span class="glc-sub"></span></div>' +
      '<div class="glc-actions">' +
      '<button type="button" class="glc-iconbtn glc-copy-label" title="Copy all">Copy</button>' +
      '<button type="button" class="glc-iconbtn glc-min" title="Minimize">–</button>' +
      '<button type="button" class="glc-iconbtn glc-max" title="Maximize">□</button>' +
      '<button type="button" class="glc-iconbtn glc-close" title="Close">×</button>' +
      "</div></div>" +
      '<div class="glc-body"><pre></pre></div>';
    bindDockEvents(dock);
    document.body.appendChild(dock);
    return dock;
  }

  function setDockLoading() {
    var dock = getDock();
    dock.classList.add("is-loading");
    dock.classList.remove("has-unread", "is-error");
    setDockMode(dock, "min");
    dock.querySelector(".glc-title-text").textContent = "Running…";
    dock.querySelector(".glc-sub").textContent = "Search can take 10+ minutes";
    dock.querySelector("pre").textContent =
      "GLC is still searching. This can take 10 minutes or more. The report will appear here when the graph is ready.";
    dock.__reportText = "";
  }

  function setDockReady(text, isError) {
    var dock = getDock();
    dock.classList.remove("is-loading");
    if (isError) dock.classList.add("is-error");
    else dock.classList.remove("is-error");
    dock.classList.add("has-unread");
    setDockMode(dock, "min");
    dock.querySelector(".glc-title-text").textContent = "GLC network report";
    dock.querySelector(".glc-sub").textContent = isError ? "Failed · click to open" : "Ready · click to open";
    dock.querySelector("pre").textContent = text;
    dock.__reportText = text;
  }

  function showReportWindow(text) {
    setDockReady(text, false);
  }

  function showModal(text) {
    setDockReady(text, /could not|timed out|failed/i.test(String(text || "")));
  }

  function getOkHost() {
    var okBtn = getOkButton();
    if (!okBtn) return null;
    if (okBtn.closest) {
      var host = okBtn.closest("erm-button");
      if (host) return host;
    }
    return okBtn;
  }

  function onOkCapture() {
    if (summarizeRunning) return;
    startSummarizeFromOk();
  }

  function unbindOkCapture() {
    if (!boundOkHost) return;
    boundOkHost.removeEventListener("click", onOkCapture, true);
    boundOkHost = null;
  }

  function bindOkCapture() {
    var leftover = document.querySelector("#glcRunAndSummarizeBtn");
    if (leftover) leftover.remove();
    var host = getOkHost();
    if (!host) return;
    if (host === boundOkHost) return;
    unbindOkCapture();
    boundOkHost = host;
    host.addEventListener("click", onOkCapture, true);
    log("Ok capture bound");
  }

  function startSummarizeFromOk() {
    if (summarizeRunning) return;
    summarizeRunning = true;
    setDockLoading();
    installHooks();
    var cmp = findGlcComponent();
    if (cmp) {
      hookGlcComponent(cmp);
    } else {
      log("GLCComponent not found; will use the searchByNodes response");
    }
    var wait = armCapture(WAIT_MS, cmp);
    startHarvestLoop(cmp);
    wait
      .then(function (captured) {
        showModal(buildSummary(captured.req, captured.data));
      })
      .catch(function (err) {
        showModal("Could not build the report.\n\n" + (err && err.message ? err.message : err));
      })
      .then(function () {
        summarizeRunning = false;
      });
  }

  function start() {
    if (observer) return;
    installHooks();
    observer = new MutationObserver(function () {
      bindOkCapture();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    bindOkCapture();
  }

  function stop() {
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    unbindOkCapture();
    summarizeRunning = false;
    var leftover = document.querySelector("#glcRunAndSummarizeBtn");
    if (leftover) leftover.remove();
    var dock = document.getElementById("glcSummaryDock");
    if (dock) dock.remove();
  }

  function updateState() {
    var should = isLinkAnalysisPage();
    if (should && !active) {
      active = true;
      log("LinkAnalysis ENTER");
      start();
    }
    if (!should && active) {
      active = false;
      log("LinkAnalysis EXIT");
      stop();
    }
  }

  function hookHistory(fnName) {
    var original = history[fnName];
    history[fnName] = function () {
      var result = original.apply(this, arguments);
      window.dispatchEvent(new Event("locationchange"));
      return result;
    };
  }

  hookHistory("pushState");
  hookHistory("replaceState");
  window.addEventListener("popstate", function () {
    window.dispatchEvent(new Event("locationchange"));
  });
  window.addEventListener("locationchange", updateState);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", updateState);
  } else {
    updateState();
  }
})(typeof window !== "undefined" ? window : global);
