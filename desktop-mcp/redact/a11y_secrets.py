#!/usr/bin/env python3
"""Print the on-screen password fields that apps expose over AT-SPI, as JSON.

Output: [{"pid": int, "app": str, "window": str, "x": int, "y": int, "width": int, "height": int}]
Coordinates are relative to the field's top-level window (Wayland apps don't know their global position).
Only reads the accessibility tree; never reads field contents.
"""
import json
import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

MAX_NODES = 20000


def toplevel(obj):
    top = obj
    try:
        while True:
            parent = top.get_parent()
            if parent is None or parent.get_role() == Atspi.Role.APPLICATION:
                return top
            top = parent
    except Exception:
        return top


def main():
    out = []
    desk = Atspi.get_desktop(0)
    rule = Atspi.MatchRule.new(
        Atspi.StateSet.new([Atspi.StateType.SHOWING]), Atspi.CollectionMatchType.ALL,
        None, Atspi.CollectionMatchType.NONE,
        [Atspi.Role.PASSWORD_TEXT], Atspi.CollectionMatchType.ANY,
        None, Atspi.CollectionMatchType.NONE, False,
    )
    for i in range(desk.get_child_count()):
        app = desk.get_child_at_index(i)
        if app is None:
            continue
        try:
            pid = app.get_process_id()
            name = app.get_name() or ""
        except Exception:
            continue
        found = []
        # Fast path: server-side collection match. Some toolkits return nothing here, so also walk.
        try:
            col = app.get_collection_iface()
            if col is not None:
                found = list(col.get_matches(rule, Atspi.CollectionSortOrder.CANONICAL, 100, True))
        except Exception:
            found = []
        if not found:
            stack, seen = [app], 0
            while stack and seen < MAX_NODES:
                node = stack.pop()
                seen += 1
                try:
                    if node.get_role() == Atspi.Role.PASSWORD_TEXT and node.get_state_set().contains(Atspi.StateType.SHOWING):
                        found.append(node)
                    n = node.get_child_count()
                except Exception:
                    continue
                for j in range(n):
                    try:
                        ch = node.get_child_at_index(j)
                    except Exception:
                        ch = None
                    if ch is not None:
                        stack.append(ch)
        for node in found:
            try:
                comp = node.get_component_iface()
                e = comp.get_extents(Atspi.CoordType.WINDOW)
                if e.width <= 0 or e.height <= 0:
                    continue
                win = toplevel(node)
                out.append({"pid": pid, "app": name, "window": win.get_name() or "",
                            "x": e.x, "y": e.y, "width": e.width, "height": e.height})
            except Exception:
                continue
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
