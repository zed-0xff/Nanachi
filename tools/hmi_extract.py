#!/usr/bin/env python3
"""Extracts the embedded resources of a TJC/Nextion editor `.HMI` project file (the uncompiled project source, as
opposed to a compiled `.tft`).

  hmi_extract.py project.HMI out_dir/

Format corrected against the independent, round-trip-verified reverse engineering in
`ext/nextion-hmi-format` (see docs/page-block.md, lib/container.js, lib/page.js) - our own from-scratch pass had the
directory's "unknown leading 4 bytes" and the `.pa` object layout slightly wrong; this version follows the verified
model.

## Directory

  +0   u32   number of entries
  +4   entries, 28 bytes each:
         +0   char[16]  name (`main.HMI`, `0.i`, `0.is`, `0.zi`, `0.pa`), NUL padded, can be empty
         +16  u32       absolute offset of the block
         +20  u32       size of the block
         +24  u32       flags; bit 0 = stale copy left over from an earlier save (the Editor ignores these; so does
                        this tool by default - pass --include-stale to extract them too)

## Images: `.is`/`.ib` (PNG/JPEG source) and `.i` (raw RGB565)

An image is commonly stored twice: a `.is`/`.ib` PNG/JPEG record (what the Editor shows) and a `.i` raw-RGB565
record (what the panel actually gets). Both share the same small header, disambiguated by the 4th byte:

  +0   u8    editor version tag, 0x0a or 0x0b (can differ between the two records of the same picture)
  +1   u8    0x64
  +2   u8    0x01
  +3   u8    1 = PNG/JPEG record, 0 = raw RGB565 record
  +8   u32   header size: 27 for PNG/JPEG, 24 for raw RGB565
  +12  u16   width
  +14  u16   height
  +16  u32   payload length
  +20  u32   0
  +24  3     "png" or "jpg"   (PNG/JPEG record only)
  +27/+24    payload

PNG/JPEG payload is a plain file, `payload_length == record size - 27`. The raw RGB565 payload is `width * height *
2` bytes, little-endian; on landscape (90-degree rotated) projects the pixels are stored rotated clockwise -
`index = x * height + (height - 1 - y)` instead of the straight `index = y * width + x` - verified against a real
sample (`powadcr_iface`, a cassette-deck icon that is unrecognisable without the rotation and a clean image with
it). By default `.is`/`.ib` are unpacked to their real PNG/JPEG file and `.i` is converted to a PNG using the
project's own orientation (read from a live `main.HMI` manifest when present, straight otherwise); pass
--no-unpack-images / --no-convert-i to keep the raw containers instead.

Only a small minority of `.i` records in the wild match this layout (4th byte 0, confirmed by payload length); most
have a different, still-undeciphered 4th byte (3 or 4) and are left untouched regardless of --no-convert-i.

## Page block `N.pa` - text dump

A `.pa` holds one project page and every component on it:

  +0   u32   content stamp (not reproduced here, this tool only reads)
  +4   u32   total block size
  +8   u32   header size = 56
  +12  u32   object count (the page itself plus its components)
  +20  u32   0x00214F00
  +24  char[16] page name
  +40  u32   not a constant, varies per page - a header sample field, irrelevant for reading
  +56  object table, 12 bytes per object: offset (from +56), length, 0
       followed by the object bodies

Each object is a flat chain of `u32 length + body` records ending with a zero-length record:
length >= 16 is an attribute (16-byte name, then the value, 1/2/4 bytes little-endian or a string for a fixed set of
always-string attributes); length < 16 is a marker - either the object's own type marker (`att-NN`) or an
event-handler section header (`codesload-N`, `codesdown-N`, ...) followed directly by N more short records, which
are its source lines (blank lines are stored as the literal text "//"). By default `.pa` is unpacked to a readable
`.cs` text file (the extension is picked only so editors syntax-highlight it out of the box - the content is not
C#) listing every attribute (as a compact table in a comment) and the full source of every event handler; pass
--no-unpack-pa to keep the raw container instead.

## Naming

Resources are written under their own name from the directory (not an index-prefixed name - every record type
carries its real name). If that name is already used in the output directory, a numeric suffix is added before the
extension (`name_1.ext`, `name_2.ext`, ...).

## Legacy format (older, non-TJC Nextion Editor)

A small minority of `.HMI` files (seen in `ESP-HVAC/Thermostat.HMI` and `nextion-font-editor/NextionHMITest.HMI`,
confirmed by an identical 12-byte signature at offset 0 and otherwise byte-identical boilerplate between the two,
unrelated projects) do not have the directory above at all - `read_directory()` raises instead of returning entries.
This is a different, much older Nextion Editor serialization (header bytes 0-19 match TFTTool.py's own compiled-TFT
`header1` layout almost exactly: resolution, orientation and - tellingly - the exact file size, all check out) that
stores each component as a flat run of self-describing attribute records instead of compact name+value pairs:

  +0   char[8]   attribute name, NUL padded
  +8   u16       value width in bytes (1/2/4), repeated once more (purpose of the second copy not determined)
  +12  u8        a per-attribute field/sort code, differs per name but is constant across projects
  +13  u8        0xff
  +14..27        14 bytes not decoded (the real/placeholder value round-trip within here isn't understood,
                 only that the real, current value always ends up in the next field)
  +28            value, `width` bytes
  +28+width      a trailing label/help-text string, running up to the next record

Found and decoded with a content-agnostic scanner (`_looks_like_legacy_record`/`decode_legacy_attributes`) that
doesn't need a known attribute name list: records are recognized purely by this shape, which is how `type`, `sta`
etc regenerate the same values our regular `.pa` decoder already established (`type=121` for a Page, `sta` 1 vs 2
matching the one real difference found between the two sample files). Component/event boundaries (`att-NN`-style
markers, `Eload`/`Edown`/`Eup`-style event sections - this format's equivalent of `.pa`'s `codesload`/`codesdown`)
are not separated out: the whole file is dumped as one flat `legacy.cs` listing of `name = value  // label` lines,
which still surfaces every real attribute value and every readable string (including embedded event script code,
inline in whichever record's label run it happens to fall into) without needing those boundaries resolved.
"""
import argparse
import os
import re
import struct
import sys
import zlib

RECORD_SIZE = 28
IB_HEADER_SIZE = 27
IB_EXTENSIONS = (".is", ".ib")
I_RAW_HEADER_SIZE = 24
PA_HEADER_SIZE = 56
ZI_HEADER_SIZE = 44

# Attributes whose value is always a string regardless of its byte length (ported from lib/page.js in
# ext/nextion-hmi-format, which disambiguates these from same-length integers).
PA_STRING_ATTRS = {"objname", "txt", "path", "from", "val0", "val1"}
PA_CODE_MARKER_RE = re.compile(
    r'^(codesload|codesloadend|codesdown|codesup|codesunload|codestimer|codesslide|codesplayend)-(\d+)$')


# ---------------------------------------------------------------------------------------------------------------
# Directory
# ---------------------------------------------------------------------------------------------------------------

def read_directory(raw):
    """-> list of {i, name, offset, size, flags, stale} dicts."""
    if len(raw) < 4:
        return []
    count = struct.unpack_from("<I", raw, 0)[0]
    if count > (len(raw) - 4) // RECORD_SIZE:
        # Declared count does not even fit the file: this isn't the sparse-container format at all (seen on a
        # much smaller, differently-structured .HMI export), not just a handful of corrupt entries. Fail loudly
        # instead of silently walking the rest of the file as if every 28-byte slice were a directory record.
        raise ValueError(f"directory entry count {count} does not fit the file (not a supported .HMI container)")
    entries = []
    for i in range(count):
        o = 4 + i * RECORD_SIZE
        name_bytes = raw[o:o + 16].split(b"\x00", 1)[0]
        if not all(32 <= b < 127 for b in name_bytes):
            continue  # garbage name: not a real directory entry, skip rather than emit junk output
        offset, size, flags = struct.unpack_from("<III", raw, o + 16)
        if offset + size > len(raw):
            continue
        entries.append({"i": i, "name": name_bytes.decode("ascii"), "offset": offset, "size": size,
                         "flags": flags, "stale": bool(flags & 1)})
    return entries


def detect_landscape(raw, entries):
    """-> True/False from a live main.HMI manifest's orientation byte, or None if it can't be determined."""
    for e in entries:
        if e["stale"] or e["name"] != "main.HMI":
            continue
        b = raw[e["offset"]:e["offset"] + e["size"]]
        if len(b) >= 96 and struct.unpack_from("<I", b, 4)[0] == 96:
            return b[12] == 1
    return None


def unique_path(out_dir, filename):
    base, ext = os.path.splitext(filename)
    candidate = filename
    n = 1
    while os.path.exists(os.path.join(out_dir, candidate)):
        candidate = f"{base}_{n}{ext}"
        n += 1
    return os.path.join(out_dir, candidate)


def sanitize_filename(name):
    return re.sub(r'[\\/\x00-\x1f]', "_", name).strip() or "unnamed"


def _decode_text(b):
    """Decodes free-form text content (attribute strings, source lines, names): UTF-8 first, then GBK - these
    files commonly carry Chinese UI text and comments, and not always in the same encoding even within one
    project (seen: a QIDI project's `.txt` attribute values in UTF-8 but its `keybdA` page's code comments in
    GBK) - falling back to latin1 (which never raises) only when neither matches."""
    for enc in ("utf-8", "gbk"):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            pass
    return b.decode("latin1", "replace")


# ---------------------------------------------------------------------------------------------------------------
# Fonts (.zi)
# ---------------------------------------------------------------------------------------------------------------

def decode_zi_name(data):
    """-> the font's own name/encoding string (e.g. "gothic-40iso-8859-1"), or None.

    Stored right after the 44-byte header as a NUL-terminated string with no delimiter between the font name and
    the encoding (`pts26iso-8859-5`, `Roboto B 20iso-8859-1`, ...); there is no separate length field, so the two
    halves aren't reliably splittable, but the whole string is far more descriptive than the directory's own
    generic `N.zi` name. Verified to parse on all 246 `.zi` files of the sample corpus."""
    if len(data) < ZI_HEADER_SIZE or data[0] != 0x04 or data[1] != 0xff:
        return None
    if struct.unpack_from("<I", data, 24)[0] != ZI_HEADER_SIZE:
        return None
    nul = data.find(b"\x00", ZI_HEADER_SIZE)
    if nul == -1:
        return None
    return _decode_text(data[ZI_HEADER_SIZE:nul])


# ---------------------------------------------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------------------------------------------

def decode_ib(data):
    """-> (width, height, tag, image_bytes) for a well-formed `.is`/`.ib` PNG/JPEG container, else None.

    `tag` is read from the actual payload bytes, not the container's own 3-byte tag field: a small minority of
    files (seen in a QIDI_PLUS3 project, ~2% of the sample corpus) carry a stale tag ("jpg") left over from before
    the image was re-saved as a different format, while the payload itself is unambiguous (a real file magic)."""
    if len(data) < IB_HEADER_SIZE:
        return None
    if data[0] not in (0x0a, 0x0b) or data[1] != 0x64 or data[2] != 0x01 or data[3] != 0x01:
        return None
    header_size = struct.unpack_from("<I", data, 8)[0]
    if header_size != IB_HEADER_SIZE:
        return None
    width, height = struct.unpack_from("<HH", data, 12)
    payload_size = struct.unpack_from("<I", data, 16)[0]
    image = data[IB_HEADER_SIZE:IB_HEADER_SIZE + payload_size]
    if image[:8] == b"\x89PNG\r\n\x1a\n":
        tag = "png"
    elif image[:3] == b"\xff\xd8\xff":
        tag = "jpg"
    else:
        tag = data[24:27].decode("ascii", "replace")  # unknown payload magic: fall back to the stored tag
    return width, height, tag, image


def decode_i_raw(data, landscape=False):
    """-> (width, height, rgb_bytes) for a well-formed raw-RGB565 `.i` record, else None."""
    if len(data) < I_RAW_HEADER_SIZE:
        return None
    if data[0] not in (0x0a, 0x0b) or data[1] != 0x64 or data[2] != 0x01 or data[3] != 0x00:
        return None
    header_size = struct.unpack_from("<I", data, 8)[0]
    if header_size != I_RAW_HEADER_SIZE:
        return None
    w, h = struct.unpack_from("<HH", data, 12)
    payload_size = struct.unpack_from("<I", data, 16)[0]
    if w == 0 or h == 0 or payload_size != w * h * 2 or I_RAW_HEADER_SIZE + payload_size != len(data):
        return None

    pixels = struct.unpack_from(f"<{w * h}H", data, I_RAW_HEADER_SIZE)
    rgb = bytearray(w * h * 3)

    def put(o, v):
        rgb[o] = (v >> 11 & 0x1f) * 255 // 31
        rgb[o + 1] = (v >> 5 & 0x3f) * 255 // 63
        rgb[o + 2] = (v & 0x1f) * 255 // 31

    if landscape:
        idx = 0
        for x in range(w):
            for yy in range(h):
                y = h - 1 - yy
                put((y * w + x) * 3, pixels[idx])
                idx += 1
    else:
        for idx, v in enumerate(pixels):
            put(idx * 3, v)

    return w, h, bytes(rgb)


def _png_chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)


def write_png_rgb(path, width, height, rgb_bytes):
    """Writes a plain 8-bit RGB PNG using only the standard library (no Pillow dependency)."""
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        raw.extend(rgb_bytes[y * stride:(y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", ihdr))
        f.write(_png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(_png_chunk(b"IEND", b""))


# ---------------------------------------------------------------------------------------------------------------
# Page blocks (.pa)
# ---------------------------------------------------------------------------------------------------------------

def _decode_pa_value(key, v):
    if key in PA_STRING_ATTRS:
        return _decode_text(v.rstrip(b"\x00"))
    if len(v) == 1:
        return v[0]
    if len(v) == 2:
        return struct.unpack("<H", v)[0]
    if len(v) == 4:
        return struct.unpack("<I", v)[0]
    return _decode_text(v.rstrip(b"\x00"))


def _parse_pa_object(blk):
    """-> list of ("attr", (key, value)) / ("mark", text) / ("line", text) / ("end", None) items, in file order.

    A `codes*-N` marker is followed directly by N more records that are its source lines (blank lines stored as
    the literal text "//"), regardless of their individual length: the generic "length >= 16 means an attribute"
    rule does not apply to them, since a source line can easily run past 16 bytes and would otherwise get its
    first 16 bytes sliced off as a fake attribute name. Round-tripping (lib/page.js in ext/nextion-hmi-format)
    does not need this distinction - it only has to reproduce the same bytes - so it never surfaced there."""
    items = []
    p = 0
    pending_lines = 0
    while p + 4 <= len(blk):
        (n,) = struct.unpack_from("<I", blk, p)
        p += 4
        if n == 0:
            items.append(("end", None))
            continue
        if p + n > len(blk):
            break
        body = blk[p:p + n]
        p += n
        if pending_lines > 0:
            items.append(("line", _decode_text(body)))
            pending_lines -= 1
            continue
        body_text = _decode_text(body)
        m = PA_CODE_MARKER_RE.match(body_text)
        if m:
            items.append(("mark", body_text))
            pending_lines = int(m.group(2))
        elif n >= 16:
            key = body[:16].rstrip(b"\x00").decode("latin1", "replace")
            items.append(("attr", (key, _decode_pa_value(key, body[16:]))))
        else:
            items.append(("mark", body_text))
    return items


def decode_pa(data):
    """-> (page_name, [object_items, ...]) for a well-formed `.pa` page block, else None."""
    if len(data) < PA_HEADER_SIZE:
        return None
    total, header_size, nobj = struct.unpack_from("<III", data, 4)
    if header_size != PA_HEADER_SIZE or total != len(data):
        return None
    page_name = _decode_text(data[24:40].split(b"\x00", 1)[0])
    objs = []
    for i in range(nobj):
        p = PA_HEADER_SIZE + 12 * i
        off, size, _zero = struct.unpack_from("<III", data, p)
        blk = data[PA_HEADER_SIZE + off: PA_HEADER_SIZE + off + size]
        objs.append(_parse_pa_object(blk))
    return page_name, objs


def _format_attr_table(attrs, width=112):
    """Lays out "key=value" pairs in a dense multi-column grid instead of one per line - the attribute list of a
    single object can run to 40 entries, which is unreadable as a plain vertical list."""
    cells = [f"{k}={v}" for k, v in attrs]
    if not cells:
        return []
    col = max(len(c) for c in cells) + 2
    per_row = max(1, width // col)
    return ["".join(c.ljust(col) for c in cells[i:i + per_row]).rstrip()
            for i in range(0, len(cells), per_row)]


def render_pa_text(page_name, objs):
    out = [f"// page {page_name} ({len(objs)} objects)", ""]
    for obj in objs:
        marker = None
        attrs = []
        sections = []        # [(header, [source lines]), ...]
        current = None
        for kind, value in obj:
            if kind == "end":
                continue
            if kind == "attr":
                attrs.append(value)
            elif kind == "mark":
                if marker is None:
                    marker = value
                else:
                    current = [value, []]
                    sections.append(current)
            elif kind == "line" and current is not None:
                current[1].append(value)
        # Attributes aren't real C, so they go in a comment - the event-handler code below is real script source
        # and is left bare so editors actually syntax-highlight it.
        out.append(f"/* {marker}")
        out.extend("   " + line for line in _format_attr_table(attrs))
        out.append("*/")
        out.append("")
        for header, lines in sections:
            out.append(f"// {header}")
            out.extend(lines)
            out.append("")
        out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------
# Legacy (older, non-TJC Nextion Editor) format
# ---------------------------------------------------------------------------------------------------------------

LEGACY_RECORD_PREFIX = 28  # bytes from the start of a record to its value, see the module docstring


def _looks_like_legacy_record(data, p):
    if p + LEGACY_RECORD_PREFIX > len(data):
        return False
    name = data[p:p + 8]
    nul = name.find(b"\x00")
    if nul <= 0 or any(name[nul:]):
        return False
    if not all(32 <= b < 127 for b in name[:nul]):
        return False
    w1, w2 = struct.unpack_from("<HH", data, p + 8)
    if w1 != w2 or w1 not in (1, 2, 4):
        return False
    return data[p + 13] == 0xff


def _decode_legacy_value(width, raw):
    if width == 1:
        return raw[0]
    if width == 2:
        return struct.unpack("<H", raw)[0]
    return struct.unpack("<I", raw)[0]


def decode_legacy_attributes(data, start=0, end=None):
    """-> [(name, width, value, label, record_start), ...] - see the module docstring for the record shape. Scans
    byte-by-byte for the record signature rather than relying on a known attribute name list, since this format's
    vocabulary doesn't match `.pa`'s (confirmed missing: objname, codesload, sendkey, groupid0)."""
    end = len(data) if end is None else end
    records = []
    p = start
    while p < end:
        if not _looks_like_legacy_record(data, p):
            p += 1
            continue
        name = data[p:p + 8].split(b"\x00", 1)[0].decode("ascii")
        width = struct.unpack_from("<H", data, p + 8)[0]
        value_off = p + LEGACY_RECORD_PREFIX
        value = _decode_legacy_value(width, data[value_off:value_off + width])
        # The label run stops at the next recognized record or at the first control byte, whichever comes first:
        # genuine help text is plain text, so a control byte means we've run into something this format's record
        # shape doesn't cover (string-valued attributes, component/event-section boundaries) - better to stop
        # cleanly there than show its raw bytes as if they were part of the label.
        q = value_off + width
        while q < end and not _looks_like_legacy_record(data, q) and (data[q] >= 0x20 or data[q] in b"\t\n"):
            q += 1
        label = _decode_text(data[value_off + width:q])
        records.append((name, width, value, label, p))
        p = q
    return records


def render_legacy_text(records):
    out = []
    for name, _width, value, label, _pos in records:
        if name == "type":
            out.append("")
        out.append(f"{name} = {value}  // {label}" if label else f"{name} = {value}")
    return "\n".join(out)


def extract_legacy(path, out_dir):
    """Best-effort extraction for the older Nextion Editor format: a single flat `legacy.cs` text dump (component
    and event-section boundaries aren't resolved, see the module docstring)."""
    raw = open(path, "rb").read()
    records = decode_legacy_attributes(raw)
    if not records:
        raise ValueError("not a recognized legacy .HMI format either (no attribute records found)")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "legacy.cs")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render_legacy_text(records))
    return records, out_path


# ---------------------------------------------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------------------------------------------

def extract(path, out_dir, unpack_images=True, unpack_pa=True, convert_i=True, include_stale=False):
    """Extracts into subdirectories by kind (pages/, pictures/, fonts/, scripts/, other/), the same layout style as
    TFTTool.py's own writeOutput()."""
    raw = open(path, "rb").read()
    entries = read_directory(raw)
    if not entries:
        raise ValueError("no resource directory found at the start of the file")
    landscape = bool(detect_landscape(raw, entries)) if convert_i else False

    written = []
    picture_bases = set()  # base names already covered by a decoded .is/.ib picture

    def process(e):
        name = e["name"] if e["name"] else f"unnamed_{e['i']:04d}"
        data = raw[e["offset"]:e["offset"] + e["size"]]
        lower = name.lower()

        if lower.endswith(".ib"):
            subdir = "ib"
        elif lower.endswith(".is"):
            subdir = "is"
        elif lower.endswith(".i"):
            subdir = "i"
        elif lower.endswith(".pa"):
            subdir = "pages"
        elif lower.endswith(".zi"):
            subdir = "fonts"
        elif lower.endswith(".s"):
            subdir = "scripts"
        else:
            subdir = "other"
        out_name, binary, text = name, data, None

        if unpack_images and lower.endswith(IB_EXTENSIONS):
            decoded = decode_ib(data)
            if decoded:
                _, _, tag, image = decoded
                out_name, binary = name[:-3] + "." + tag, image
                picture_bases.add(name[:-3].lower())

        elif lower.endswith(".i"):
            if name[:-2].lower() in picture_bases:
                return  # a sibling .is/.ib already produced this same picture; the .i copy is redundant
            if convert_i:
                decoded = decode_i_raw(data, landscape=landscape)
                if decoded:
                    w, h, rgb = decoded
                    out_dir_full = os.path.join(out_dir, subdir)
                    os.makedirs(out_dir_full, exist_ok=True)
                    out_path = unique_path(out_dir_full, name[:-2] + ".png")
                    write_png_rgb(out_path, w, h, rgb)
                    written.append((e, out_path))
                    return

        elif unpack_pa and lower.endswith(".pa"):
            decoded = decode_pa(data)
            if decoded:
                page_name, objs = decoded
                out_name = (sanitize_filename(page_name) if page_name else name[:-3]) + ".cs"
                text = render_pa_text(page_name, objs)

        elif lower.endswith(".zi"):
            zi_name = decode_zi_name(data)
            if zi_name:
                out_name = sanitize_filename(zi_name) + ".zi"

        elif lower.endswith(".s"):
            # the global (pre-init) script, not per-object attribute data like .pa - same encoding uncertainty applies
            text = _decode_text(data.rstrip(b"\x00"))

        out_dir_full = os.path.join(out_dir, subdir)
        os.makedirs(out_dir_full, exist_ok=True)
        out_path = unique_path(out_dir_full, out_name)
        if text is not None:
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text)
        else:
            with open(out_path, "wb") as f:
                f.write(binary)
        written.append((e, out_path))

    live = [e for e in entries if include_stale or not e["stale"]]
    skipped_stale = len(entries) - len(live)
    # Process .is/.ib (and everything else) before plain .i, so a sibling picture is already known by the time a
    # same-numbered .i is considered, regardless of which order the directory itself lists them in.
    plain_i = [e for e in live if e["name"].lower().endswith(".i")]
    others = [e for e in live if not e["name"].lower().endswith(".i")]
    for e in others:
        process(e)
    for e in plain_i:
        process(e)

    return entries, written, skipped_stale


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-i", "--input", metavar="HMI_FILE", required=True, dest="hmi_file",
                   help="path to the .HMI project file")
    p.add_argument("-o", "--output", metavar="OUTPUT_DIR", default=None, dest="out_dir",
                   help="directory to extract the resources into, as pages/is/ib/i/fonts/scripts/other "
                        "subdirectories (default: the input file's basename without extension); must not "
                        "already exist")
    p.add_argument("--no-unpack-images", dest="unpack_images", action="store_false",
                   help="keep .is/.ib resources as raw containers instead of unpacking the embedded PNG/JPEG")
    p.add_argument("--no-convert-i", dest="convert_i", action="store_false",
                   help="keep .i resources as raw containers instead of converting the raw RGB565 ones to PNG")
    p.add_argument("--no-unpack-pa", dest="unpack_pa", action="store_false",
                   help="keep .pa resources as raw containers instead of a readable text dump")
    p.add_argument("--include-stale", action="store_true",
                   help="also extract directory entries flagged as stale (leftover copies from earlier saves)")
    args = p.parse_args()

    if args.out_dir is None:
        args.out_dir = os.path.splitext(os.path.basename(args.hmi_file))[0]
    if os.path.exists(args.out_dir):
        print(f"error: output directory {args.out_dir!r} already exists", file=sys.stderr)
        sys.exit(1)

    try:
        entries, written, skipped_stale = extract(
            args.hmi_file, args.out_dir,
            unpack_images=args.unpack_images, unpack_pa=args.unpack_pa,
            convert_i=args.convert_i, include_stale=args.include_stale)
    except ValueError as exc:
        try:
            records, out_path = extract_legacy(args.hmi_file, args.out_dir)
        except ValueError:
            print(f"error: {exc}", file=sys.stderr)
            sys.exit(1)
        print(f"not the usual .HMI container ({exc}); fell back to the older Nextion Editor format: "
              f"{len(records)} attributes dumped to {out_path}")
        return

    print(f"{len(written)} resources extracted to {args.out_dir} ({skipped_stale} stale entries skipped)")
    kinds = {}
    for e, _ in written:
        name = e["name"]
        ext = name.rsplit(".", 1)[-1] if "." in name else "<none>"
        c, s = kinds.get(ext, (0, 0))
        kinds[ext] = (c + 1, s + e["size"])
    for ext, (count, total) in sorted(kinds.items(), key=lambda kv: -kv[1][1]):
        print(f"  .{ext:<8s} {count:4d} files, {total:10d} bytes")


if __name__ == "__main__":
    main()
