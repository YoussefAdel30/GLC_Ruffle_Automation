#!/usr/bin/env python3
"""Build a short text census of a GLC graph response.

Stdlib only. No pip packages.
"""

from __future__ import print_function

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict


MSISDN_TYPE_ID = 1
USER_TYPE_ID = 1001
DEVICE_TYPE_ID = 1000
ID_TYPE_ID = 1003
WALLET_PROFILE_TYPE_ID = 1321
WALLET_STATUS_TYPE_ID = 1141
LINE_STATUS_TYPE_ID = 1160

VALUE_TYPE_IDS = {
    WALLET_PROFILE_TYPE_ID,
    WALLET_STATUS_TYPE_ID,
    LINE_STATUS_TYPE_ID,
}
IDENTITY_TYPE_IDS = {
    MSISDN_TYPE_ID,
    DEVICE_TYPE_ID,
    USER_TYPE_ID,
    ID_TYPE_ID,
}

_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
TOP_N_DEFAULT = 8


def load_json(path):
    with open(path, "r") as fh:
        raw = fh.read().strip()
    if not raw:
        raise ValueError("empty JSON file: %s" % path)
    try:
        return json.loads(raw)
    except ValueError as exc:
        preview = raw[:240].replace("\n", " ")
        raise ValueError("invalid JSON in %s: %s; preview=%s" % (path, exc, preview))


def node_type_id(node):
    if not node:
        return None
    if node.get("nodeTypeId") not in (None, ""):
        try:
            return int(node.get("nodeTypeId"))
        except (TypeError, ValueError):
            pass
    nt = node.get("nodeType") or {}
    for key in ("nodeTypeId", "id"):
        if nt.get(key) not in (None, ""):
            try:
                return int(nt.get(key))
            except (TypeError, ValueError):
                continue
    return None


def node_type_name(node):
    if not node:
        return "Unknown"
    nt = node.get("nodeType") or {}
    name = nt.get("nodeTypeName")
    if name:
        return str(name).strip()
    tid = node_type_id(node)
    return known_type_name(tid)


def known_type_name(type_id):
    return {
        MSISDN_TYPE_ID: "MSISDN",
        DEVICE_TYPE_ID: "Device",
        USER_TYPE_ID: "User",
        ID_TYPE_ID: "ID",
        WALLET_STATUS_TYPE_ID: "Wallet Status",
        LINE_STATUS_TYPE_ID: "Line Status",
        WALLET_PROFILE_TYPE_ID: "Wallet Profile",
    }.get(type_id, "type-%s" % type_id)


def node_name(node):
    if not node:
        return ""
    for key in ("nodeName", "label"):
        val = node.get(key)
        if val not in (None, ""):
            return str(val).strip()
    node_id = node.get("nodeId") or node.get("id") or ""
    if isinstance(node_id, str) and "_" in node_id:
        return node_id.split("_", 1)[1].strip()
    return str(node_id).strip()


def short_name(value, limit=48):
    text = _BR_RE.split(str(value or ""), 1)[0].strip()
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def line_status_parts(value):
    text = str(value or "").replace("\r", "").strip()
    if not text:
        return "", ""
    head = _BR_RE.split(text, 1)[0].strip()
    if "_" in head:
        status, reason = head.split("_", 1)
        return status.strip(), reason.strip()
    return head, ""


def request_inputs(req):
    groups = []
    if not req:
        return groups
    for group in req.get("nodes") or []:
        raw_type = group.get("nodeType") or group.get("id") or ""
        try:
            type_id = int(raw_type)
        except (TypeError, ValueError):
            type_id = MSISDN_TYPE_ID
        values = []
        seen = set()
        for item in str(group.get("nodes") or "").replace("\r", "\n").split("\n"):
            item = item.strip()
            if item and item not in seen:
                seen.add(item)
                values.append(item)
        groups.append(
            {
                "type_id": type_id,
                "type_name": group.get("text") or known_type_name(type_id),
                "values": values,
            }
        )
    return groups


def input_name_set(groups):
    names = set()
    by_type = defaultdict(set)
    for group in groups:
        for name in group["values"]:
            names.add(name)
            by_type[group["type_id"]].add(name)
    return names, by_type


def vertices(data):
    return data.get("vertices") or []


def edges(data):
    return data.get("edges") or []


def edge_count(edge):
    info = edge.get("edgeInfo") or {}
    try:
        n = int(info.get("totalCount") or 1)
    except (TypeError, ValueError):
        n = 1
    return n if n > 0 else 1


def link_meta(edge):
    lt = edge.get("linkType") or {}
    lid = edge.get("linkTypeID") or edge.get("linkTypeId") or lt.get("linkTypeId") or lt.get("id")
    try:
        lid = int(lid)
    except (TypeError, ValueError):
        lid = lid or 0
    name = lt.get("linkTypeName") or lt.get("alias") or ("link-%s" % lid)
    alias = lt.get("alias") or ""
    return lid, str(name), str(alias)


def directed_names(edge):
    node_a = edge.get("nodeA")
    node_b = edge.get("nodeB")
    name_a = node_name(node_a)
    name_b = node_name(node_b)
    direction = edge.get("direction")
    try:
        direction = int(direction)
    except (TypeError, ValueError):
        direction = 1
    if direction == 2:
        return name_b, name_a, node_type_id(node_b), node_type_id(node_a)
    return name_a, name_b, node_type_id(node_a), node_type_id(node_b)


def classify_link(type_a, type_b, unique_dest, n_edges):
    if type_a == type_b:
        return "peer"
    if type_b in VALUE_TYPE_IDS or type_a in VALUE_TYPE_IDS:
        return "value"
    if (
        type_b not in IDENTITY_TYPE_IDS
        and unique_dest
        and unique_dest <= 25
        and unique_dest * 3 < max(n_edges, 1)
    ):
        return "value"
    return "identity"


def top_items(counter, top_n):
    items = counter.most_common()
    shown = items[:top_n]
    rest = items[top_n:]
    rest_n = sum(n for _k, n in rest)
    return shown, len(rest), rest_n


def fmt_counts(pairs):
    parts = ["%s %s" % (n, short_name(name)) for name, n in pairs]
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]
    if len(parts) == 2:
        return "%s and %s" % (parts[0], parts[1])
    return "%s, and %s" % (", ".join(parts[:-1]), parts[-1])


def friendly_link_name(name, alias):
    """Prefer the on-screen link text; skip generic aliases like Has."""
    generic = {"", "has", "has a", "contains", "is", "of"}
    alias = (alias or "").strip()
    if alias and alias.lower() not in generic:
        return alias
    return name or "Link"


def coverage_line(linked, total):
    if not total:
        return "  No starting numbers were given."
    if linked == total:
        return "  All %s starting numbers have this link." % total
    if linked == 0:
        return "  None of the %s starting numbers have this link." % total
    return "  %s of %s starting numbers have this link." % (linked, total)


def pair_word(n):
    return "pair" if n == 1 else "pairs"


def census_nodes(data, input_names):
    by_type = defaultdict(list)
    for vertex in vertices(data):
        tid = node_type_id(vertex)
        by_type[tid].append(vertex)
    rows = []
    for tid, verts in sorted(by_type.items(), key=lambda kv: (-len(kv[1]), kv[0] or 0)):
        names = [node_name(v) for v in verts]
        tname = node_type_name(verts[0]) if verts else known_type_name(tid)
        roots = sum(1 for v in verts if v.get("root") or v.get("highlight"))
        in_input = sum(1 for n in names if n in input_names)
        isolated = sum(1 for v in verts if int(v.get("neighboursCount") or 0) == 0)
        rows.append(
            {
                "type_id": tid,
                "type_name": tname,
                "count": len(verts),
                "roots": roots,
                "in_input": in_input,
                "isolated": isolated,
            }
        )
    return rows


def group_edges(data):
    groups = defaultdict(list)
    for edge in edges(data):
        lid, name, alias = link_meta(edge)
        groups[(lid, name, alias)].append(edge)
    return groups


def summarize_value_link(kind_edges, input_names, top_n):
    value_counter = Counter()
    status_counter = Counter()
    reason_counter = Counter()
    linked_inputs = set()
    dest_is_line = False
    dest_type_name = "value"
    raw_dests = set()
    parsed_combos = set()
    for edge in kind_edges:
        src, dst, type_src, type_dst = directed_names(edge)
        if type_src in VALUE_TYPE_IDS and type_dst not in VALUE_TYPE_IDS:
            src, dst, type_src, type_dst = dst, src, type_dst, type_src
        dest_type_name = known_type_name(type_dst)
        raw_dests.add(dst)
        if type_dst == LINE_STATUS_TYPE_ID:
            dest_is_line = True
            status, reason = line_status_parts(dst)
            label = status or dst
            value_counter[label] += 1
            if status:
                status_counter[status] += 1
            if reason:
                reason_counter[reason] += 1
            parsed_combos.add((status or dst, reason))
        else:
            value_counter[dst] += 1
            parsed_combos.add((dst, ""))
        if src in input_names:
            linked_inputs.add(src)
    lines = []
    shown, extra_kinds, extra_n = top_items(value_counter, top_n)
    if dest_is_line and status_counter:
        shown_s, extra_s, extra_sn = top_items(status_counter, top_n)
        lines.append(
            "  Status: %s%s."
            % (
                fmt_counts(shown_s),
                (" and %s more" % extra_s) if extra_s else "",
            )
        )
        if reason_counter:
            shown_r, extra_r, _n = top_items(reason_counter, top_n)
            lines.append(
                "  Suspension reasons: %s%s."
                % (
                    fmt_counts(shown_r),
                    (" and %s more reasons" % extra_r) if extra_r else "",
                )
            )
        lines.append(
            "  There are %s different %s nodes. "
            "The time on a Suspended label makes each one a separate node."
            % (len(raw_dests), dest_type_name)
        )
        lines.append(
            "  If we ignore the time, there are %s different statuses."
            % len(parsed_combos)
        )
    else:
        lines.append(
            "  Values: %s%s."
            % (
                fmt_counts(shown),
                (" and %s more (%s links)" % (extra_kinds, extra_n)) if extra_kinds else "",
            )
        )
        if raw_dests:
            lines.append(
                "  There are %s different %s nodes."
                % (len(raw_dests), dest_type_name)
            )
    if input_names:
        lines.append(coverage_line(len(linked_inputs), len(input_names)))
    return lines


def summarize_identity_link(kind_edges, input_names, top_n):
    partner_of = defaultdict(Counter)
    shared = defaultdict(set)
    linked_inputs = set()
    for edge in kind_edges:
        src, dst, type_src, type_dst = directed_names(edge)
        if src in input_names:
            linked_inputs.add(src)
            partner_of[src][dst] += edge_count(edge)
            shared[dst].add(src)
        if dst in input_names:
            linked_inputs.add(dst)
            partner_of[dst][src] += edge_count(edge)
            shared[src].add(dst)
    lines = [coverage_line(len(linked_inputs), len(input_names) or 0)]
    common = [
        (name, sorted(members))
        for name, members in shared.items()
        if name not in input_names and len(members) >= 2
    ]
    common.sort(key=lambda row: (-len(row[1]), row[0]))
    if common:
        lines.append("  Shared nodes (linked to 2 or more starting numbers):")
        for name, members in common[:top_n]:
            preview = ", ".join(members[:6])
            if len(members) > 6:
                preview += ", ..."
            lines.append(
                "    %s is linked to %s starting numbers (%s)."
                % (short_name(name), len(members), preview)
            )
        if len(common) > top_n:
            lines.append("    ... and %s more shared nodes." % (len(common) - top_n))
    else:
        lines.append("  No node is shared by two or more starting numbers.")
    isolated = [n for n in sorted(input_names) if n not in linked_inputs]
    if isolated:
        preview = ", ".join(isolated[:top_n])
        extra = "" if len(isolated) <= top_n else " and %s more" % (len(isolated) - top_n)
        lines.append(
            "  Starting numbers with no link of this kind: %s%s." % (preview, extra)
        )
    return lines


def summarize_peer_link(kind_edges, input_names, top_n):
    direct = []
    linked_inputs = set()
    neighbor_to_inputs = defaultdict(set)
    out_of_input = Counter()
    in_to_input = Counter()
    for edge in kind_edges:
        src, dst, _ta, _tb = directed_names(edge)
        n = edge_count(edge)
        src_in = src in input_names
        dst_in = dst in input_names
        if src_in:
            linked_inputs.add(src)
        if dst_in:
            linked_inputs.add(dst)
        if src_in and dst_in:
            direct.append((src, dst, n))
        elif src_in and not dst_in:
            neighbor_to_inputs[dst].add(src)
            out_of_input[src] += n
        elif dst_in and not src_in:
            neighbor_to_inputs[src].add(dst)
            in_to_input[dst] += n
        else:
            if src_in:
                neighbor_to_inputs[dst].add(src)
            if dst_in:
                neighbor_to_inputs[src].add(dst)
    total = len(input_names) or 0
    linked = len(linked_inputs)
    if not total:
        lines = ["  No starting numbers were given."]
    elif linked == total:
        lines = ["  All %s starting numbers appear in these links." % total]
    elif linked == 0:
        lines = ["  None of the %s starting numbers appear in these links." % total]
    else:
        lines = [
            "  %s of %s starting numbers appear in these links." % (linked, total)
        ]
    if direct:
        direct.sort(key=lambda row: (-row[2], row[0], row[1]))
        lines.append(
            "  Direct links between starting numbers: %s %s."
            % (len(direct), pair_word(len(direct)))
        )
        for src, dst, n in direct[:top_n]:
            extra = " (%s times)" % n if n > 1 else ""
            lines.append("    %s -> %s%s" % (src, dst, extra))
        if len(direct) > top_n:
            lines.append("    ... and %s more direct pairs." % (len(direct) - top_n))
    else:
        lines.append("  No direct links between the starting numbers.")

    common = [
        (name, sorted(members))
        for name, members in neighbor_to_inputs.items()
        if len(members) >= 2
    ]
    common.sort(key=lambda row: (-len(row[1]), row[0]))
    if common:
        lines.append(
            "  Shared outside numbers (2 or more starting numbers link to the same number):"
        )
        for name, members in common[:top_n]:
            preview = ", ".join(members[:6])
            if len(members) > 6:
                preview += ", ..."
            lines.append(
                "    %s is linked to %s starting numbers (%s)."
                % (short_name(name), len(members), preview)
            )
        if len(common) > top_n:
            lines.append("    ... and %s more shared numbers." % (len(common) - top_n))
    else:
        lines.append("  No shared outside numbers among the starting list.")

    isolated = [n for n in sorted(input_names) if n not in linked_inputs]
    if isolated:
        preview = ", ".join(isolated[:top_n])
        extra = "" if len(isolated) <= top_n else " and %s more" % (len(isolated) - top_n)
        lines.append(
            "  Starting numbers with no link of this kind: %s%s." % (preview, extra)
        )
    return lines


def build_summary(req, data, top_n=TOP_N_DEFAULT):
    req = req or {}
    data = data or {}
    groups = request_inputs(req)
    input_names, _by_type = input_name_set(groups)
    if not input_names:
        for vertex in vertices(data):
            if vertex.get("root") or vertex.get("highlight"):
                input_names.add(node_name(vertex))

    lines = []
    lines.append("=" * 64)
    lines.append("GLC network report")
    lines.append("=" * 64)

    date_from = req.get("dateFrom") or ""
    date_to = req.get("dateTo") or ""
    depth = req.get("graphDepth")
    if date_from or date_to:
        lines.append("Period: %s to %s" % (date_from, date_to))
    try:
        depth_n = int(depth)
    except (TypeError, ValueError):
        depth_n = None
    if depth_n == 1:
        lines.append("Scope: direct links only (one step from the starting list).")
    elif depth_n:
        lines.append(
            "Scope: up to %s steps from the starting list." % depth_n
        )
    if groups:
        for group in groups:
            preview = ", ".join(group["values"][:8])
            extra = ""
            if len(group["values"]) > 8:
                extra = ", ... (%s in total)" % len(group["values"])
            lines.append(
                "Starting %s list (%s): %s%s"
                % (group["type_name"], len(group["values"]), preview, extra)
            )
    else:
        lines.append("Starting list: none in the request; using highlighted nodes from the result.")
    lines.append("")

    code = data.get("responseCode")
    warn = data.get("warningMsg")
    n_nodes = len(vertices(data))
    n_links = len(edges(data))
    if code in (0, "0", None):
        result = "OK"
    else:
        result = "not OK (code %s)" % code
    result_line = "Result: %s. %s nodes, %s links." % (result, n_nodes, n_links)
    if warn:
        result_line += " Note: %s" % warn
    lines.append(result_line)
    if not n_nodes and not n_links:
        lines.append("")
        lines.append("This search returned no nodes and no links.")
        lines.append("=" * 64)
        return "\n".join(lines) + "\n"

    lines.append("")
    lines.append("----- NODES -----")
    for row in census_nodes(data, input_names):
        bits = []
        if row["in_input"] and row["in_input"] == row["count"]:
            bits.append("all %s were in the starting list" % row["in_input"])
        elif row["in_input"]:
            bits.append("%s were in the starting list" % row["in_input"])
        extra_nodes = row["count"] - row["in_input"]
        if extra_nodes > 0 and row["type_id"] not in VALUE_TYPE_IDS:
            bits.append("%s extra" % extra_nodes)
        if row["isolated"]:
            bits.append("%s with no links" % row["isolated"])
        suffix = " (%s)" % ", ".join(bits) if bits else ""
        lines.append(
            "%s %s nodes%s."
            % (row["count"], row["type_name"], suffix)
        )
        if row["type_id"] == LINE_STATUS_TYPE_ID:
            lines.append(
                "  These are status labels, not one node per number. "
                "If several numbers are Active, they share one Active node. "
                "If numbers are Suspended at different times, each time is a separate node."
            )
        elif row["type_id"] in VALUE_TYPE_IDS:
            lines.append(
                "  These are shared labels, not one node per number. "
                "Several numbers can share the same %s node."
                % row["type_name"]
            )

    edge_groups = group_edges(data)
    lines.append("")
    lines.append("----- LINKS -----")
    if not edge_groups:
        lines.append("There are no links in this result.")
    for (lid, name, alias), kind_edges in sorted(
        edge_groups.items(), key=lambda kv: (-len(kv[1]), kv[0][1])
    ):
        type_pairs = Counter()
        dest_names = set()
        for edge in kind_edges:
            src, dst, ta, tb = directed_names(edge)
            type_pairs[(ta, tb)] += 1
            dest_names.add(dst)
        (ta, tb), _n = type_pairs.most_common(1)[0]
        kind = classify_link(ta, tb, len(dest_names), len(kind_edges))
        title = friendly_link_name(name, alias)
        n_kind = len(kind_edges)
        link_word = "link" if n_kind == 1 else "links"
        lines.append("")
        lines.append(title)
        lines.append(
            "  %s %s from %s to %s."
            % (n_kind, link_word, known_type_name(ta), known_type_name(tb))
        )
        if kind == "value":
            lines.extend(summarize_value_link(kind_edges, input_names, top_n))
        elif kind == "peer":
            lines.extend(summarize_peer_link(kind_edges, input_names, top_n))
        else:
            lines.extend(summarize_identity_link(kind_edges, input_names, top_n))

    lines.append("")
    lines.append("=" * 64)
    return "\n".join(lines) + "\n"


def apply_request_dates(req, date_from, date_to):
    if not req:
        return req
    out = json.loads(json.dumps(req))
    if date_from:
        out["dateFrom"] = date_from
    if date_to:
        out["dateTo"] = date_to
    return out


def cmd_summarize(args):
    req = load_json(args.request) if args.request else {}
    if args.date_from or args.date_to:
        req = apply_request_dates(req, args.date_from, args.date_to)
    data = load_json(args.response)
    text = build_summary(req, data, top_n=args.top_n)
    if args.out and args.out != "-":
        with open(args.out, "w") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)


def _sample_line_status():
    return {
        "responseCode": 0,
        "vertices": [
            {"nodeName": "201000000001", "nodeTypeId": 1, "root": True,
             "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"}},
            {"nodeName": "201000000002", "nodeTypeId": 1, "root": True,
             "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"}},
            {"nodeName": "201000000003", "nodeTypeId": 1, "root": True,
             "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"}},
            {"nodeName": "Active", "nodeTypeId": 1160,
             "nodeType": {"nodeTypeId": 1160, "nodeTypeName": "Line Status"}},
            {"nodeName": "Suspended_Fraud<br>2026-08-30 14:23:05", "nodeTypeId": 1160,
             "nodeType": {"nodeTypeId": 1160, "nodeTypeName": "Line Status"}},
        ],
        "edges": [
            {
                "linkTypeID": 371,
                "linkType": {"linkTypeId": 371, "linkTypeName": "MSISDN-Line Status"},
                "nodeA": {"nodeName": "201000000001", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Active", "nodeTypeId": 1160},
            },
            {
                "linkTypeID": 371,
                "linkType": {"linkTypeId": 371, "linkTypeName": "MSISDN-Line Status"},
                "nodeA": {"nodeName": "201000000002", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Suspended_Fraud<br>2026-08-30 14:23:05", "nodeTypeId": 1160},
            },
            {
                "linkTypeID": 371,
                "linkType": {"linkTypeId": 371, "linkTypeName": "MSISDN-Line Status"},
                "nodeA": {"nodeName": "201000000003", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Suspended_Fraud<br>2026-08-30 14:23:05", "nodeTypeId": 1160},
            },
        ],
    }


def _sample_voicecall():
    def msisdn(name, root=False):
        return {
            "nodeName": name,
            "nodeTypeId": 1,
            "root": root,
            "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
        }

    def call(a, b, count=1):
        return {
            "direction": 1,
            "linkTypeID": 7,
            "linkType": {"linkTypeId": 7, "linkTypeName": "VoiceCall", "alias": "VoiceCall"},
            "edgeInfo": {"totalCount": count, "label": "VoiceCall"},
            "nodeA": {"nodeName": a, "nodeTypeId": 1},
            "nodeB": {"nodeName": b, "nodeTypeId": 1},
        }

    return {
        "responseCode": 0,
        "vertices": [
            msisdn("201111111111", True),
            msisdn("201222222222", True),
            msisdn("201333333333", True),
            msisdn("201999999999", False),
        ],
        "edges": [
            call("201111111111", "201222222222", 12),
            call("201222222222", "201111111111", 3),
            call("201111111111", "201999999999", 5),
            call("201222222222", "201999999999", 2),
        ],
    }


def cmd_selftest(_args):
    req = {
        "graphDepth": 1,
        "dateFrom": "2026/07/15 00:00:00",
        "dateTo": "2026/09/01 23:59:59",
        "linkTypeCat": 371,
        "dispTypes": "1,1160",
        "nodes": [{"id": "1", "nodeType": "1", "nodes": "201000000001\n201000000002\n201000000003", "text": "MSISDN"}],
    }
    text = build_summary(req, _sample_line_status(), top_n=8)
    assert "3 MSISDN nodes" in text, text
    assert "2 Line Status nodes" in text, text
    assert "not one node per number" in text, text
    assert "There are 2 different Line Status nodes" in text, text
    assert "If we ignore the time, there are 2 different statuses" in text, text
    assert "Active" in text
    assert "Fraud" in text
    assert "Suspended" in text
    assert "linkTypeId" not in text, text
    assert "edges" not in text.lower(), text

    vreq = {
        "graphDepth": 1,
        "linkTypeCat": 7,
        "dispTypes": "1",
        "nodes": [{"id": "1", "nodeType": "1", "nodes": "201111111111\n201222222222\n201333333333", "text": "MSISDN"}],
    }
    vtext = build_summary(vreq, _sample_voicecall(), top_n=8)
    assert "VoiceCall" in vtext, vtext
    assert "Direct links between starting numbers: 2 pairs." in vtext, vtext
    assert "201111111111 -> 201222222222 (12 times)" in vtext, vtext
    assert "201999999999" in vtext
    assert "201333333333" in vtext
    assert "Starting numbers with no link of this kind" in vtext
    assert "linkTypeId" not in vtext, vtext
    print("selftest_ok")


def build_parser():
    parser = argparse.ArgumentParser(description="Summarize a GLC graph response")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("summarize")
    p.add_argument("--request", help="GLC request JSON (optional but recommended)")
    p.add_argument("--response", required=True, help="GLC response JSON")
    p.add_argument("--out", default="-")
    p.add_argument("--top-n", type=int, default=TOP_N_DEFAULT)
    p.add_argument("--date-from")
    p.add_argument("--date-to")
    p.set_defaults(func=cmd_summarize)

    p = sub.add_parser("selftest")
    p.set_defaults(func=cmd_selftest)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.error("command required (summarize | selftest)")
    args.func(args)


if __name__ == "__main__":
    main()
