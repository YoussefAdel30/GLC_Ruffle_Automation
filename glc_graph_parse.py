#!/usr/bin/env python3
"""Helpers for building GLC request bodies and parsing graph JSON responses."""

from __future__ import print_function

import argparse
import json
import os
import sys


MSISDN_TYPE_ID = 1
USER_TYPE_ID = 1001
DEVICE_TYPE_ID = 1000
ID_TYPE_ID = 1003
WALLET_PROFILE_TYPE_ID = 1321
WALLET_STATUS_TYPE_ID = 1141
LINE_STATUS_TYPE_ID = 1160


def _load_json(path):
    with open(path, "r") as fh:
        raw = fh.read().strip()
    if not raw:
        raise ValueError("empty JSON file: %s" % path)
    try:
        return json.loads(raw)
    except ValueError as exc:
        preview = raw[:240].replace("\n", " ")
        raise ValueError("invalid JSON in %s: %s; preview=%s" % (path, exc, preview))


def _read_lines(path):
    if not path or path == "-":
        fh = sys.stdin
        close = False
    else:
        if not os.path.exists(path):
            return []
        fh = open(path, "r")
        close = True
    try:
        out = []
        seen = set()
        for line in fh:
            item = line.strip().replace("\r", "")
            if not item or item.startswith("#"):
                continue
            if item not in seen:
                seen.add(item)
                out.append(item)
        return out
    finally:
        if close:
            fh.close()


def _write_lines(path, items):
    text = "\n".join(items)
    if text:
        text += "\n"
    if path and path != "-":
        with open(path, "w") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)


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


def unique_preserve(items):
    seen = set()
    out = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


def vertices(data):
    return data.get("vertices") or []


def edges(data):
    return data.get("edges") or []


def summary(data):
    return {
        "responseCode": data.get("responseCode"),
        "warningMsg": data.get("warningMsg"),
        "vertexCount": len(vertices(data)),
        "edgeCount": len(edges(data)),
        "rootCount": len(data.get("rootNodes") or []),
    }


def nodes_of_type(data, type_id):
    names = []
    for vertex in vertices(data):
        if node_type_id(vertex) == type_id:
            name = node_name(vertex)
            if name:
                names.append(name)
    return unique_preserve(names)


def relation_pairs(data, from_type_id, to_type_id):
    pairs = []
    seen = set()
    for edge in edges(data):
        node_a = edge.get("nodeA")
        node_b = edge.get("nodeB")
        if not node_a or not node_b:
            continue
        type_a = node_type_id(node_a)
        type_b = node_type_id(node_b)
        name_a = node_name(node_a)
        name_b = node_name(node_b)
        if not name_a or not name_b:
            continue
        matched = []
        if type_a == from_type_id and type_b == to_type_id:
            matched.append((name_a, name_b))
        if type_b == from_type_id and type_a == to_type_id:
            matched.append((name_b, name_a))
        for pair in matched:
            if pair not in seen:
                seen.add(pair)
                pairs.append(pair)
    return pairs


def related_map(data, from_type_id, to_type_id):
    mapping = {}
    for src, dst in relation_pairs(data, from_type_id, to_type_id):
        mapping.setdefault(src, [])
        if dst not in mapping[src]:
            mapping[src].append(dst)
    return mapping


def _norm(value):
    return str(value or "").strip().casefold()


def exclude_if_related(data, from_type_id, to_type_id, candidates=None):
    """Return (src, related_values) for sources that have any related target node."""
    mapping = related_map(data, from_type_id, to_type_id)
    cand = set(candidates) if candidates is not None else None
    out = []
    for src, values in mapping.items():
        if cand is not None and src not in cand:
            continue
        if values:
            out.append((src, values))
    return out


def exclude_if_value(data, from_type_id, to_type_id, match_values, candidates=None):
    """Return (src, matched_values) when a related node name is in match_values."""
    wanted = set(_norm(v) for v in match_values if str(v).strip())
    mapping = related_map(data, from_type_id, to_type_id)
    cand = set(candidates) if candidates is not None else None
    out = []
    for src, values in mapping.items():
        if cand is not None and src not in cand:
            continue
        matched = [v for v in values if _norm(v) in wanted]
        if matched:
            out.append((src, matched, values))
    return out


def msisdns_with_any_relation(data, candidates=None):
    """Input MSISDNs that have any graph relation (edge or neighboursCount > 0)."""
    cand = set(candidates) if candidates is not None else None
    related = set()

    for edge in edges(data):
        for side in (edge.get("nodeA"), edge.get("nodeB")):
            if not side:
                continue
            if node_type_id(side) != MSISDN_TYPE_ID:
                continue
            name = node_name(side)
            if name and (cand is None or name in cand):
                related.add(name)

    for vertex in vertices(data):
        if node_type_id(vertex) != MSISDN_TYPE_ID:
            continue
        name = node_name(vertex)
        if not name or (cand is not None and name not in cand):
            continue
        if int(vertex.get("neighboursCount") or 0) > 0:
            related.add(name)

    if candidates is None:
        return unique_preserve(sorted(related))
    return [m for m in candidates if m in related]


def exclude_via_hop(first_pairs, second_pairs, candidates=None):
    """
    first_pairs: [(msisdn, id), ...]
    second_pairs: [(id, user), ...]
    Exclude msisdn if any of its ids has at least one user.
    """
    id_to_users = {}
    for ident, user in second_pairs:
        id_to_users.setdefault(ident, [])
        if user not in id_to_users[ident]:
            id_to_users[ident].append(user)

    msisdn_to_ids = {}
    for msisdn, ident in first_pairs:
        if candidates is not None and msisdn not in candidates:
            continue
        msisdn_to_ids.setdefault(msisdn, [])
        if ident not in msisdn_to_ids[msisdn]:
            msisdn_to_ids[msisdn].append(ident)

    excluded = []
    for msisdn, idents in msisdn_to_ids.items():
        hits = []
        for ident in idents:
            users = id_to_users.get(ident) or []
            if users:
                hits.append((ident, users))
        if hits:
            excluded.append((msisdn, hits))
    return excluded


def build_request(template, node_values, date_from=None, date_to=None):
    req = json.loads(json.dumps(template))
    if date_from:
        req["dateFrom"] = date_from
    if date_to:
        req["dateTo"] = date_to
    if not req.get("nodes"):
        raise ValueError("template is missing nodes[]")
    req["nodes"][0]["nodes"] = "\n".join(node_values)
    return req


def _parse_pairs(path):
    pairs = []
    for line in _read_lines(path):
        if "|" not in line:
            continue
        left, right = line.split("|", 1)
        left = left.strip()
        right = right.strip()
        if left and right:
            pairs.append((left, right))
    return pairs


def cmd_build_request(args):
    template = _load_json(args.template)
    nodes = _read_lines(args.nodes_file)
    req = build_request(template, nodes, args.date_from, args.date_to)
    text = json.dumps(req, indent=2)
    if args.out and args.out != "-":
        with open(args.out, "w") as fh:
            fh.write(text)
            fh.write("\n")
    else:
        print(text)


def cmd_summary(args):
    data = _load_json(args.response)
    info = summary(data)
    print(
        "responseCode=%s vertexCount=%s edgeCount=%s rootCount=%s warningMsg=%s"
        % (
            info["responseCode"],
            info["vertexCount"],
            info["edgeCount"],
            info["rootCount"],
            info["warningMsg"],
        )
    )


def cmd_relations(args):
    data = _load_json(args.response)
    candidates = _read_lines(args.candidates) if args.candidates else None
    cand = set(candidates) if candidates is not None else None
    for src, dst in relation_pairs(data, args.from_type, args.to_type):
        if cand is not None and src not in cand:
            continue
        print("%s|%s" % (src, dst))


def cmd_nodes(args):
    data = _load_json(args.response)
    _write_lines(args.out, nodes_of_type(data, args.type_id))


def cmd_exclude_if_related(args):
    data = _load_json(args.response)
    candidates = _read_lines(args.candidates) if args.candidates else None
    rows = exclude_if_related(data, args.from_type, args.to_type, candidates)
    for src, values in rows:
        print("%s|%s" % (src, ",".join(values)))


def collect_match_values(match_values=None, match_values_file=None):
    values = []
    if match_values:
        values.extend(v.strip() for v in str(match_values).split(",") if v.strip())
    if match_values_file:
        values.extend(_read_lines(match_values_file))
    return values


def cmd_exclude_if_value(args):
    data = _load_json(args.response)
    candidates = _read_lines(args.candidates) if args.candidates else None
    match_values = collect_match_values(args.match_values, args.match_values_file)
    rows = exclude_if_value(
        data, args.from_type, args.to_type, match_values, candidates
    )
    for src, matched, all_values in rows:
        print("%s|%s|%s" % (src, ",".join(matched), ",".join(all_values)))


def cmd_related_dump(args):
    data = _load_json(args.response)
    candidates = _read_lines(args.candidates) if args.candidates else None
    mapping = related_map(data, args.from_type, args.to_type)
    items = candidates if candidates is not None else sorted(mapping.keys())
    for src in items:
        values = mapping.get(src) or []
        print("%s|%s" % (src, ",".join(values) if values else ""))


def cmd_has_relation(args):
    data = _load_json(args.response)
    candidates = _read_lines(args.candidates) if args.candidates else None
    for name in msisdns_with_any_relation(data, candidates):
        print(name)


def cmd_exclude_via_hop(args):
    first_pairs = _parse_pairs(args.first_map)
    second_pairs = _parse_pairs(args.second_map)
    candidates = _read_lines(args.candidates) if args.candidates else None
    cand_set = set(candidates) if candidates is not None else None
    rows = exclude_via_hop(first_pairs, second_pairs, cand_set)
    for msisdn, hits in rows:
        details = []
        for ident, users in hits:
            details.append("%s->%s" % (ident, ",".join(users)))
        print("%s|%s" % (msisdn, ";".join(details)))


def cmd_unique(args):
    items = _read_lines(args.nodes_file)
    _write_lines(args.out, unique_preserve(items))


def _sample_msisdn_user():
    return {
        "responseCode": 0,
        "vertices": [
            {
                "label": "ADELY1",
                "nodeId": "1001_ADELY1",
                "nodeName": "ADELY1",
                "nodeTypeId": 1001,
                "neighboursCount": 1,
                "nodeType": {"nodeTypeId": 1001, "nodeTypeName": "User"},
            },
            {
                "label": "201066257228",
                "nodeId": "1_201066257228",
                "nodeName": "201066257228",
                "nodeTypeId": 1,
                "neighboursCount": 1,
                "highlight": True,
                "root": True,
                "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
            },
        ],
        "edges": [
            {
                "nodeA_ID": "1001_ADELY1",
                "nodeB_ID": "1_201066257228",
                "nodeA": {
                    "label": "ADELY1",
                    "nodeName": "ADELY1",
                    "nodeTypeId": 1001,
                    "nodeType": {"nodeTypeId": 1001, "nodeTypeName": "User"},
                },
                "nodeB": {
                    "label": "201066257228",
                    "nodeName": "201066257228",
                    "nodeTypeId": 1,
                    "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
                },
                "linkType": {"linkTypeName": "MSISDN-User", "alias": "Owns"},
            }
        ],
        "rootNodes": [{"nodeName": "201066257228", "nodeTypeId": 1}],
    }


def _sample_msisdn_id():
    return {
        "responseCode": 0,
        "vertices": [
            {
                "label": "201066257228",
                "nodeName": "201066257228",
                "nodeTypeId": 1,
                "neighboursCount": 1,
                "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
            },
            {
                "label": "30008300101556",
                "nodeName": "30008300101556",
                "nodeTypeId": 1003,
                "neighboursCount": 1,
                "nodeType": {"nodeTypeId": 1003, "nodeTypeName": "ID"},
            },
        ],
        "edges": [
            {
                "nodeA": {
                    "label": "201066257228",
                    "nodeName": "201066257228",
                    "nodeTypeId": 1,
                    "nodeType": {"nodeTypeId": 1, "nodeTypeName": "MSISDN"},
                },
                "nodeB": {
                    "label": "30008300101556",
                    "nodeName": "30008300101556",
                    "nodeTypeId": 1003,
                    "nodeType": {"nodeTypeId": 1003, "nodeTypeName": "ID"},
                },
            }
        ],
        "rootNodes": [{"nodeName": "201066257228", "nodeTypeId": 1}],
    }


def cmd_selftest(_args):
    user_graph = _sample_msisdn_user()
    info = summary(user_graph)
    assert info["vertexCount"] == 2, info
    assert info["edgeCount"] == 1, info
    pairs = relation_pairs(user_graph, MSISDN_TYPE_ID, USER_TYPE_ID)
    assert pairs == [("201066257228", "ADELY1")], pairs
    excluded = exclude_if_related(
        user_graph, MSISDN_TYPE_ID, USER_TYPE_ID, ["201066257228", "201000000000"]
    )
    assert excluded == [("201066257228", ["ADELY1"])], excluded
    keep = exclude_if_related(
        user_graph, MSISDN_TYPE_ID, USER_TYPE_ID, ["201000000000"]
    )
    assert keep == [], keep

    id_graph = _sample_msisdn_id()
    id_pairs = relation_pairs(id_graph, MSISDN_TYPE_ID, ID_TYPE_ID)
    assert id_pairs == [("201066257228", "30008300101556")], id_pairs
    hop = exclude_via_hop(
        id_pairs,
        [("30008300101556", "ADELY1")],
        ["201066257228"],
    )
    assert hop[0][0] == "201066257228"
    hop_none = exclude_via_hop(id_pairs, [], ["201066257228"])
    assert hop_none == []

    profile_graph = {
        "vertices": [],
        "edges": [
            {
                "nodeA": {
                    "nodeName": "201033008757",
                    "nodeTypeId": 1,
                    "nodeType": {"nodeTypeId": 1},
                },
                "nodeB": {
                    "nodeName": "Credit Only Consumer",
                    "nodeTypeId": 1321,
                    "nodeType": {"nodeTypeId": 1321},
                },
            }
        ],
    }
    rows = exclude_if_value(
        profile_graph,
        MSISDN_TYPE_ID,
        WALLET_PROFILE_TYPE_ID,
        ["Credit Only Consumer"],
        ["201033008757"],
    )
    assert rows[0][0] == "201033008757"

    status_graph = {
        "vertices": [],
        "edges": [
            {
                "nodeA": {"nodeName": "201111111111", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Suspended", "nodeTypeId": 1141},
            },
            {
                "nodeA": {"nodeName": "201222222222", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Active", "nodeTypeId": 1141},
            },
        ],
    }
    bad = exclude_if_value(
        status_graph,
        MSISDN_TYPE_ID,
        WALLET_STATUS_TYPE_ID,
        ["Suspended", "Barred"],
        ["201111111111", "201222222222"],
    )
    assert [r[0] for r in bad] == ["201111111111"], bad

    reasons_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "exclude_lists",
        "line_status_reasons.txt",
    )
    reasons = _read_lines(reasons_path)
    assert "Fraud" in reasons
    assert "Fraud Nonpayment" in reasons
    line_graph = {
        "vertices": [],
        "edges": [
            {
                "nodeA": {"nodeName": "201222222222", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Fraud IRSF", "nodeTypeId": 1160},
            },
            {
                "nodeA": {"nodeName": "201000000001", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Fraud", "nodeTypeId": 1160},
            },
            {
                "nodeA": {"nodeName": "201000000002", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Active", "nodeTypeId": 1160},
            },
            {
                "nodeA": {"nodeName": "201000000003", "nodeTypeId": 1},
                "nodeB": {"nodeName": "Suspended", "nodeTypeId": 1160},
            },
        ],
    }
    line_bad = exclude_if_value(
        line_graph,
        MSISDN_TYPE_ID,
        LINE_STATUS_TYPE_ID,
        reasons,
        ["201222222222", "201000000001", "201000000002", "201000000003"],
    )
    assert sorted(r[0] for r in line_bad) == ["201000000001", "201222222222"], line_bad

    isolated = {
        "vertices": [
            {
                "nodeName": "201066257228",
                "nodeTypeId": 1,
                "neighboursCount": 0,
            }
        ],
        "edges": [],
    }
    assert msisdns_with_any_relation(isolated, ["201066257228"]) == []
    assert msisdns_with_any_relation(user_graph, ["201066257228"]) == ["201066257228"]

    template = {
        "graphDepth": 1,
        "dateFrom": "2026/01/01 00:00:00",
        "dateTo": "2026/01/31 23:59:59",
        "linkTypeCat": 13,
        "dispTypes": "1,1001",
        "nodes": [{"id": "1", "nodeType": "1", "nodes": "OLD", "text": "MSISDN"}],
    }
    req = build_request(template, ["A", "B", "C"], "2026/08/01 00:00:00", None)
    assert req["nodes"][0]["nodes"] == "A\nB\nC"
    assert req["dateFrom"] == "2026/08/01 00:00:00"
    assert req["dateTo"] == "2026/01/31 23:59:59"

    print("selftest_ok")


def build_parser():
    parser = argparse.ArgumentParser(description="GLC graph JSON helpers")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("build-request")
    p.add_argument("--template", required=True)
    p.add_argument("--nodes-file", required=True)
    p.add_argument("--out", default="-")
    p.add_argument("--date-from")
    p.add_argument("--date-to")
    p.set_defaults(func=cmd_build_request)

    p = sub.add_parser("summary")
    p.add_argument("--response", required=True)
    p.set_defaults(func=cmd_summary)

    p = sub.add_parser("relations")
    p.add_argument("--response", required=True)
    p.add_argument("--from-type", type=int, required=True)
    p.add_argument("--to-type", type=int, required=True)
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_relations)

    p = sub.add_parser("nodes")
    p.add_argument("--response", required=True)
    p.add_argument("--type-id", type=int, required=True)
    p.add_argument("--out", default="-")
    p.set_defaults(func=cmd_nodes)

    p = sub.add_parser("exclude-if-related")
    p.add_argument("--response", required=True)
    p.add_argument("--from-type", type=int, required=True)
    p.add_argument("--to-type", type=int, required=True)
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_exclude_if_related)

    p = sub.add_parser("exclude-if-value")
    p.add_argument("--response", required=True)
    p.add_argument("--from-type", type=int, required=True)
    p.add_argument("--to-type", type=int, required=True)
    p.add_argument("--match-values", default="")
    p.add_argument("--match-values-file")
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_exclude_if_value)

    p = sub.add_parser("related-dump")
    p.add_argument("--response", required=True)
    p.add_argument("--from-type", type=int, required=True)
    p.add_argument("--to-type", type=int, required=True)
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_related_dump)

    p = sub.add_parser("has-relation")
    p.add_argument("--response", required=True)
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_has_relation)

    p = sub.add_parser("exclude-via-hop")
    p.add_argument("--first-map", required=True)
    p.add_argument("--second-map", required=True)
    p.add_argument("--candidates")
    p.set_defaults(func=cmd_exclude_via_hop)

    p = sub.add_parser("unique")
    p.add_argument("--nodes-file", required=True)
    p.add_argument("--out", default="-")
    p.set_defaults(func=cmd_unique)

    p = sub.add_parser("selftest")
    p.set_defaults(func=cmd_selftest)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.error("command required")
    args.func(args)


if __name__ == "__main__":
    main()
