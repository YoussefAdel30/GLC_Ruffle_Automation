#!/usr/bin/env python3
"""Helpers for the ruffle cron wrapper: parse drop CSVs, map users, build mail CSV."""

from __future__ import print_function

import argparse
import csv
import os
import re
import sys


def _read_text_rows(path):
    with open(path, "r") as fh:
        raw = fh.read()
    if raw.startswith("\ufeff"):
        raw = raw[1:]
    return list(csv.reader(raw.splitlines()))


def parse_ruffle_csv(path):
    """Return unique MSISDNs (col 1), unique user ids (col 2), and raffle_name (col 3 first cell)."""
    msisdns = []
    seen_m = set()
    userids = []
    seen_u = set()
    raffle_name = ""
    rows = _read_text_rows(path)
    if not rows:
        return msisdns, userids, raffle_name
    start = 0
    first = rows[0]
    col0 = str(first[0]).strip().lower() if first else ""
    col2 = str(first[2]).strip().lower() if first and len(first) > 2 else ""
    if col0 in ("msisdn", "input msisdn", "input msisdns") or col2 == "raffle_name":
        start = 1
    for row in rows[start:]:
        if not row:
            continue
        msisdn = str(row[0]).strip() if len(row) > 0 else ""
        userid = str(row[1]).strip() if len(row) > 1 else ""
        name = str(row[2]).strip() if len(row) > 2 else ""
        if msisdn and msisdn not in seen_m:
            seen_m.add(msisdn)
            msisdns.append(msisdn)
        if userid and userid not in seen_u:
            seen_u.add(userid)
            userids.append(userid)
        if name and not raffle_name:
            raffle_name = name
    return msisdns, userids, raffle_name


def load_mapper(path):
    mapping = {}
    if not path or not os.path.exists(path):
        return mapping
    rows = _read_text_rows(path)
    start = 0
    if rows and rows[0] and str(rows[0][0]).strip().lower() in ("userid", "user id", "user"):
        start = 1
    for row in rows[start:]:
        if not row or len(row) < 2:
            continue
        userid = str(row[0]).strip()
        email = str(row[1]).strip()
        if userid and email:
            mapping[userid] = email
            mapping[userid.lower()] = email
    return mapping


def map_user_emails(userids, mapper):
    emails = []
    missing = []
    seen = set()
    for userid in userids:
        email = mapper.get(userid) or mapper.get(userid.lower())
        if not email:
            missing.append(userid)
            continue
        if email not in seen:
            seen.add(email)
            emails.append(email)
    return emails, missing


def safe_userid_label(userids):
    if not userids:
        return "unknown"
    parts = []
    for userid in userids:
        cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", str(userid)).strip("_")
        if cleaned:
            parts.append(cleaned)
    return "_".join(parts) if parts else "unknown"


def format_reason(row):
    step = (row.get("step") or "").strip()
    reason = (row.get("reason") or "").strip()
    detail = (row.get("detail") or "").strip()
    bits = [b for b in (step, reason, detail) if b]
    return " / ".join(bits)


def load_exclusions(path):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("msisdn|"):
                continue
            parts = line.split("|", 3)
            while len(parts) < 4:
                parts.append("")
            rows.append(
                {
                    "msisdn": parts[0],
                    "step": parts[1],
                    "reason": parts[2],
                    "detail": parts[3],
                }
            )
    return rows


def _read_lines(path):
    if not path or not os.path.exists(path):
        return []
    out = []
    seen = set()
    with open(path) as fh:
        for line in fh:
            item = line.strip().replace("\r", "")
            if not item or item.startswith("#"):
                continue
            if item not in seen:
                seen.add(item)
                out.append(item)
    return out


def parse_filter_report(text):
    """Pull remaining numbers and exclusions out of the text filter report."""
    remaining = []
    exclusions = []
    section = None
    current = None
    for raw in str(text or "").splitlines():
        line = raw.rstrip("\n")
        if line.startswith("----- REMAINING"):
            section = "remaining"
            current = None
            continue
        if line.startswith("----- EXCLUDED INPUT"):
            section = "excluded"
            current = None
            continue
        if line.startswith("-----"):
            section = None
            current = None
            continue
        if not section:
            continue
        stripped = line.strip()
        if section == "remaining":
            if stripped and stripped != "(none)":
                remaining.append(stripped)
            continue
        if section == "excluded":
            if line.startswith("  step:"):
                if current is not None:
                    current["step"] = line.split(":", 1)[1].strip()
            elif line.startswith("  reason:"):
                if current is not None:
                    current["reason"] = line.split(":", 1)[1].strip()
            elif line.startswith("  detail:"):
                if current is not None:
                    current["detail"] = line.split(":", 1)[1].strip()
            elif stripped and stripped != "(none)":
                current = {
                    "msisdn": stripped,
                    "step": "",
                    "reason": "",
                    "detail": "",
                }
                exclusions.append(current)
    return remaining, exclusions


def parse_filter_report_file(path):
    if not path or not os.path.exists(path):
        return [], []
    with open(path) as fh:
        return parse_filter_report(fh.read())


def write_attachment(input_msisdns, remaining, exclusions, out_path):
    remaining_set = set(remaining)
    excl_by = {}
    for row in exclusions:
        msisdn = row.get("msisdn")
        if msisdn and msisdn not in excl_by:
            excl_by[msisdn] = row
    ordered = list(input_msisdns)
    seen = set(ordered)
    for msisdn in remaining:
        if msisdn not in seen:
            ordered.append(msisdn)
            seen.add(msisdn)
    for msisdn in excl_by:
        if msisdn not in seen:
            ordered.append(msisdn)
            seen.add(msisdn)
    with open(out_path, "w") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(
            ["Input MSISDNs", "Filtered Msisdns", "Excluded Msisdns", "Reason of exclusion"]
        )
        for msisdn in ordered:
            if msisdn in remaining_set:
                writer.writerow([msisdn, msisdn, "", ""])
            elif msisdn in excl_by:
                writer.writerow([msisdn, "", msisdn, format_reason(excl_by[msisdn])])
            else:
                writer.writerow([msisdn, "", msisdn, "not processed"])
    return len(ordered)


def cmd_parse(args):
    msisdns, userids, raffle_name = parse_ruffle_csv(args.csv)
    if args.msisdns_out:
        with open(args.msisdns_out, "w") as fh:
            if msisdns:
                fh.write("\n".join(msisdns) + "\n")
    if args.userids_out:
        with open(args.userids_out, "w") as fh:
            if userids:
                fh.write("\n".join(userids) + "\n")
    if getattr(args, "raffle_name_out", None):
        with open(args.raffle_name_out, "w") as fh:
            fh.write((raffle_name + "\n") if raffle_name else "")
    print(
        "msisdns=%s userids=%s raffle_name=%s"
        % (len(msisdns), ",".join(userids) if userids else "", raffle_name)
    )


def cmd_map(args):
    userids = _read_lines(args.userids)
    emails, missing = map_user_emails(userids, load_mapper(args.mapper))
    if args.emails_out:
        with open(args.emails_out, "w") as fh:
            if emails:
                fh.write("\n".join(emails) + "\n")
    if args.missing_out:
        with open(args.missing_out, "w") as fh:
            if missing:
                fh.write("\n".join(missing) + "\n")
    print("emails=%s missing=%s" % (",".join(emails), ",".join(missing)))


def cmd_attachment(args):
    inputs = _read_lines(args.input_file)
    remaining = _read_lines(getattr(args, "remaining_file", None))
    exclusions = load_exclusions(getattr(args, "excluded_file", None))
    report_remaining, report_exclusions = parse_filter_report_file(
        getattr(args, "report_file", None)
    )
    if not remaining:
        remaining = report_remaining
    if not exclusions:
        exclusions = report_exclusions
    if not inputs:
        inputs = []
        for msisdn in remaining:
            if msisdn not in inputs:
                inputs.append(msisdn)
        for row in exclusions:
            msisdn = row.get("msisdn")
            if msisdn and msisdn not in inputs:
                inputs.append(msisdn)
    rows = write_attachment(inputs, remaining, exclusions, args.out)
    print("attachment_rows=%s remaining=%s excluded=%s" % (rows, len(remaining), len(exclusions)))


def cmd_label(args):
    userids = _read_lines(args.userids) if args.userids else []
    sys.stdout.write(safe_userid_label(userids) + "\n")


def cmd_selftest(args):
    import tempfile

    tmp = tempfile.mkdtemp()
    csv_path = os.path.join(tmp, "ruffle.csv")
    with open(csv_path, "w") as fh:
        fh.write("201111111111,AmrY1,Ramadan2026\n")
        fh.write("201222222222,IBRAHIMA67,IgnoredOtherName\n")
        fh.write(",\n")
        fh.write("201111111111,AmrY1\n")
        fh.write(",Mahmoudb4\n")
    msisdns, userids, raffle_name = parse_ruffle_csv(csv_path)
    assert msisdns == ["201111111111", "201222222222"], msisdns
    assert userids == ["AmrY1", "IBRAHIMA67", "Mahmoudb4"], userids
    assert raffle_name == "Ramadan2026", raffle_name
    header_csv = os.path.join(tmp, "header.csv")
    with open(header_csv, "w") as fh:
        fh.write("msisdn,userid,raffle_name\n")
        fh.write("201111111111,AmrY1,Eid2026\n")
    _m, _u, header_name = parse_ruffle_csv(header_csv)
    assert header_name == "Eid2026", header_name

    mapper_path = os.path.join(tmp, "mapper.csv")
    with open(mapper_path, "w") as fh:
        fh.write("userid,email\n")
        fh.write("AmrY1,one@vodafone.com.eg\n")
        fh.write("IBRAHIMA67,two@vodafone.com.eg\n")
    emails, missing = map_user_emails(userids, load_mapper(mapper_path))
    assert emails == ["one@vodafone.com.eg", "two@vodafone.com.eg"], emails
    assert missing == ["Mahmoudb4"], missing
    assert safe_userid_label(userids) == "AmrY1_IBRAHIMA67_Mahmoudb4"

    att = os.path.join(tmp, "out.csv")
    write_attachment(
        ["201111111111", "201222222222"],
        ["201222222222"],
        [
            {
                "msisdn": "201111111111",
                "step": "1-msisdn_user",
                "reason": "has_user",
                "detail": "ADELY1",
            }
        ],
        att,
    )
    text = open(att).read()
    assert "Input MSISDNs,Filtered Msisdns,Excluded Msisdns,Reason of exclusion" in text
    assert "201111111111,,201111111111,1-msisdn_user / has_user / ADELY1" in text
    assert "201222222222,201222222222,," in text

    empty_in = os.path.join(tmp, "empty_in.txt")
    open(empty_in, "w").close()
    report_path = os.path.join(tmp, "report.txt")
    with open(report_path, "w") as fh:
        fh.write(
            "\n".join(
                [
                    "input_msisdns=1",
                    "remaining=0",
                    "excluded_from_input=1",
                    "",
                    "----- REMAINING MSISDNs (0) -----",
                    "(none)",
                    "",
                    "----- EXCLUDED INPUT MSISDNs (1) -----",
                    "201066257228",
                    "  step:   1-msisdn_user",
                    "  reason: has_user",
                    "  detail: ADELY1",
                    "",
                ]
            )
            + "\n"
        )
    remaining, exclusions = parse_filter_report(open(report_path).read())
    assert remaining == []
    assert exclusions[0]["msisdn"] == "201066257228"
    assert exclusions[0]["reason"] == "has_user"
    all_excl = os.path.join(tmp, "all_excl.csv")
    write_attachment(
        ["201066257228"],
        [],
        exclusions,
        all_excl,
    )
    all_text = open(all_excl).read()
    assert "201066257228,,201066257228,1-msisdn_user / has_user / ADELY1" in all_text
    fallback = os.path.join(tmp, "fallback.csv")
    cmd_attachment(
        argparse.Namespace(
            input_file=empty_in,
            remaining_file=os.path.join(tmp, "missing_remaining.txt"),
            excluded_file=os.path.join(tmp, "missing_excluded.txt"),
            report_file=report_path,
            out=fallback,
        )
    )
    fb = open(fallback).read()
    assert "201066257228,,201066257228,1-msisdn_user / has_user / ADELY1" in fb
    print("selftest_ok")


def build_parser():
    parser = argparse.ArgumentParser(description="Ruffle cron job helpers")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("parse")
    p.add_argument("--csv", required=True)
    p.add_argument("--msisdns-out")
    p.add_argument("--userids-out")
    p.add_argument("--raffle-name-out")
    p.set_defaults(func=cmd_parse)

    p = sub.add_parser("map")
    p.add_argument("--mapper", required=True)
    p.add_argument("--userids", required=True)
    p.add_argument("--emails-out")
    p.add_argument("--missing-out")
    p.set_defaults(func=cmd_map)

    p = sub.add_parser("attachment")
    p.add_argument("--input-file", required=True)
    p.add_argument("--remaining-file")
    p.add_argument("--excluded-file")
    p.add_argument("--report-file")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_attachment)

    p = sub.add_parser("label")
    p.add_argument("--userids", required=True)
    p.set_defaults(func=cmd_label)

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
