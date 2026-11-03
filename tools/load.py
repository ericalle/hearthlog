#!/usr/bin/env python3
"""Load Hearthlog SavedVariables files into pandas.

    from load import load_files
    j = load_files(["data/eric.lua", "data/reidoo.lua"])
    j.samples   # one row per path point
    j.events    # one row per event
    j.sessions  # one row per session
    j.chars     # {key: {"meta":..., "counters":..., "tallies":...}}
    j.maps      # {mapID: {"name":..., "l":..., "t":..., "r":..., "b":..., "inst":...}}

Run as a script for a summary:  python3 tools/load.py path/to/Hearthlog.lua [...]

The file is executed as Lua (it is a Lua table literal), so no hand parser.
Positions are packed strings; see Hearthlog/Track.lua for the format.
World coordinates: the addon stores each map's world bounds once; a sample's
map position (0..1 both axes, stored x1000) converts with
    east  = l + (r - l) * x
    north = t + (b - t) * y
"""
import sys
from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd
from lupa import lua51 as lupa

MODE_NAMES = {"f": "foot", "m": "mount", "t": "taxi", "s": "swim", "g": "ghost", "v": "form", "b": "boat"}


def _lua_to_py(obj):
    """Recursively convert a lupa table to dict/list."""
    if not hasattr(obj, "items"):
        return obj
    keys = list(obj.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [_lua_to_py(obj[k]) for k in range(1, len(keys) + 1)]
    return {k: _lua_to_py(v) for k, v in obj.items()}


def _lzw_decode(data: bytes) -> bytes:
    """Inverse of the addon's LZW: 16-bit big-endian codes, dictionary reset at 65535."""
    def fresh():
        return {i: bytes([i]) for i in range(256)}
    dict_, size = fresh(), 256
    out = bytearray()
    w = b""
    for i in range(0, len(data) - 1, 2):
        code = data[i] * 256 + data[i + 1]
        if code in dict_:
            entry = dict_[code]
        elif code == size and w:
            entry = w + w[:1]
        else:
            raise ValueError("bad LZW code %d at byte %d" % (code, i))
        out += entry
        if w:
            if size < 65535:
                dict_[size] = w + entry[:1]
                size += 1
            else:
                dict_, size = fresh(), 256
        w = entry
    return bytes(out)


def decode_export(text: str):
    """Turn an /hl export string (HL2:...) into a HearthlogDB-shaped dict."""
    import base64
    text = text.strip()
    if text.startswith("HL2:"):
        raw = _lzw_decode(base64.b64decode(text[4:])).decode("utf-8")
    elif text.startswith("HL1"):
        raw = text[3:].lstrip(": \r\n")
    else:
        raise ValueError("not a Hearthlog export string")
    rt = lupa.LuaRuntime()
    obj = _lua_to_py(rt.execute("return " + raw))
    return {"maps": obj.get("maps") or {}, "chars": {obj.get("key") or "export": obj.get("char") or {}}}


def read_lua(path):
    text = Path(path).read_text(encoding="utf-8")
    if text.lstrip().startswith(("HL2:", "HL1")):
        return decode_export(text)
    rt = lupa.LuaRuntime()
    rt.execute(text)
    return _lua_to_py(rt.globals().HearthlogDB)


@dataclass
class Journey:
    samples: pd.DataFrame
    events: pd.DataFrame
    sessions: pd.DataFrame
    chars: dict = field(default_factory=dict)
    maps: dict = field(default_factory=dict)


def _unpack_samples(char_key, session_index, session, chunks, maps):
    """Expand one session's packed chunks into sample rows."""
    rows = []
    t = session.get("t0")
    hidden = False
    teleport_next = False
    order = 0
    for chunk in chunks:
        for s in chunk.split(";"):
            if not s:
                continue
            head = s.split(",")[0]
            if head == "P":
                t = (t or 0) + int(s.split(",")[1])
                continue
            if head == "X":
                hidden = True
                rows.append(dict(char=char_key, session=session_index, order=order, t=t, hidden=True,
                                 map=None, x=None, y=None, mode=None, teleport=False, east=None, north=None))
                order += 1
                continue
            if head == "T":
                teleport_next = True
                continue
            if head == "M":
                continue
            parts = s.split(",")
            if len(parts) != 5:
                continue
            dt, map_id, x, y, mode = int(parts[0]), int(parts[1]), int(parts[2]) / 1000.0, int(parts[3]) / 1000.0, parts[4]
            t = (t or 0) + dt
            east = north = None
            m = maps.get(map_id)
            if m and m.get("l") is not None:
                east = m["l"] + (m["r"] - m["l"]) * x
                north = m["t"] + (m["b"] - m["t"]) * y
            rows.append(dict(char=char_key, session=session_index, order=order, t=t, hidden=False,
                             map=map_id, x=x, y=y, mode=mode, teleport=teleport_next, east=east, north=north))
            teleport_next = False
            hidden = False
            order += 1
    return rows


def load_db(db, source=""):
    maps = {int(k): v for k, v in (db.get("maps") or {}).items()}
    sample_rows, event_rows, session_rows, chars = [], [], [], {}
    for key, char in (db.get("chars") or {}).items():
        chars[key] = {"meta": char.get("meta", {}), "counters": char.get("counters", {}),
                      "tallies": char.get("tallies", {}), "source": source}
        sessions = char.get("sessions") or []
        pos = char.get("pos") or {}
        if isinstance(pos, list):
            pos = {i + 1: v for i, v in enumerate(pos)}
        for i, sess in enumerate(sessions, start=1):
            row = dict(char=key, session=i, **{k: v for k, v in sess.items()})
            session_rows.append(row)
            chunks = pos.get(i) or []
            sample_rows.extend(_unpack_samples(key, i, sess, chunks, maps))
        for e in char.get("events") or []:
            row = {"char": key}
            for k, v in e.items():
                if isinstance(v, list):
                    row[k] = ",".join(map(str, v))
                elif isinstance(v, dict):
                    row[k] = str(v)
                else:
                    row[k] = v
            event_rows.append(row)

    samples = pd.DataFrame(sample_rows)
    if not samples.empty:
        samples["time"] = pd.to_datetime(samples["t"], unit="s", utc=True)
        samples["mode_name"] = samples["mode"].map(MODE_NAMES)
        samples["zone"] = samples["map"].map(lambda m: maps.get(m, {}).get("name") if pd.notna(m) else None)
    events = pd.DataFrame(event_rows)
    if not events.empty:
        events["time"] = pd.to_datetime(events["t"], unit="s", utc=True)
        events = events.sort_values(["char", "t"]).reset_index(drop=True)
    sessions = pd.DataFrame(session_rows)
    if not sessions.empty:
        for col in ("t0", "t1"):
            if col in sessions:
                sessions[col + "_time"] = pd.to_datetime(sessions[col], unit="s", utc=True)
        sessions["minutes"] = (sessions.get("t1") - sessions.get("t0")) / 60
    return Journey(samples, events, sessions, chars, maps)


def load_files(paths):
    parts = [load_db(read_lua(p), source=str(p)) for p in paths]
    maps = {}
    chars = {}
    for p in parts:
        maps.update(p.maps)
        chars.update(p.chars)
    cat = lambda name: pd.concat([getattr(p, name) for p in parts if not getattr(p, name).empty], ignore_index=True) \
        if any(not getattr(p, name).empty for p in parts) else pd.DataFrame()
    return Journey(cat("samples"), cat("events"), cat("sessions"), chars, maps)


def summary(j):
    out = []
    for key, c in j.chars.items():
        m, cnt = c["meta"], c["counters"]
        out.append(f"{key}: {m.get('race')} {m.get('class')} on {m.get('client')}, "
                   f"{int(cnt.get('kills', 0))} kills, {int(cnt.get('deaths', 0))} deaths, "
                   f"{int(cnt.get('questsDone', 0))} quests, {int(cnt.get('jumps', 0))} jumps")
    if not j.sessions.empty:
        out.append(f"sessions: {len(j.sessions)}, {j.sessions['minutes'].sum():.0f} minutes")
    if not j.samples.empty:
        s = j.samples[~j.samples.hidden]
        out.append(f"samples: {len(s)} ({s.east.notna().sum()} with world coords), modes: {s.mode_name.value_counts().to_dict()}")
        out.append("zones: " + ", ".join(f"{z} ({n})" for z, n in s.zone.value_counts().items()))
    if not j.events.empty:
        out.append("events: " + ", ".join(f"{k} {n}" for k, n in j.events.k.value_counts().items()))
    return "\n".join(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    print(summary(load_files(sys.argv[1:])))
