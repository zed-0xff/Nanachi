#!/usr/bin/env python3
"""Page -> widget map for the Sovol/Makerbase screen client.

Joins the screen layout decoded from the .tft (via TFTTool) with the host handlers in ui.h / ui.cpp:
  * which components of each page report to the host (the 0x65 <page> <widget> <press/release> frame),
  * where they are on screen (x, y, w, h),
  * which host constant / handler case receives them and what it does.
Mismatches (host cases without a screen component and the other way around) are listed per page.

usage: widget_map.py --tft FILE.tft --src zhongchuang [--tfttool PATH] [-o widget_map.md]
"""
import argparse
import json
import re
import sys
from pathlib import Path


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def parse_enums(text):
    """Returns (constants name -> value, list of TJC_PAGE_* names in order)."""
    text = strip_comments(text)
    consts = {}
    pages = []
    for m in re.finditer(r"enum\s*\w*\s*\{(.*?)\}", text, flags=re.S):
        cur = 0
        for item in m.group(1).split(","):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                name, expr = [x.strip() for x in item.split("=", 1)]
                try:
                    cur = int(expr, 0)
                except ValueError:
                    cur = consts.get(expr, cur)
            else:
                name = item
            consts[name] = cur
            if name.startswith("TJC_PAGE_"):
                pages.append(name)
            cur += 1
    return consts, pages


def read_sources(src):
    files = sorted(Path(src).glob("src/*.cpp")) + sorted(Path(src).glob("*.cpp"))
    return {f: f.read_text(errors="replace") for f in files}


def function_body(text, name):
    m = re.search(r"^\s*(?:static\s+)?(?:void|int|bool)\s+" + re.escape(name) + r"\s*\([^)]*\)\s*\{", text, flags=re.M)
    if not m:
        return None
    i = m.end()
    depth = 1
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return text[m.end():i - 1]


def dispatch_table(sources):
    """page constant -> handler function name, from the switch(page_id) in tjc_event_clicked_handler."""
    for text in sources.values():
        body = function_body(text, "tjc_event_clicked_handler")
        if body:
            break
    else:
        return {}
    body = strip_comments(body)
    table, pending = {}, []
    for line in body.splitlines():
        m = re.match(r"\s*case\s+(TJC_PAGE_\w+)\s*:", line)
        if m:
            pending.append(m.group(1))
            continue
        m = re.match(r"\s*(\w+)\s*\(([^;]*)\)\s*;", line)
        if m and pending and m.group(1) not in ("page_to", "MKSLOG_GREEN"):
            for p in pending:
                table[p] = m.group(1)
            pending = []
        if re.match(r"\s*break\s*;", line):
            pending = []
    return table


def handler_cases(sources, name):
    """case label -> short summary of what the host does."""
    for text in sources.values():
        body = function_body(text, name)
        if body is not None:
            break
    else:
        return None
    body = strip_comments(body)
    m = re.search(r"switch\s*\(\s*widget_id\s*\)\s*\{", body)
    if not m:
        return {}
    i = m.end()
    depth = 1
    j = i
    while j < len(body) and depth:
        depth += {"{": 1, "}": -1}.get(body[j], 0)
        j += 1
    sw = body[i:j - 1]
    cases, labels, stmts = {}, [], []

    def flush():
        if labels:
            summary = [s for s in stmts if s and not s.startswith(("MKSLOG", "std::cout", "break", "{", "}", "else", "return"))]
            text = "; ".join(summary[:3])
            for l in labels:
                cases[l] = (text[:140] + "…") if len(text) > 140 else text

    for line in sw.splitlines():
        line = line.strip()
        m = re.match(r"case\s+(\w+)\s*:(.*)", line)
        if m and m.group(1).startswith("TJC_PAGE_"):
            continue    # switch on a page id (e.g. previous_page_id), not on a widget id
        if m:
            if stmts:
                flush()
                labels, stmts = [], []
            labels.append(m.group(1))
            if m.group(2).strip():
                stmts.append(m.group(2).strip())
            continue
        if line.startswith("default:"):
            flush()
            labels, stmts = [], []
            continue
        if labels:
            stmts.append(line)
    flush()
    return cases


def screen_pages(tft, tfttool):
    sys.path.insert(0, str(tfttool))
    import TFTTool as T
    t = T.TFTFile(Path(tft).read_bytes(), decode_usercode=True)
    return json.loads(t.getReadable(includeUnknowns=False))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tft", required=True)
    ap.add_argument("--src", required=True, help="host source tree (contains include/ui.h and src/*.cpp)")
    ap.add_argument("--tfttool", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("-o", "--output", default="widget_map.md")
    args = ap.parse_args()

    src = Path(args.src)
    consts, page_names = parse_enums((src / "include" / "ui.h").read_text(errors="replace"))
    sources = read_sources(src)
    dispatch = dispatch_table(sources)
    data = screen_pages(args.tft, args.tfttool)
    pages = data["pages"]
    menu = handler_cases(sources, "tjc_menu_handler") or {}

    out = ["# Page → widget map", "",
           f"Screen file: `{Path(args.tft).name}` ({data['info']['pages_count']} pages, "
           f"{data['info']['objects_count']} components, editor {data['info']['editor']}).",
           "Host source: `ui.h` / `ui.cpp`. Generated by `sovol/widget_map.py`; do not edit by hand.", "",
           "A touch reports `65 <page> <widget> <01 press | 00 release> FF FF FF` only for components with "
           "\"send key code\" enabled. The *widget* column below is that number. Host values `>= 100` are the global "
           "navigation ids handled by `tjc_menu_handler` on every page.", ""]
    if menu:
        out += ["## Global navigation (`tjc_menu_handler`)", "", "| widget | constant | host action |", "|---|---|---|"]
        for label, summary in menu.items():
            out.append(f"| {consts.get(label, '?')} | `{label}` | {summary} |")
        out.append("")

    unmatched_total = no_case_total = 0
    for idx, pg in enumerate(pages):
        pname = page_names[idx] if idx < len(page_names) else f"(page {idx})"
        handler = dispatch.get(pname)
        cases = handler_cases(sources, handler) if handler else None
        objs = pg.get("objects", [])
        reporting = {}
        for o in objs:
            for ename, he in o.get("host_events", {}).items():
                w = he["widget"]
                if isinstance(w, int):
                    reporting.setdefault(w, []).append((o, ename))
        if not reporting and not cases:
            continue
        out.append(f"## {idx}: `{pname}`")
        out.append("")
        out.append(f"Handler: `{handler}`" if handler else "Handler: none in `tjc_event_clicked_handler`")
        out.append(f"Components: {len(objs)}, reporting to the host: {len(reporting)}")
        out.append("")
        case_by_value = {}
        for label, summary in (cases or {}).items():
            if label in consts:
                case_by_value.setdefault(consts[label], []).append((label, summary))
        for label, summary in menu.items():
            v = consts.get(label)
            if v in reporting and v not in case_by_value:
                case_by_value[v] = [(label + " (menu)", summary)]
        values = sorted(set(reporting) | set(case_by_value))
        out += ["| widget | constant | component (label, English) | position (x,y,w,h) | event | host action |",
                "|---|---|---|---|---|---|"]
        for v in values:
            cs = case_by_value.get(v, [])
            const = ", ".join(f"`{l}`" for l, _ in cs) or "–"
            action = " / ".join(s for _, s in cs if s) or ("*(no case)*" if not cs else "")
            if v in reporting:
                for o, ename in reporting[v]:
                    pos = f"{o['x']},{o['y']},{o['w']},{o['h']}"
                    tx = o.get("text", {})
                    label = tx.get("1") or tx.get("0") or ""
                    label = f' "{label}"' if label else ""
                    out.append(f"| {v} | {const} | #{o['id']} {o['type']}{label} | {pos} | {ename} | {action} |")
            else:
                out.append(f"| {v} | {const} | **none on screen** | | | {action} |")
                unmatched_total += 1
            if v in reporting and not cs:
                no_case_total += 1
        out.append("")
    out.append(f"*Host cases without a screen component: {unmatched_total}. "
               f"Screen components reporting to the host without a host case: {no_case_total}.*")
    Path(args.output).write_text("\n".join(out) + "\n")
    print(f"written {args.output}: {len(pages)} pages, {unmatched_total} host cases without a screen component, "
          f"{no_case_total} screen widgets without a host case")


if __name__ == "__main__":
    main()
