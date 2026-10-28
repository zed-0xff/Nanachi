#!/usr/bin/env python3
"""Extracts the instruction tables of a TJC / Nextion firmware image (the plain, already unscrambled image, see
tools/fw_unscramble.py) and prints them as JSON or text.

The runtime has two tables the command parser walks (found in the AiHmiT7 firmware 159, `sub_1D88x` area of the Hex-Rays dump):

  long   12 byte records `name[8] f0 f1 f2 f3`, starts with `click`, ends with `setbaudz`: the commands with a string
         argument (`print`, `twfile`, `rdfile`, `doevents`, ...)
  short  8 byte records `name[4] f0 f1 f2 f3`, starts with `i`, ends with `play`: the fixed size commands (`pic`, `cir`, `fill`,
         `page`, ...); the position in this table is the number the parser uses for the command

The four bytes are, in the names of the editor's own source (`HMI/hmitype/CodeRun.cs`, `comtype_64` / `comtype_32`, an
older build with 32 / 31 of these records; 28 of 30 and 28 of 29 common records are byte-identical, the others only differ in the
number of operands, e.g. `timerset` 3 -> 4, `nstr` 2 -> 3, `draw_h` 6 -> 13):
  comindex  the command class index (0..7)
  canqyt    the number of operands (0xFE = variable, 0xFF = see the parser)
  canlei    the operand kind, an ASCII letter: `e` expression, `f`, `g`, `o` object, `p`, `y` (255 = none / special)
  res       the code number of the command inside its class The positions of the long table match the numbers of the operator class 8 of TFTTool
(`doevents` is 48 in both); the positions of the short table do NOT equal the editor's numbers of class 4 (firmware 159 knows
`uprd`, `move`, `xnum`, `beep`, `meup`, `gets`, `sets`, `cuts`, `rept`, `wept`, `play` that the 1.65.5 / 1.67.4 lists lack), so
the tables of this firmware can only be used to check the names and the order, not to name compiled operators.

The third list, `hidden`, are the names the interpreter compares with strings in its operators 47 (read) and 48 (write):
nothing in the documentation of the editor, found by scanning the literal pools, so the list is heuristic.
"""
import argparse
import json
import re
import sys

_NAME = re.compile(rb"^[a-z_][a-z0-9_]*$")


def _record(index, text, rest):
    comindex, canqyt, canlei, res = rest
    return {"index": index, "name": text.decode(), "comindex": comindex, "canqyt": canqyt, "canlei": canlei, "res": res,
            "f": list(rest)}


def _long_table(data):
    start = data.find(b"click\x00\x00\x00")
    if start < 0:
        return 0, []
    out = []
    pos = start
    while pos + 12 <= len(data):
        name, rest = data[pos:pos + 8], data[pos + 8:pos + 12]
        end = name.find(b"\x00")
        text = name if end < 0 else name[:end]
        if len(text) < 3 or not _NAME.match(text) or (end >= 0 and name[end:].strip(b"\x00")):
            break
        out.append(_record(len(out), text, rest))
        pos += 12
    return pos, out


def _short_table(data, pos):
    out = []
    while pos + 8 <= len(data):
        name, rest = data[pos:pos + 4], data[pos + 4:pos + 8]
        end = name.find(b"\x00")
        text = name if end < 0 else name[:end]
        if not text or not _NAME.match(text) or (end >= 0 and name[end:].strip(b"\x00")):
            break
        out.append(_record(len(out), text, rest))
        pos += 8
    return out


def _hidden(data, known):
    anchor = data.find(b"\x00hexcrc\x00")
    end = data.find(b"\x00mlen\x00", anchor)
    if anchor < 0 or end < 0:
        return []
    names = []
    for m in re.finditer(rb"(?<=\x00)[a-z][a-z0-9_]{3,}(?=\x00)", data[anchor:end + 6]):
        name = m.group().decode()
        if name not in known and name not in names:
            names.append(name)
    return names


def extract(data):
    pos, long_t = _long_table(data)
    short_t = _short_table(data, pos)
    known = {e["name"] for e in long_t} | {e["name"] for e in short_t}
    return {"long": long_t, "short": short_t, "hidden": _hidden(data, known)}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image", help="plain firmware image")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    tables = extract(open(a.image, "rb").read())
    if a.json:
        json.dump(tables, sys.stdout, indent=1)
        print()
        return 0
    for key in ("long", "short"):
        print(f"{key} table, {len(tables[key])} records")
        for e in tables[key]:
            print(f"  {e['index']:3} {e['name']:<10} class {e['comindex']} operands {e['canqyt']:3} kind {e['canlei']:3}"
                  f" code {e['res']:3}")
    print(f"hidden names ({len(tables['hidden'])}): " + " ".join(tables["hidden"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
