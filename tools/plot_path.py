#!/usr/bin/env python3
"""Draw a character's path in world coordinates as a PNG.

    python3 tools/plot_path.py data/eric-era.lua [--char Name-Realm] [--out path.png] [--zone "Elwynn Forest"]

North is up, east is right. Zone boxes come from the map bounds the addon
recorded, so the picture needs no game art. Path color is the movement mode;
markers are deaths, level-ups, hearths, taxis and discoveries.
"""
import argparse
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

sys.path.insert(0, str(Path(__file__).parent))
from load import load_files, MODE_NAMES

MODE_COLORS = {"foot": "#2d7dd2", "mount": "#8e44ad", "taxi": "#f39c12", "swim": "#16a085",
               "ghost": "#95a5a6", "form": "#27ae60", "boat": "#d35400"}
EVENT_STYLE = {
    "DEATH": dict(marker="X", color="#c0392b", s=90, label="death", zorder=6),
    "LEVEL": dict(marker="*", color="#f1c40f", s=160, edgecolors="#7f6000", label="level up", zorder=6),
    "HEARTH": dict(marker="h", color="#1abc9c", s=80, edgecolors="black", label="hearth", zorder=5),
    "DISCOVER": dict(marker="o", color="white", s=30, edgecolors="#555", label="discovery", zorder=4),
    "QUEST_DONE": dict(marker="s", color="#e67e22", s=40, edgecolors="#7a3e00", label="quest done", zorder=4),
}


def world_xy(east, north):
    # The addon's "east" axis is WoW's west-positive axis; flip it so east is right
    return -east, north


def event_world(e, maps):
    m = maps.get(int(e["m"])) if e.get("m") == e.get("m") and e.get("m") is not None else None
    if not m or m.get("l") is None or e.get("x") != e.get("x"):
        return None
    east = m["l"] + (m["r"] - m["l"]) * (e["x"] / 1000.0)
    north = m["t"] + (m["b"] - m["t"]) * (e["y"] / 1000.0)
    return world_xy(east, north)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--char", help="Name-Realm (default: first character found)")
    ap.add_argument("--out", help="PNG path (default: next to the first file)")
    ap.add_argument("--zone", help="Limit the picture to one zone map name")
    ap.add_argument("--title")
    args = ap.parse_args()

    j = load_files(args.files)
    char = args.char or next(iter(j.chars))
    s = j.samples[(j.samples.char == char) & (~j.samples.hidden) & j.samples.east.notna()].copy()
    ev = j.events[j.events.char == char].copy()
    if args.zone:
        zone_ids = [k for k, v in j.maps.items() if v.get("name") == args.zone]
        s = s[s["map"].isin(zone_ids)]
        ev = ev[ev["m"].isin(zone_ids)]
    if s.empty:
        sys.exit("no samples to draw")

    s["px"], s["py"] = world_xy(s.east, s.north)

    fig, ax = plt.subplots(figsize=(14, 12), dpi=130)
    ax.set_facecolor("#0f1a12")
    fig.patch.set_facecolor("#0f1a12")

    # Zone boxes from recorded bounds (skip continent-sized maps unless they are all we have)
    used = set(s["map"].dropna().astype(int))
    for mid in used:
        m = j.maps.get(mid)
        if not m or m.get("l") is None:
            continue
        if m.get("kind") in (0, 1, 2) and len(used) > 1:   # cosmic, world, continent
            continue
        x0, y0 = world_xy(m["l"], m["t"])
        x1, y1 = world_xy(m["r"], m["b"])
        ax.add_patch(plt.Rectangle((min(x0, x1), min(y0, y1)), abs(x1 - x0), abs(y1 - y0),
                                   fill=False, edgecolor="#3b5a40", linewidth=1, linestyle="--", zorder=1))
        ax.text(min(x0, x1) + 40, max(y0, y1) - 60, m.get("name", str(mid)), color="#6f9a75", fontsize=9, zorder=2)

    # Path: one line per run of consecutive samples; break on session change, teleport, or a hidden gap
    s = s.sort_values(["session", "order"])
    prev = None
    for _, row in s.iterrows():
        if prev is not None and prev.session == row.session and not row.teleport and row.order == prev.order + 1:
            color = MODE_COLORS.get(row.mode_name, "#ffffff")
            width = 2.2 if row.mode_name == "taxi" else 1.4
            ax.plot([prev.px, row.px], [prev.py, row.py], color=color, linewidth=width, alpha=0.9, zorder=3,
                    solid_capstyle="round")
        prev = row

    # Events
    seen_labels = set()
    for _, e in ev.iterrows():
        style = EVENT_STYLE.get(e.get("k"))
        if not style:
            continue
        xy = event_world(e, j.maps)
        if not xy:
            continue
        st = dict(style)
        label = st.pop("label")
        if label in seen_labels:
            label = None
        else:
            seen_labels.add(label)
        ax.scatter([xy[0]], [xy[1]], label=label, **st)
        if e.get("k") == "LEVEL":
            ax.annotate(f"lvl {int(e['v'])}", xy, xytext=(6, 6), textcoords="offset points", color="#f1c40f", fontsize=8)
        if e.get("k") == "DEATH" and isinstance(e.get("by"), str):
            ax.annotate(e["by"], xy, xytext=(6, -10), textcoords="offset points", color="#e57373", fontsize=7)

    # Legend: modes present plus event markers
    handles = [Line2D([0], [0], color=MODE_COLORS[m], lw=2, label=m) for m in s.mode_name.dropna().unique() if m in MODE_COLORS]
    h2, l2 = ax.get_legend_handles_labels()
    ax.legend(handles=handles + h2, loc="lower right", facecolor="#1b2a1e", edgecolor="#3b5a40", labelcolor="white", fontsize=8)

    meta = j.chars[char]["meta"]
    minutes = j.sessions[j.sessions.char == char]["minutes"].sum()
    ax.set_title(args.title or f"{meta.get('name')} · {meta.get('race')} {str(meta.get('class')).title()} · "
                 f"{len(j.sessions[j.sessions.char == char])} sessions, {minutes:.0f} min · {len(s)} points",
                 color="white", fontsize=12)
    ax.set_aspect("equal")
    ax.tick_params(colors="#6f9a75", labelsize=7)
    for sp in ax.spines.values():
        sp.set_color("#3b5a40")
    ax.set_xlabel("east (yards)", color="#6f9a75")
    ax.set_ylabel("north (yards)", color="#6f9a75")
    ax.margins(0.04)
    fig.tight_layout()

    out = args.out or str(Path(args.files[0]).with_suffix("")) + ("-" + args.zone.replace(" ", "_").lower() if args.zone else "") + "-path.png"
    fig.savefig(out, facecolor=fig.get_facecolor())
    print("wrote", out)


if __name__ == "__main__":
    main()
