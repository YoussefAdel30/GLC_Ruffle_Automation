#!/usr/bin/env python3
"""Build a short business story of a GLC graph response.

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
RATE_PLAN_TYPE_ID = 1180

VALUE_TYPE_IDS = {
    WALLET_PROFILE_TYPE_ID,
    WALLET_STATUS_TYPE_ID,
    LINE_STATUS_TYPE_ID,
    RATE_PLAN_TYPE_ID,
}
IDENTITY_TYPE_IDS = {
    MSISDN_TYPE_ID,
    DEVICE_TYPE_ID,
    USER_TYPE_ID,
    ID_TYPE_ID,
}

_BR_RE = re.compile(r"<br\s*/?>", re.IGNORECASE)
TOP_N_DEFAULT = 8
MAX_DISTINCT_VALUES = 100


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
        RATE_PLAN_TYPE_ID: "Rate Plan",
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


try:
    from urllib.parse import unquote
except ImportError:
    from urllib import unquote


_MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)


def decode_form_value(value):
    text = str(value or "")
    if not text:
        return ""
    try:
        text = unquote(text.replace("+", " "))
    except Exception:
        return str(value)
    if "%" in text:
        try:
            text = unquote(text)
        except Exception:
            pass
    return text


def format_period(value):
    text = decode_form_value(value).strip()
    if not text:
        return ""
    m = re.match(
        r"^(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?",
        text,
    )
    if not m:
        return text
    month_i = int(m.group(2)) - 1
    month = _MONTHS[month_i] if 0 <= month_i < 12 else m.group(2)
    day = str(int(m.group(3)))
    out = "%s %s %s" % (day, month, m.group(1))
    if m.group(4):
        out += ", %s:%s:%s" % (m.group(4), m.group(5), m.group(6) or "00")
    return out


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


def display_value(name):
    text = _BR_RE.sub(" ", str(name or "")).strip()
    return re.sub(r"\s+", " ", text)


def format_unique_counts(counter, limit=MAX_DISTINCT_VALUES):
    items = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    extra = 0
    if len(items) > limit:
        extra = len(items) - limit
        items = items[:limit]
    parts = ["%s %s" % (n, display_value(name)) for name, n in items]
    if not parts:
        return ""
    text = ", ".join(parts)
    if extra:
        text += ", and %s more" % extra
    return text


def capped(items, limit=MAX_DISTINCT_VALUES):
    extra = 0
    if len(items) > limit:
        extra = len(items) - limit
        items = items[:limit]
    return items, extra


def join_capped(items, limit=MAX_DISTINCT_VALUES):
    shown, extra = capped(list(items), limit)
    if extra:
        return "%s, and %s more" % (", ".join(shown), extra)
    return join_and(shown)


def join_and(items):
    items = [str(x) for x in items if x not in (None, "")]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return "%s and %s" % (items[0], items[1])
    return "%s, and %s" % (", ".join(items[:-1]), items[-1])


def type_catalog(data):
    names = {}

    def add(tid, tname):
        if tid is None or tname in (None, ""):
            return
        try:
            tid = int(tid)
        except (TypeError, ValueError):
            return
        names[tid] = str(tname).strip()

    for nt in data.get("nodeTypes") or []:
        add(nt.get("nodeTypeId") if nt.get("nodeTypeId") not in (None, "") else nt.get("id"), nt.get("nodeTypeName"))
    for vertex in vertices(data):
        nt = vertex.get("nodeType") or {}
        add(node_type_id(vertex), nt.get("nodeTypeName"))
    for edge in edges(data):
        for node in (edge.get("nodeA"), edge.get("nodeB")):
            if not node:
                continue
            nt = node.get("nodeType") or {}
            add(node_type_id(node), nt.get("nodeTypeName"))
    return names


def type_label(tid, catalog):
    if tid in catalog:
        return catalog[tid]
    return known_type_name(tid)


def friendly_link_name(name, alias):
    """Prefer the on-screen link text; skip generic aliases like Has."""
    generic = {"", "has", "has a", "contains", "is", "of"}
    alias = (alias or "").strip()
    if alias and alias.lower() not in generic:
        return alias
    return name or "Link"


def coverage_story(linked, total):
    if not total:
        return "No starting list was given."
    if linked == total:
        if total == 1:
            return "The starting number has this kind of link."
        return "Every starting number has this kind of link."
    if linked == 0:
        return "None of the starting numbers have this kind of link."
    return "%s of the %s starting numbers have this kind of link." % (linked, total)


def looks_like_call(name, alias):
    text = ("%s %s" % (name or "", alias or "")).lower()
    return "voice" in text or "call" in text


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
                "names": names,
            }
        )
    return rows


def group_edges(data):
    groups = defaultdict(list)
    for edge in edges(data):
        lid, name, alias = link_meta(edge)
        groups[(lid, name, alias)].append(edge)
    return groups


def summarize_value_link(kind_edges, input_names):
    linked_inputs = set()
    value_counter = Counter()
    for edge in kind_edges:
        src, dst, type_src, type_dst = directed_names(edge)
        if type_src in VALUE_TYPE_IDS and type_dst not in VALUE_TYPE_IDS:
            src, dst, type_src, type_dst = dst, src, type_dst, type_src
        value_counter[dst] += 1
        if src in input_names:
            linked_inputs.add(src)
    lines = [coverage_story(len(linked_inputs), len(input_names))]
    listed = format_unique_counts(value_counter)
    if listed:
        lines.append("Values: %s." % listed)
    isolated = [n for n in sorted(input_names) if n not in linked_inputs]
    if isolated:
        lines.append(
            "Starting numbers with no link of this kind: %s." % join_capped(isolated)
        )
    return lines


def summarize_identity_link(kind_edges, input_names):
    shared = defaultdict(set)
    linked_inputs = set()
    rels = []
    seen_rel = set()
    for edge in kind_edges:
        src, dst, _ta, _tb = directed_names(edge)
        if src in input_names:
            linked_inputs.add(src)
            shared[dst].add(src)
            if dst not in input_names:
                key = (src, dst)
                if key not in seen_rel:
                    seen_rel.add(key)
                    rels.append(key)
        if dst in input_names:
            linked_inputs.add(dst)
            shared[src].add(dst)
            if src not in input_names:
                key = (dst, src)
                if key not in seen_rel:
                    seen_rel.add(key)
                    rels.append(key)
    lines = [coverage_story(len(linked_inputs), len(input_names) or 0)]
    rels, extra_rels = capped(rels)
    for start, partner in rels:
        lines.append("The starting number %s is linked to %s." % (start, partner))
    if extra_rels:
        lines.append("and %s more." % extra_rels)
    common = [
        (name, sorted(members))
        for name, members in shared.items()
        if name not in input_names and len(members) >= 2
    ]
    common.sort(key=lambda row: (-len(row[1]), row[0]))
    if common:
        lines.append("These nodes are linked to two or more starting numbers:")
        common, extra_common = capped(common)
        for name, members in common:
            lines.append("%s is linked to %s." % (name, join_and(members)))
        if extra_common:
            lines.append("and %s more." % extra_common)
    elif input_names:
        lines.append("No node is shared by two or more starting numbers.")
    isolated = [n for n in sorted(input_names) if n not in linked_inputs]
    if isolated:
        lines.append(
            "Starting numbers with no link of this kind: %s." % join_capped(isolated)
        )
    return lines


def summarize_peer_link(kind_edges, input_names, title):
    direct = []
    linked_inputs = set()
    neighbor_to_inputs = defaultdict(set)
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
        elif dst_in and not src_in:
            neighbor_to_inputs[src].add(dst)
    total = len(input_names) or 0
    linked = len(linked_inputs)
    if not total:
        lines = ["No starting list was given."]
    elif linked == total:
        lines = ["Every starting number appears in these links."]
    elif linked == 0:
        lines = ["None of the starting numbers appear in these links."]
    else:
        lines = [
            "%s of the %s starting numbers appear in these links." % (linked, total)
        ]
    callish = looks_like_call(title, "")
    if direct:
        direct.sort(key=lambda row: (-row[2], row[0], row[1]))
        if callish:
            lines.append("These starting numbers called each other:")
        else:
            lines.append("These starting numbers are linked to each other:")
        direct, extra_direct = capped(direct)
        for src, dst, n in direct:
            extra = " (%s times)" % n if n > 1 else ""
            if callish:
                lines.append("%s called %s%s." % (src, dst, extra))
            else:
                lines.append("%s → %s%s." % (src, dst, extra))
        if extra_direct:
            lines.append("and %s more." % extra_direct)
    elif input_names:
        lines.append("There are no direct links between the starting numbers.")

    common = [
        (name, sorted(members))
        for name, members in neighbor_to_inputs.items()
        if len(members) >= 2
    ]
    common.sort(key=lambda row: (-len(row[1]), row[0]))
    if common:
        if len(common) == 1:
            lines.append("They also share an outside number:")
        else:
            lines.append("They also share outside numbers:")
        common, extra_common = capped(common)
        for name, members in common:
            lines.append("%s is linked to %s." % (name, join_and(members)))
        if extra_common:
            lines.append("and %s more." % extra_common)
    elif input_names:
        lines.append("They do not share an outside number among the starting list.")

    isolated = [n for n in sorted(input_names) if n not in linked_inputs]
    if isolated:
        lines.append(
            "Starting numbers with no link of this kind: %s." % join_capped(isolated)
        )
    return lines


def build_summary(req, data, top_n=TOP_N_DEFAULT):
    req = req or {}
    data = data or {}
    _ = top_n
    catalog = type_catalog(data)
    groups = request_inputs(req)
    input_names, _by_type = input_name_set(groups)
    if not input_names:
        for vertex in vertices(data):
            if vertex.get("root") or vertex.get("highlight"):
                input_names.add(node_name(vertex))

    lines = []
    date_from = format_period(req.get("dateFrom") or "")
    date_to = format_period(req.get("dateTo") or "")
    try:
        depth_n = int(req.get("graphDepth"))
    except (TypeError, ValueError):
        depth_n = None

    open_bits = []
    if groups:
        parts = []
        for group in groups:
            n = len(group["values"])
            label = group["type_name"]
            unit = "number" if n == 1 else "numbers"
            if label != "MSISDN":
                unit = "item" if n == 1 else "items"
            parts.append(
                "%s %s %s (%s)" % (n, label, unit, join_capped(group["values"]))
            )
        open_bits.append("This search looked at %s" % join_and(parts))
    elif input_names:
        highlighted = sorted(input_names)
        unit = "number" if len(highlighted) == 1 else "numbers"
        open_bits.append(
            "This search used %s highlighted %s from the graph (%s)"
            % (len(highlighted), unit, join_capped(highlighted))
        )
    else:
        open_bits.append("This search had no starting list in the request")
    if date_from or date_to:
        open_bits.append("from %s to %s" % (date_from, date_to))
    opener = " ".join(open_bits) + "."
    if depth_n == 1:
        opener += " It only followed direct links (one step from the starting list)."
    elif depth_n:
        opener += " It followed up to %s steps from the starting list." % depth_n
    lines.append(opener)

    code = data.get("responseCode")
    warn = data.get("warningMsg")
    n_nodes = len(vertices(data))
    n_links = len(edges(data))
    if code in (0, "0", None):
        result = "The result came back OK."
    else:
        result = "The result did not come back OK (code %s)." % code
    node_word = "node" if n_nodes == 1 else "nodes"
    link_word = "link" if n_links == 1 else "links"
    result += " The graph has %s %s and %s %s." % (n_nodes, node_word, n_links, link_word)
    if warn:
        result += " Note: %s" % warn
    lines.append("")
    lines.append(result)
    if not n_nodes and not n_links:
        lines.append("")
        lines.append("This search returned no nodes and no links.")
        return "\n".join(lines) + "\n"

    lines.append("")
    lines.append("What is in the graph")
    for row in census_nodes(data, input_names):
        n = row["count"]
        tname = row["type_name"] or type_label(row["type_id"], catalog)
        if n == 1:
            head = "There is 1 %s node" % tname
        else:
            head = "There are %s %s nodes" % (n, tname)
        extras = []
        if row["in_input"] and row["in_input"] == n:
            extras.append("all of them were in the starting list" if n > 1 else "it was in the starting list")
        elif row["in_input"]:
            extras.append(
                "%s %s in the starting list"
                % (row["in_input"], "was" if row["in_input"] == 1 else "were")
            )
        extra_nodes = n - row["in_input"]
        if extra_nodes > 0 and row["type_id"] not in VALUE_TYPE_IDS:
            if extra_nodes == n:
                extras.append(
                    "none of them were in the starting list" if n > 1 else "it was not in the starting list"
                )
            else:
                extras.append("%s extra" % extra_nodes)
        if row["isolated"]:
            if n == 1:
                extras.append("it has no links")
            else:
                extras.append("%s with no links" % row["isolated"])
        names_bit = ""
        if (
            row["type_id"] not in VALUE_TYPE_IDS
            and row["type_id"] != MSISDN_TYPE_ID
            and row.get("names")
        ):
            names_bit = " (%s)" % join_and(row["names"])
        suffix = ("; " + ", ".join(extras)) if extras else ""
        lines.append(head + names_bit + suffix + ".")
        if row["type_id"] == LINE_STATUS_TYPE_ID:
            lines.append(
                "These are status labels, not one node per number. "
                "If several numbers are Active, they share one Active node. "
                "If numbers are Suspended at different times, each time is a separate node."
            )
        elif row["type_id"] in VALUE_TYPE_IDS:
            lines.append(
                "These are shared labels, not one node per number. "
                "Several numbers can share the same %s node."
                % tname
            )

    edge_groups = group_edges(data)
    lines.append("")
    lines.append("How they are linked")
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
        lines.append("")
        lines.append(title)
        if kind == "value":
            lines.extend(summarize_value_link(kind_edges, input_names))
        elif kind == "peer":
            lines.extend(summarize_peer_link(kind_edges, input_names, title))
        else:
            lines.extend(summarize_identity_link(kind_edges, input_names))

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
    assert "3 MSISDN" in text, text
    assert "2 Line Status" in text, text
    assert "not one node per number" in text, text
    assert "Values:" in text, text
    assert "Active" in text
    assert "Suspended" in text
    assert "and 5 more" not in text, text
    assert "links from" not in text, text
    assert "type-" not in text, text
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
    assert "201111111111 called 201222222222" in vtext, vtext
    assert "201999999999" in vtext
    assert "201333333333" in vtext
    assert "Values:" not in vtext, vtext
    assert "linkTypeId" not in vtext, vtext

    assert format_period("2026%2F09%2F08%2000%3A00%3A00") == "8 Sep 2026, 00:00:00"
    assert format_period("2026/09/08 23:59:59") == "8 Sep 2026, 23:59:59"
    many = Counter()
    for i in range(101):
        many["plan-%03d" % i] = 1
    many_text = format_unique_counts(many)
    assert "and 1 more" in many_text, many_text
    assert many_text.count("plan-") == 100, many_text
    few = format_unique_counts(Counter({"Gold": 3, "Silver": 1}))
    assert few == "3 Gold, 1 Silver", few
    assert "more" not in few
    owns_req = {
        "graphDepth": 1,
        "dateFrom": "2026%2F09%2F08%2000%3A00%3A00",
        "dateTo": "2026%2F09%2F08%2023%3A59%3A59",
        "nodes": [{
            "id": "1",
            "nodeType": "1",
            "nodes": "201066257228",
            "text": "MSISDN",
        }],
    }
    owns_data = {
        "responseCode": 0,
        "vertices": [
            {
                "nodeName": "ADELY1",
                "nodeTypeId": 1001,
                "nodeType": {"nodeTypeId": 1001, "nodeTypeName": "User"},
            },
            {
                "nodeName": "201066257228",
                "nodeTypeId": 1,
                "root": True,
                "highlight": True,
                "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
            },
        ],
        "edges": [
            {
                "linkTypeID": 13,
                "linkType": {
                    "linkTypeId": 13,
                    "linkTypeName": "MSISDN-User",
                    "alias": "Owns",
                },
                "nodeA": {
                    "nodeName": "ADELY1",
                    "nodeTypeId": 1001,
                    "nodeType": {"nodeTypeId": 1001, "nodeTypeName": "User"},
                },
                "nodeB": {
                    "nodeName": "201066257228",
                    "nodeTypeId": 1,
                    "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
                },
            }
        ],
    }
    owns_text = build_summary(owns_req, owns_data)
    assert "8 Sep 2026, 00:00:00 to 8 Sep 2026, 23:59:59" in owns_text, owns_text
    assert "%2F" not in owns_text, owns_text
    assert "The graph has 2 nodes and 1 link." in owns_text, owns_text
    assert "ADELY1" in owns_text, owns_text
    assert "Owns" in owns_text, owns_text
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
