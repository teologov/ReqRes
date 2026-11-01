#!/usr/bin/env python3
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
"""
build-geo-resources.py — turns public geodata into GeoKit's bundled resources.

    Sources (downloaded with --download, never committed):
      dbip-country-lite-YYYY-MM.csv.gz   DB-IP "IP to Country Lite", CC BY 4.0
      ne_110m_admin_0_countries.geojson  Natural Earth 1:110m Admin 0, public domain
      zone.tab + backward                IANA tz database, public domain

    Outputs (Sources/AppServices/Sources/GeoKit/Resources/):
      dbip-country.bin     IPv4 + IPv6 → country, block-indexed varint deltas
      world-110m.geojson   country outlines, {iso,name} + 2-decimal coordinates
      centroids.json       ISO2 → [lat, lon], one point per country
      tz-countries.tsv     tz identifier → ISO2
    plus Tests/GeoKitTests/Fixtures/ip-samples.csv, sampled from the same CSV so
    the Swift decoder is checked against the data it was built from.

Deterministic: the same inputs give byte-identical outputs. Python 3 standard
library only.

    --download DIR --month YYYY-MM       fetch the sources into DIR
    --build --sources DIR                convert; writes every output above
    --check [--sources DIR]              verify the committed resources are in
                                         canonical form (round-trip through the
                                         encoder), agree with PROVENANCE.md and,
                                         when --sources is given, match a fresh
                                         conversion byte for byte

BINARY FORMAT (dbip-country.bin, version 1, all integers little-endian)

  Fixed (start, end, country u16) rows would be 15.8 MB for this data, against
  a budget of about 3 MB for the whole addition, so the table stores STARTS only
  (the ranges are contiguous once every gap is filled with ZZ, so each row's end
  is the next start − 1) and encodes them as deltas:

  header (64 bytes)
     0  4  magic "GEOI"
     4  2  version = 1
     6  2  header length = 64
     8  8  data month "YYYY-MM", NUL padded
    16  2  country count (≤ 255; the country index is one byte)
    18  2  block size B (rows per index entry)
    20  4  IPv4 shifts for tags 0..3   (24, 16, 8, 0)
    24  4  IPv6 shifts for tags 0..3   (96, 80, 64, 0)
    28  4  IPv4 row count
    32  4  IPv6 row count
    36  4  offset: country table   (count × 2 ASCII bytes, sorted)
    40  4  offset: IPv4 index      (per block: start u32, stream offset u32)
    44  4  offset: IPv4 stream
    48  4  offset: IPv6 index      (per block: start u128, stream offset u32)
    52  4  offset: IPv6 stream
    56  4  file length
    60  4  reserved = 0

  stream, per block: country byte of the block's first row (its start is in the
  index), then for each following row a LEB128 varint V and a country byte,
  where tag = V & 3, delta = (V >> 2) << shifts[tag], start = previous + delta.
  The encoder picks the tag that yields the shortest varint. Lookup: binary
  search the index for the last block start ≤ ip, then walk the block until the
  next start exceeds ip.
"""

import argparse
import csv
import gzip
import hashlib
import io
import ipaddress
import json
import math
import os
import random
import re
import struct
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
RESOURCES = os.path.join(REPO, "Sources", "AppServices", "Sources", "GeoKit", "Resources")
FIXTURES = os.path.join(REPO, "Sources", "AppServices", "Tests", "GeoKitTests", "Fixtures")

MAGIC = b"GEOI"
VERSION = 1
HEADER_LEN = 64
BLOCK = 64
V4_SHIFTS = (24, 16, 8, 0)
V6_SHIFTS = (96, 80, 64, 0)
V4_MAX = (1 << 32) - 1
V6_MAX = (1 << 128) - 1
UNKNOWN = "ZZ"

OUT_BIN = "dbip-country.bin"
OUT_GEOJSON = "world-110m.geojson"
OUT_CENTROIDS = "centroids.json"
OUT_TZ = "tz-countries.tsv"
OUT_SAMPLES = "ip-samples.csv"
PROVENANCE = "PROVENANCE.md"

DBIP_URL = "https://download.db-ip.com/free/dbip-country-lite-{month}.csv.gz"
NE_URL = ("https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/"
          "geojson/ne_110m_admin_0_countries.geojson")
TZ_ZONE_URL = "https://raw.githubusercontent.com/eggert/tz/main/zone.tab"
TZ_BACKWARD_URL = "https://raw.githubusercontent.com/eggert/tz/main/backward"

# Countries DB-IP knows that have no polygon at 1:110m (islands and
# micro-states smaller than the scale). Hand-placed, approximate (a capital or
# the main island); precision is irrelevant at world-map scale. These exist so
# a request to Singapore or Hong Kong — among the most common destinations —
# still gets a dot.
HAND_PLACED = {
    "AD": (42.51, 1.52), "AG": (17.06, -61.80), "AI": (18.22, -63.07),
    "AS": (-14.27, -170.70), "AW": (12.52, -69.97), "AX": (60.18, 19.92),
    "BB": (13.19, -59.54), "BH": (26.07, 50.55), "BL": (17.90, -62.83),
    "BM": (32.32, -64.76), "BQ": (12.18, -68.26), "BV": (-54.42, 3.36),
    "CC": (-12.17, 96.84), "CK": (-21.24, -159.78), "CV": (15.12, -23.60),
    "CW": (12.17, -68.99), "CX": (-10.49, 105.63), "DM": (15.41, -61.37),
    "FM": (6.92, 158.16), "FO": (62.00, -6.78), "GD": (12.12, -61.68),
    "GF": (3.93, -53.13), "GG": (49.46, -2.58), "GI": (36.14, -5.35),
    "GP": (16.25, -61.55), "GS": (-54.43, -36.59), "GU": (13.44, 144.79),
    "HK": (22.32, 114.17), "HM": (-53.08, 73.50), "IM": (54.24, -4.55),
    "IO": (-7.33, 72.42), "JE": (49.21, -2.13), "KI": (1.42, 173.00),
    "KM": (-11.65, 43.33), "KN": (17.36, -62.78), "KY": (19.31, -81.25),
    "LC": (13.91, -60.98), "LI": (47.17, 9.55), "MC": (43.73, 7.42),
    "MF": (18.07, -63.05), "MH": (7.11, 171.19), "MO": (22.20, 113.55),
    "MP": (15.19, 145.75), "MQ": (14.64, -61.02), "MS": (16.74, -62.19),
    "MT": (35.90, 14.51), "MU": (-20.35, 57.55), "MV": (4.17, 73.51),
    "NF": (-29.04, 167.95), "NR": (-0.53, 166.93), "NU": (-19.05, -169.87),
    "PF": (-17.68, -149.41), "PM": (46.78, -56.18), "PN": (-25.07, -130.10),
    "PW": (7.51, 134.58), "RE": (-21.12, 55.54), "SC": (-4.68, 55.49),
    "SG": (1.35, 103.82), "SH": (-15.97, -5.71), "SJ": (78.22, 15.63),
    "SM": (43.94, 12.46), "ST": (0.34, 6.73), "SX": (18.04, -63.07),
    "TC": (21.69, -71.80), "TK": (-9.20, -171.85), "TO": (-21.18, -175.20),
    "TV": (-8.52, 179.20), "UM": (19.28, 166.65), "VA": (41.90, 12.45),
    "VC": (13.25, -61.20), "VG": (18.42, -64.64), "VI": (18.34, -64.90),
    "WF": (-13.77, -177.16), "WS": (-13.76, -172.10), "YT": (-12.83, 45.17),
}

# Where the largest polygon's area centroid is the wrong point for a label.
# The converter computes the centroid for every outline and REFUSES to build
# if a computed point is outside its own polygon and not listed here, so this
# list can only grow for a reason. Measured against the 1:110m outlines:
#   HR  Croatia is a crescent around Bosnia; the centroid (45.02, 16.57) is in
#       Bosnia. Moved north-west, near Zagreb.
#   HT  Haiti's two arms enclose the Gulf of Gonâve; the centroid (18.90,
#       -72.66) is at sea. Moved to the Port-au-Prince plain.
#   IL  Israel's centroid (31.48, 35.00) lands in the West Bank, which is the
#       PS polygon at this scale. Moved to the northern Negev.
#   NO  fjords and the northern arm put the centroid (64.54, 14.25) in Sweden.
#       Moved to the mainland south of Trondheim.
#   VN  the S-shape puts the centroid (16.65, 106.29) in Laos. Moved to the
#       central highlands.
# Two are inside their polygon but the largest polygon is the wrong island:
#   ID  the largest polygon is Indonesian Borneo (Kalimantan); the point people
#       expect — and where the data centres are — is Java.
#   MY  the largest polygon is Malaysian Borneo (Sarawak/Sabah); use the
#       peninsula, where Kuala Lumpur is.
# Checked and left computed: US (the largest polygon IS the contiguous 48, so
# Alaska never enters), RU (central Siberia is right for that size), JP
# (Honshu), CL (inside, despite the shape), CA, AU, GB, FR, IT, GR, PH, NZ.
HAND_FIXED = {
    "HR": (45.50, 16.00),
    "HT": (18.60, -72.30),
    "IL": (31.50, 34.85),
    "NO": (62.50, 9.50),
    "VN": (13.80, 108.30),
    "ID": (-7.30, 110.00),
    "MY": (3.90, 102.00),
}


# --------------------------------------------------------------------------
# helpers

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def open_text(path):
    if path.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "rb"), encoding="utf-8", newline="")
    return open(path, "r", encoding="utf-8", newline="")


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def read_varint(buf, pos):
    result = 0
    shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 140:
            raise ValueError("varint too long")


def fail(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


# --------------------------------------------------------------------------
# DB-IP → binary

def load_dbip(path):
    """Returns (v4_rows, v6_rows, month) with rows as sorted, contiguous,
    merged (start, country) lists covering the whole address space."""
    v4 = []
    v6 = []
    with open_text(path) as f:
        for row in csv.reader(f):
            if not row or row[0].startswith("#"):
                continue
            start, end, country = row[0].strip(), row[1].strip(), row[2].strip().upper()
            if not (len(country) == 2 and country.isalpha()):
                fail("unexpected country code %r in %s" % (country, path))
            if ":" in start:
                v6.append((int(ipaddress.IPv6Address(start)), int(ipaddress.IPv6Address(end)), country))
            else:
                v4.append((int(ipaddress.IPv4Address(start)), int(ipaddress.IPv4Address(end)), country))
    m = re.search(r"(\d{4}-\d{2})", os.path.basename(path))
    month = m.group(1) if m else None
    return contiguous(v4, V4_MAX), contiguous(v6, V6_MAX), month


def contiguous(ranges, maximum):
    """Sort, reject overlaps, fill gaps with ZZ, merge neighbours with the same
    country, and return [(start, country)] — the END of every row is implied by
    the next row's start (or `maximum` for the last)."""
    ranges.sort()
    rows = []
    cursor = 0
    for start, end, country in ranges:
        if start < cursor:
            fail("overlapping ranges at %d" % start)
        if start > cursor:
            rows.append((cursor, UNKNOWN))
        rows.append((start, country))
        cursor = end + 1
    if cursor <= maximum:
        rows.append((cursor, UNKNOWN))
    merged = []
    for start, country in rows:
        if merged and merged[-1][1] == country:
            continue
        merged.append((start, country))
    return merged


def encode_table(rows, country_index, shifts, start_bytes, block):
    index = bytearray()
    stream = bytearray()
    for i in range(0, len(rows), block):
        start, country = rows[i]
        index += start.to_bytes(start_bytes, "little") + struct.pack("<I", len(stream))
        stream.append(country_index[country])
        previous = start
        for start, country in rows[i + 1:i + block]:
            delta = start - previous
            previous = start
            best = None
            for tag, shift in enumerate(shifts):
                if delta & ((1 << shift) - 1) == 0:
                    candidate = varint(((delta >> shift) << 2) | tag)
                    if best is None or len(candidate) < len(best):
                        best = candidate
            stream += best
            stream.append(country_index[country])
    return bytes(index), bytes(stream)


def build_binary(v4, v6, month):
    countries = sorted(set(c for _, c in v4) | set(c for _, c in v6))
    if len(countries) > 255:
        fail("%d countries do not fit a one-byte index" % len(countries))
    country_index = {c: i for i, c in enumerate(countries)}
    v4_index, v4_stream = encode_table(v4, country_index, V4_SHIFTS, 4, BLOCK)
    v6_index, v6_stream = encode_table(v6, country_index, V6_SHIFTS, 16, BLOCK)
    table = "".join(countries).encode("ascii")

    offset = HEADER_LEN
    off_countries = offset
    offset += len(table)
    off_v4_index = offset
    offset += len(v4_index)
    off_v4_stream = offset
    offset += len(v4_stream)
    off_v6_index = offset
    offset += len(v6_index)
    off_v6_stream = offset
    offset += len(v6_stream)
    length = offset

    header = struct.pack(
        "<4sHH8sHH4B4BIIIIIIIII",
        MAGIC, VERSION, HEADER_LEN, month.encode("ascii").ljust(8, b"\0"),
        len(countries), BLOCK, *V4_SHIFTS, *V6_SHIFTS,
        len(v4), len(v6),
        off_countries, off_v4_index, off_v4_stream, off_v6_index, off_v6_stream,
        length, 0,
    )
    assert len(header) == HEADER_LEN, len(header)
    return header + table + v4_index + v4_stream + v6_index + v6_stream


def decode_binary(blob):
    """Inverse of build_binary — the reference decoder --check uses to prove the
    committed file is canonical. Returns (v4_rows, v6_rows, month)."""
    if len(blob) < HEADER_LEN:
        fail("binary too short")
    fields = struct.unpack_from("<4sHH8sHH4B4BIIIIIIIII", blob, 0)
    magic, version, header_len, month = fields[0], fields[1], fields[2], fields[3]
    country_count, block = fields[4], fields[5]
    v4_shifts, v6_shifts = tuple(fields[6:10]), tuple(fields[10:14])
    v4_rows, v6_rows = fields[14], fields[15]
    off_c, off_v4i, off_v4s, off_v6i, off_v6s, length, reserved = fields[16:23]
    if magic != MAGIC or version != VERSION or header_len != HEADER_LEN:
        fail("binary header mismatch: %r v%d len %d" % (magic, version, header_len))
    if length != len(blob) or reserved != 0:
        fail("binary length mismatch")
    if block != BLOCK or v4_shifts != V4_SHIFTS or v6_shifts != V6_SHIFTS:
        fail("binary parameters differ from this converter's")
    month = month.rstrip(b"\0").decode("ascii")
    countries = [blob[off_c + 2 * i:off_c + 2 * i + 2].decode("ascii") for i in range(country_count)]

    def decode(rows, shifts, start_bytes, off_index, off_stream, end):
        out = []
        blocks = (rows + block - 1) // block
        for b in range(blocks):
            entry = off_index + b * (start_bytes + 4)
            start = int.from_bytes(blob[entry:entry + start_bytes], "little")
            (stream_off,) = struct.unpack_from("<I", blob, entry + start_bytes)
            pos = off_stream + stream_off
            out.append((start, countries[blob[pos]]))
            pos += 1
            for _ in range(min(block, rows - b * block) - 1):
                value, pos = read_varint(blob, pos)
                start += (value >> 2) << shifts[value & 3]
                out.append((start, countries[blob[pos]]))
                pos += 1
            if b == blocks - 1 and pos != end:
                fail("stream has trailing bytes")
        return out

    v4 = decode(v4_rows, v4_shifts, 4, off_v4i, off_v4s, off_v6i)
    v6 = decode(v6_rows, v6_shifts, 16, off_v6i, off_v6s, length)
    return v4, v6, month


def lookup(rows, ip):
    """Bisect on starts — what the Swift side does, minus the blocks."""
    lo, hi = 0, len(rows)
    while lo < hi:
        mid = (lo + hi) // 2
        if rows[mid][0] <= ip:
            lo = mid + 1
        else:
            hi = mid
    return rows[lo - 1][1] if lo else UNKNOWN


def write_samples(v4, v6, path, count=400):
    """Deterministic random addresses with their expected country, for the Swift
    tests. Edges (a range's first and last address) are over-represented on
    purpose — off-by-one in the decoder shows up there first."""
    rng = random.Random(20260901)
    lines = []

    def sample(rows, maximum, make):
        for _ in range(count):
            i = rng.randrange(len(rows))
            start = rows[i][0]
            end = rows[i + 1][0] - 1 if i + 1 < len(rows) else maximum
            choice = rng.random()
            if choice < 0.25:
                ip = start
            elif choice < 0.5:
                ip = end
            else:
                ip = rng.randint(start, end)
            lines.append("%s,%s" % (make(ip), rows[i][1]))

    sample(v4, V4_MAX, lambda ip: str(ipaddress.IPv4Address(ip)))
    sample(v6, V6_MAX, lambda ip: str(ipaddress.IPv6Address(ip)))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# address,expected — generated by Scripts/geo/build-geo-resources.py; ZZ = unknown\n")
        f.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# Natural Earth → trimmed GeoJSON + centroids

def iso_of(properties):
    for key in ("ISO_A2_EH", "ISO_A2"):
        value = properties.get(key)
        if isinstance(value, str) and len(value) == 2 and value.isalpha() and value.isupper():
            return value
    return None


def round_coordinate(value):
    value = round(value, 2)
    if value == 0:
        value = 0.0  # never "-0.0"
    return value


def clean_ring(ring):
    out = []
    for lon, lat in (pt[:2] for pt in ring):
        pt = [round_coordinate(lon), round_coordinate(lat)]
        if not out or out[-1] != pt:
            out.append(pt)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    if len(out) < 3:
        return None
    out.append(list(out[0]))
    return out


def clean_polygon(rings):
    exterior = clean_ring(rings[0])
    if exterior is None:
        return None
    holes = [h for h in (clean_ring(r) for r in rings[1:]) if h is not None]
    return [exterior] + holes


def trim_geojson(source):
    features = []
    for feature in source["features"]:
        props = feature["properties"]
        geometry = feature["geometry"]
        if geometry["type"] == "Polygon":
            polygons = [geometry["coordinates"]]
        elif geometry["type"] == "MultiPolygon":
            polygons = geometry["coordinates"]
        else:
            fail("unexpected geometry %s" % geometry["type"])
        cleaned = [p for p in (clean_polygon(rings) for rings in polygons) if p is not None]
        if not cleaned:
            continue
        if len(cleaned) == 1:
            geom = {"type": "Polygon", "coordinates": cleaned[0]}
        else:
            geom = {"type": "MultiPolygon", "coordinates": cleaned}
        features.append({
            "type": "Feature",
            "properties": {"iso": iso_of(props), "name": props["NAME"]},
            "geometry": geom,
        })
    features.sort(key=lambda f: (f["properties"]["name"], f["properties"]["iso"] or ""))
    return {"type": "FeatureCollection", "features": features}


def canonical_json(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n"


def ring_area_centroid(ring):
    """Planar shoelace on lon/lat degrees — good enough to pick the largest
    polygon and to place a label."""
    area2 = 0.0
    cx = 0.0
    cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        cross = x0 * y1 - x1 * y0
        area2 += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(area2) < 1e-12:
        xs = [p[0] for p in ring]
        ys = [p[1] for p in ring]
        return 0.0, (sum(xs) / len(xs), sum(ys) / len(ys))
    return abs(area2) / 2.0, (cx / (3.0 * area2), cy / (3.0 * area2))


def point_in_ring(lon, lat, ring):
    inside = False
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        if (y0 > lat) != (y1 > lat):
            x = x0 + (lat - y0) * (x1 - x0) / (y1 - y0)
            if lon < x:
                inside = not inside
    return inside


def point_in_polygon(lon, lat, polygon):
    if not point_in_ring(lon, lat, polygon[0]):
        return False
    return not any(point_in_ring(lon, lat, hole) for hole in polygon[1:])


def polygons_of(feature):
    geom = feature["geometry"]
    return [geom["coordinates"]] if geom["type"] == "Polygon" else geom["coordinates"]


def compute_centroids(trimmed, dbip_countries):
    centroids = {}
    problems = []
    for feature in trimmed["features"]:
        iso = feature["properties"]["iso"]
        if iso is None:
            continue
        polygons = polygons_of(feature)
        largest = max(polygons, key=lambda p: ring_area_centroid(p[0])[0])
        _, (lon, lat) = ring_area_centroid(largest[0])
        lat, lon = round(lat, 2), round(lon, 2)
        if iso in HAND_FIXED:
            lat, lon = HAND_FIXED[iso]
        inside = any(point_in_polygon(lon, lat, p) for p in polygons)
        if not inside:
            problems.append("%s (%s): centroid %.2f,%.2f is outside its outline — add it to HAND_FIXED"
                            % (iso, feature["properties"]["name"], lat, lon))
        centroids[iso] = [lat, lon]
    for iso, (lat, lon) in HAND_PLACED.items():
        if iso in centroids:
            problems.append("%s is HAND_PLACED but has an outline; remove it from HAND_PLACED" % iso)
        centroids[iso] = [lat, lon]
    for iso in HAND_FIXED:
        if iso not in centroids:
            problems.append("%s is HAND_FIXED but has no outline" % iso)
    missing = sorted(c for c in dbip_countries if c != UNKNOWN and c not in centroids)
    if missing:
        problems.append("DB-IP countries with no centroid (add to HAND_PLACED): %s" % ", ".join(missing))
    if problems:
        fail("\n  " + "\n  ".join(problems))
    return dict(sorted(centroids.items()))


# --------------------------------------------------------------------------
# tz database → zone → country

def build_tz_table(zone_tab_path, backward_path):
    zones = {}
    with open(zone_tab_path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                fail("malformed zone.tab line: %r" % line)
            zones[parts[2]] = parts[0]
    links = {}
    with open(backward_path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if parts[0] != "Link" or len(parts) < 3:
                continue
            links[parts[2]] = parts[1]
    table = dict(zones)
    for link, target in links.items():
        seen = set()
        while target in links and target not in zones and target not in seen:
            seen.add(target)
            target = links[target]
        if target in zones and link not in table:
            table[link] = zones[target]
    lines = ["# tz identifier\tISO 3166-1 alpha-2 — from the IANA tz database's zone.tab and "
             "backward (public domain); generated by Scripts/geo/build-geo-resources.py"]
    lines += ["%s\t%s" % (zone, cc) for zone, cc in sorted(table.items())]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# modes

def find_sources(directory):
    dbip = sorted(n for n in os.listdir(directory) if n.startswith("dbip-country-lite-") and n.endswith((".csv", ".csv.gz")))
    if not dbip:
        fail("no dbip-country-lite-YYYY-MM.csv[.gz] in %s" % directory)
    paths = {
        "dbip": os.path.join(directory, dbip[-1]),
        "ne": os.path.join(directory, "ne_110m_admin_0_countries.geojson"),
        "zone_tab": os.path.join(directory, "zone.tab"),
        "backward": os.path.join(directory, "backward"),
    }
    for key, path in paths.items():
        if not os.path.exists(path):
            fail("missing source %s (%s)" % (key, path))
    return paths


def convert(paths, verbose=True):
    v4, v6, month = load_dbip(paths["dbip"])
    if not month:
        fail("cannot read the data month from %s" % paths["dbip"])
    blob = build_binary(v4, v6, month)
    with open(paths["ne"], encoding="utf-8") as f:
        trimmed = trim_geojson(json.load(f))
    geojson = canonical_json(trimmed)
    countries = set(c for _, c in v4) | set(c for _, c in v6)
    centroids = canonical_json(compute_centroids(trimmed, countries))
    tz = build_tz_table(paths["zone_tab"], paths["backward"])
    outputs = {
        OUT_BIN: blob,
        OUT_GEOJSON: geojson.encode("utf-8"),
        OUT_CENTROIDS: centroids.encode("utf-8"),
        OUT_TZ: tz.encode("utf-8"),
    }
    if verbose:
        print("data month     %s" % month)
        print("IPv4 rows      %d   IPv6 rows %d   countries %d" % (len(v4), len(v6), len(countries)))
        print("outlines       %d features, %d with an ISO code"
              % (len(trimmed["features"]), sum(1 for f in trimmed["features"] if f["properties"]["iso"])))
        print("centroids      %d" % (centroids.count("["),))
        print("tz rows        %d" % (tz.count("\n") - 1))
        for name, data in outputs.items():
            print("%-22s %9d bytes" % (name, len(data)))
        print("%-22s %9d bytes" % ("total", sum(len(d) for d in outputs.values())))
        for key in ("dbip", "ne", "zone_tab", "backward"):
            print("sha256 %-9s %s  %s" % (key, sha256(paths[key]), os.path.basename(paths[key])))
    return outputs, (v4, v6, month)


def do_build(args):
    paths = find_sources(args.sources)
    outputs, (v4, v6, month) = convert(paths)
    os.makedirs(args.resources, exist_ok=True)
    for name, data in outputs.items():
        with open(os.path.join(args.resources, name), "wb") as f:
            f.write(data)
    os.makedirs(args.fixtures, exist_ok=True)
    write_samples(v4, v6, os.path.join(args.fixtures, OUT_SAMPLES))
    self_test(outputs[OUT_BIN], v4, v6)
    print("wrote %s and %s" % (args.resources, os.path.join(args.fixtures, OUT_SAMPLES)))
    print("remember: PROVENANCE.md must name month %s and the SHA-256s above" % month)


def self_test(blob, v4, v6):
    d4, d6, _ = decode_binary(blob)
    if d4 != v4 or d6 != v6:
        fail("binary does not round-trip")
    rng = random.Random(7)
    for rows, maximum in ((v4, V4_MAX), (v6, V6_MAX)):
        for _ in range(2000):
            i = rng.randrange(len(rows))
            end = rows[i + 1][0] - 1 if i + 1 < len(rows) else maximum
            ip = rng.randint(rows[i][0], end)
            if lookup(rows, ip) != rows[i][1]:
                fail("lookup disagrees with the row table at %d" % ip)


def do_check(args):
    problems = []
    for name in (OUT_BIN, OUT_GEOJSON, OUT_CENTROIDS, OUT_TZ, PROVENANCE):
        if not os.path.exists(os.path.join(args.resources, name)):
            problems.append("missing resource %s" % name)
    if problems:
        fail("\n  " + "\n  ".join(problems))

    with open(os.path.join(args.resources, OUT_BIN), "rb") as f:
        blob = f.read()
    v4, v6, month = decode_binary(blob)
    for rows, maximum, label in ((v4, V4_MAX, "IPv4"), (v6, V6_MAX, "IPv6")):
        if not rows or rows[0][0] != 0:
            problems.append("%s table does not start at address 0" % label)
        if any(a[0] >= b[0] for a, b in zip(rows, rows[1:])):
            problems.append("%s starts are not strictly increasing" % label)
        if any(a[1] == b[1] for a, b in zip(rows, rows[1:])):
            problems.append("%s has unmerged neighbours" % label)
        if rows[-1][0] > maximum:
            problems.append("%s start beyond the address space" % label)
    if build_binary(v4, v6, month) != blob:
        problems.append("%s is not the canonical encoding of its own rows" % OUT_BIN)

    with open(os.path.join(args.resources, OUT_GEOJSON), encoding="utf-8") as f:
        text = f.read()
    trimmed = json.loads(text)
    if canonical_json(trimmed) != text:
        problems.append("%s is not in canonical form" % OUT_GEOJSON)
    for feature in trimmed["features"]:
        if set(feature["properties"]) != {"iso", "name"}:
            problems.append("%s carries extra properties" % feature["properties"].get("name"))
        for polygon in polygons_of(feature):
            for ring in polygon:
                if ring[0] != ring[-1] or len(ring) < 4:
                    problems.append("%s has an open or degenerate ring" % feature["properties"]["name"])
                for lon, lat in ring:
                    if round(lon, 2) != lon or round(lat, 2) != lat or not (-180 <= lon <= 180 and -90 <= lat <= 90):
                        problems.append("%s has an unrounded or out-of-range coordinate" % feature["properties"]["name"])
                        break

    with open(os.path.join(args.resources, OUT_CENTROIDS), encoding="utf-8") as f:
        ctext = f.read()
    centroids = json.loads(ctext)
    countries = set(c for _, c in v4) | set(c for _, c in v6)
    if canonical_json(compute_centroids(trimmed, countries)) != ctext:
        problems.append("%s does not match the outlines + hand tables" % OUT_CENTROIDS)

    with open(os.path.join(args.resources, PROVENANCE), encoding="utf-8") as f:
        provenance = f.read()
    if month not in provenance:
        problems.append("PROVENANCE.md does not mention data month %s" % month)

    if args.sources:
        outputs, _ = convert(find_sources(args.sources), verbose=False)
        for name, data in outputs.items():
            with open(os.path.join(args.resources, name), "rb") as f:
                if f.read() != data:
                    problems.append("%s differs from a fresh conversion" % name)
        sample_path = os.path.join(args.fixtures, OUT_SAMPLES)
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            pass
        try:
            write_samples(v4, v6, tmp.name)
            with open(tmp.name, "rb") as a, open(sample_path, "rb") as b:
                if a.read() != b.read():
                    problems.append("%s differs from a fresh sample" % OUT_SAMPLES)
        finally:
            os.unlink(tmp.name)

    if problems:
        fail("\n  " + "\n  ".join(problems))
    print("ok: %s (data month %s, %d IPv4 + %d IPv6 rows, %d outlines, %d centroids)"
          % (args.resources, month, len(v4), len(v6), len(trimmed["features"]), len(centroids)))


def do_download(args):
    if not args.month:
        fail("--download needs --month YYYY-MM")
    os.makedirs(args.download, exist_ok=True)
    urls = {
        "dbip-country-lite-%s.csv.gz" % args.month: DBIP_URL.format(month=args.month),
        "ne_110m_admin_0_countries.geojson": NE_URL,
        "zone.tab": TZ_ZONE_URL,
        "backward": TZ_BACKWARD_URL,
    }
    for name, url in urls.items():
        target = os.path.join(args.download, name)
        print("fetching %s" % url)
        with urllib.request.urlopen(url, timeout=120) as response, open(target, "wb") as out:
            out.write(response.read())
        print("  %s  %s" % (sha256(target), name))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build", action="store_true", help="convert the sources into the resources")
    mode.add_argument("--check", action="store_true", help="verify the committed resources")
    mode.add_argument("--download", metavar="DIR", help="fetch the sources for --month into DIR")
    parser.add_argument("--sources", metavar="DIR", help="directory holding the downloaded sources")
    parser.add_argument("--month", metavar="YYYY-MM", help="DB-IP data month to download")
    parser.add_argument("--resources", default=RESOURCES, help="GeoKit Resources directory")
    parser.add_argument("--fixtures", default=FIXTURES, help="GeoKitTests Fixtures directory")
    args = parser.parse_args()
    if args.download:
        do_download(args)
    elif args.build:
        if not args.sources:
            fail("--build needs --sources DIR")
        do_build(args)
    else:
        do_check(args)


if __name__ == "__main__":
    main()
