#!/bin/bash
# Mock replacement for glc_auto.sh used by local tests.
# Reads a GLC request JSON and prints a synthetic graph response.
set -euo pipefail
python3 - "$1" <<'PY'
import json
import sys

TYPE_NAMES = {
    1: "MSISDN",
    1000: "Device",
    1001: "User",
    1003: "ID",
    1141: "Wallet Status",
    1160: "Line Status",
    1321: "Wallet Profile",
}

USERS = {"201066257228": ["ADELY1"]}
WALLET_PROFILES = {"201033008757": ["Credit Only Consumer"]}
WALLET_STATUSES = {"201111111111": ["Suspended"], "201999000003": ["Barred"]}
LINE_STATUSES = {"201222222222": ["Fraud IRSF"]}
MSISDN_DEVICES = {
    "201333333333": ["DEV1"],
    "201777777777": ["DEV2"],
}
DEVICE_MSISDNS = {
    "DEV1": ["201333333333", "201444444444"],
    "DEV2": ["201777777777"],
}
MSISDN_IDS = {
    "201333333333": ["ID333"],
    "201444444444": ["ID444"],
    "201555555555": ["ID555"],
    "201666666666": ["ID666"],
    "201777777777": ["ID777"],
}
ID_USERS = {"ID444": ["USERX"]}
SUB_RELATIONS = {"201555555555": ["201000000001"]}


def node_values(req):
    nodes = (req.get("nodes") or [{}])[0]
    raw = nodes.get("nodes") or ""
    values = []
    for item in str(raw).replace("\r", "\n").split("\n"):
        item = item.strip()
        if item:
            values.append(item)
    node_type = str(nodes.get("nodeType") or nodes.get("id") or "")
    return node_type, values


def vertex(name, type_id, neighbours=0, root=False):
    node_id = "%s_%s" % (type_id, name)
    return {
        "label": name,
        "nodeName": name,
        "nodeId": node_id,
        "id": node_id,
        "nodeTypeId": type_id,
        "neighboursCount": neighbours,
        "root": root,
        "highlight": root,
        "nodeType": {
            "nodeTypeId": type_id,
            "nodeTypeName": TYPE_NAMES.get(type_id, str(type_id)),
            "id": type_id,
        },
    }


def edge(a, b, link_id):
    return {
        "direction": 1,
        "linkID": "%s_%s_%s" % (link_id, a["nodeId"], b["nodeId"]),
        "linkTypeID": link_id,
        "nodeA_ID": a["nodeId"],
        "nodeB_ID": b["nodeId"],
        "nodeA": a,
        "nodeB": b,
        "id": "%s_%s_%s" % (link_id, a["nodeId"], b["nodeId"]),
        "linkKey": "%s::%s::%s" % (link_id, a["nodeId"], b["nodeId"]),
    }


def build_pairs(inputs, mapping, default_map=None):
    pairs = []
    for src in inputs:
        values = list(mapping.get(src) or [])
        if not values and default_map is not None:
            values = list(default_map.get(src) or [])
        for dst in values:
            pairs.append((src, dst))
    return pairs


def graph(inputs, pairs, from_type, to_type, link_id, input_are_from=True):
    vertices = {}
    edges = []
    roots = []
    neighbour_count = {}

    def add_vertex(name, type_id, root=False):
        key = (type_id, name)
        if key not in vertices:
            vertices[key] = vertex(name, type_id, 0, root)
        elif root:
            vertices[key]["root"] = True
            vertices[key]["highlight"] = True
        return vertices[key]

    for name in inputs:
        type_id = from_type if input_are_from else from_type
        v = add_vertex(name, type_id, root=True)
        roots.append(v)

    for src, dst in pairs:
        a = add_vertex(src, from_type, root=(from_type == (from_type if input_are_from else to_type) and src in inputs))
        b = add_vertex(dst, to_type)
        neighbour_count[(from_type, src)] = neighbour_count.get((from_type, src), 0) + 1
        neighbour_count[(to_type, dst)] = neighbour_count.get((to_type, dst), 0) + 1
        edges.append(edge(a, b, link_id))

    for key, count in neighbour_count.items():
        if key in vertices:
            vertices[key]["neighboursCount"] = count

    return {
        "maxDuration": 0,
        "maxCharge": 0,
        "maxCount": len(edges) or 0,
        "minDuration": 0,
        "minCount": 1 if edges else 0,
        "minCharge": 0,
        "vertices": list(vertices.values()),
        "edges": edges,
        "locations": [],
        "nodeTypes": [],
        "msgs": None,
        "paths": [],
        "warningMsg": None,
        "responseCode": 0,
        "rootNodes": roots,
        "nodesStr": [v["nodeId"] for v in vertices.values()],
    }


req = json.load(open(sys.argv[1]))
link = int(req.get("linkTypeCat"))
disp = str(req.get("dispTypes") or "")
node_type, values = node_values(req)

if link == 13:
    out = graph(values, build_pairs(values, USERS), 1, 1001, 13)
elif link == 535:
    default_profiles = {m: ["Consumer"] for m in values if m not in WALLET_PROFILES}
    out = graph(values, build_pairs(values, WALLET_PROFILES, default_profiles), 1, 1321, 535)
elif link == 352:
    default_status = {m: ["Active"] for m in values if m not in WALLET_STATUSES}
    out = graph(values, build_pairs(values, WALLET_STATUSES, default_status), 1, 1141, 352)
elif link == 371:
    default_status = {m: ["Active"] for m in values if m not in LINE_STATUSES}
    out = graph(values, build_pairs(values, LINE_STATUSES, default_status), 1, 1160, 371)
elif link == 23 and node_type == "1000":
    out = graph(values, build_pairs(values, DEVICE_MSISDNS), 1000, 1, 23)
elif link == 23:
    out = graph(values, build_pairs(values, MSISDN_DEVICES), 1, 1000, 23)
elif link == 11:
    out = graph(values, build_pairs(values, MSISDN_IDS), 1, 1003, 11)
elif link == 555:
    out = graph(values, build_pairs(values, ID_USERS), 1003, 1001, 555)
elif link == 82:
    pairs = build_pairs(values, SUB_RELATIONS)
    if "1001" in disp.split(","):
        user_pairs = [(src, "SUBUSER") for src, _dst in pairs]
        out = graph(values, user_pairs, 1, 1001, 82)
    else:
        out = graph(values, pairs, 1, 1, 82)
else:
    out = graph(values, [], 1, 1, link)

json.dump(out, sys.stdout)
sys.stdout.write("\n")
PY
