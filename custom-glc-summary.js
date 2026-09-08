/**
 * GLC "Run and Summarize" button for ERM Link Analysis.
 *
 * Same injection style as custom-delete.js. No Python, no files, no extra login.
 * Clicks the real Ok button (so the graph still draws), captures the
 * searchByNodes response, and shows the business report in a popup.
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
  var WAIT_MS = 180000;
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
        isolated: isolated
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
    lines.push(new Array(65).join("=").slice(0, 64));
    lines.push("GLC network report");
    lines.push(new Array(65).join("=").slice(0, 64));

    var dateFrom = req.dateFrom || "";
    var dateTo = req.dateTo || "";
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
      lines.push(new Array(65).join("=").slice(0, 64));
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
      lines.push(row.count + " " + row.type_name + " nodes" + suffix + ".");
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

    lines.push("");
    lines.push(new Array(65).join("=").slice(0, 64));
    return lines.join("\n") + "\n";
  }

  function parseGraphResponse(raw) {
    var data = raw;
    if (typeof data === "string") data = JSON.parse(data);
    if (data && !data.vertices && data.data && data.data.vertices) data = data.data;
    if (data && !data.vertices && data.result && data.result.vertices) data = data.result;
    return data;
  }

  function applyPair(req, key, value) {
    if (value === undefined || value === null) return;
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
        if (obj && (obj.nodes || obj.nodesToSearch || obj.graphDepth)) {
          applyPair(req, "nodesToSearch", obj.nodesToSearch || obj.nodes);
          applyPair(req, "graphDepth", obj.graphDepth);
          applyPair(req, "dateFrom", obj.dateFrom);
          applyPair(req, "dateTo", obj.dateTo);
          applyPair(req, "linkTypeCat", obj.linkTypeCat);
          applyPair(req, "dispTypes", obj.dispTypes);
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
    isSearchUrl: isSearchUrl
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
  var hooksInstalled = false;

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

  function installHooks() {
    if (hooksInstalled) return;
    hooksInstalled = true;

    function captureFromXhr(xhr, body) {
      if (!pending || !isSearchUrl(xhr.__glcUrl)) return;
      var req = parseRequestBody(body);
      function succeed() {
        if (!pending) return;
        try {
          var data = parseGraphResponse(xhr.responseText || xhr.response);
          pending.resolve({ req: req, data: data });
        } catch (err) {
          pending.reject(err);
        }
        pending = null;
      }
      function fail() {
        if (!pending) return;
        pending.reject(new Error("The GLC search request failed."));
        pending = null;
      }
      xhr.addEventListener("load", succeed);
      xhr.addEventListener("error", fail);
      xhr.addEventListener("abort", fail);
    }

    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__glcUrl = typeof url === "string" ? url : (url && url.toString()) || "";
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
          p.then(function (res) {
            return res.clone().text().then(function (text) {
              if (!pending) return;
              try {
                pending.resolve({ req: req, data: parseGraphResponse(text) });
              } catch (err) {
                pending.reject(err);
              }
              pending = null;
            });
          }).catch(function (err) {
            if (!pending) return;
            pending.reject(err);
            pending = null;
          });
        }
        return p;
      };
    }
    log("network hooks installed");
  }

  function armCapture(timeoutMs) {
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(function () {
        if (pending) {
          pending = null;
          reject(
            new Error(
              "Timed out waiting for the GLC search. The graph may still appear. Confirm Ok works, then try again."
            )
          );
        }
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

  function ensureModalCss() {
    if (document.getElementById("glcSummaryModalCss")) return;
    var style = document.createElement("style");
    style.id = "glcSummaryModalCss";
    style.textContent =
      "#glcSummaryModalMask{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:100000;display:flex;align-items:center;justify-content:center;padding:24px;}" +
      "#glcSummaryModal{background:#fff;color:#222;max-width:920px;width:100%;max-height:86vh;border-radius:6px;box-shadow:0 12px 40px rgba(0,0,0,.35);display:flex;flex-direction:column;font-family:Arial,Helvetica,sans-serif;}" +
      "#glcSummaryModal header{padding:12px 16px;border-bottom:1px solid #ddd;display:flex;align-items:center;justify-content:space-between;}" +
      "#glcSummaryModal header h2{margin:0;font-size:16px;}" +
      "#glcSummaryModal pre{margin:0;padding:16px;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:13px;line-height:1.45;flex:1;}" +
      "#glcSummaryModal footer{padding:10px 16px;border-top:1px solid #ddd;display:flex;gap:8px;justify-content:flex-end;}" +
      "#glcSummaryModal button{min-width:88px;padding:6px 12px;cursor:pointer;}";
    document.head.appendChild(style);
  }

  function showModal(text) {
    ensureModalCss();
    var old = document.getElementById("glcSummaryModalMask");
    if (old) old.remove();
    var mask = document.createElement("div");
    mask.id = "glcSummaryModalMask";
    mask.innerHTML =
      '<div id="glcSummaryModal" role="dialog" aria-modal="true">' +
      "<header><h2>GLC network report</h2></header>" +
      "<pre></pre>" +
      "<footer>" +
      '<button type="button" class="glc-copy">Copy</button>' +
      '<button type="button" class="glc-close">Close</button>' +
      "</footer></div>";
    mask.querySelector("pre").textContent = text;
    function close() {
      mask.remove();
    }
    mask.addEventListener("click", function (ev) {
      if (ev.target === mask) close();
    });
    mask.querySelector(".glc-close").addEventListener("click", close);
    mask.querySelector(".glc-copy").addEventListener("click", function () {
      var btn = this;
      function done() {
        btn.textContent = "Copied";
        setTimeout(function () {
          btn.textContent = "Copy";
        }, 1200);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(done);
      } else {
        var ta = document.createElement("textarea");
        ta.value = text;
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
    });
    document.body.appendChild(mask);
  }

  function setButtonLabel(btn, label, iconClass) {
    var icon = btn.querySelector("i");
    if (icon && iconClass) icon.className = iconClass;
    var text = btn.querySelector("span.button-content");
    if (text) text.textContent = label;
  }

  function runAndSummarize(ourBtn) {
    if (ourBtn.dataset.running === "1") return;
    var okBtn = getOkButton();
    if (!okBtn) {
      showModal("Could not find the Ok button on this page.");
      return;
    }
    ourBtn.dataset.running = "1";
    ourBtn.disabled = true;
    setButtonLabel(ourBtn, "Running...", "fa fa-spinner");
    installHooks();
    var wait = armCapture(WAIT_MS);
    try {
      okBtn.click();
    } catch (err) {
      ourBtn.dataset.running = "0";
      ourBtn.disabled = false;
      setButtonLabel(ourBtn, "Run and Summarize", "fa fa-list-alt");
      showModal("Could not click Ok.\n\n" + (err && err.message ? err.message : err));
      return;
    }
    wait
      .then(function (captured) {
        var text = buildSummary(captured.req, captured.data);
        showModal(text);
      })
      .catch(function (err) {
        showModal("Could not build the report.\n\n" + (err && err.message ? err.message : err));
      })
      .then(function () {
        ourBtn.dataset.running = "0";
        ourBtn.disabled = false;
        setButtonLabel(ourBtn, "Run and Summarize", "fa fa-list-alt");
      });
  }

  function injectButton() {
    var okBtn = getOkButton();
    if (!okBtn) return;
    if (document.querySelector("#glcRunAndSummarizeBtn")) return;

    var host = okBtn.closest ? okBtn.closest("erm-button") : okBtn.parentElement;
    var insertAfter = host || okBtn;
    var parent = insertAfter.parentNode;
    if (!parent) return;

    var newBtn = okBtn.cloneNode(true);
    newBtn.id = "glcRunAndSummarizeBtn";
    newBtn.title = "Run and Summarize";
    newBtn.disabled = false;
    newBtn.removeAttribute("disabled");
    newBtn.setAttribute("aria-disabled", "false");
    newBtn.style.marginLeft = "8px";
    newBtn.style.pointerEvents = "auto";
    setButtonLabel(newBtn, "Run and Summarize", "fa fa-list-alt");
    newBtn.onclick = null;
    newBtn.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      runAndSummarize(newBtn);
    });
    parent.insertBefore(newBtn, insertAfter.nextSibling);
    log("button injected");
  }

  function start() {
    if (observer) return;
    installHooks();
    observer = new MutationObserver(function () {
      injectButton();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    injectButton();
  }

  function stop() {
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    var btn = document.querySelector("#glcRunAndSummarizeBtn");
    if (btn) btn.remove();
    var modal = document.getElementById("glcSummaryModalMask");
    if (modal) modal.remove();
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
