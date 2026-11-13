-- Personal keybindings (managed in ~/dotfiles/hypr/bindings.lua).
-- Loaded after Omarchy's defaults. Rebinding a default key: hl.unbind() first.
-- See all bindings: omarchy menu keybindings --print
-- After editing: hyprctl reload && hyprctl configerrors

local bin = os.getenv("HOME") .. "/dotfiles/bin/"

-- ── Window movement ─────────────────────────────────────────────────────
-- Tiling only: no floating, maximize/fullscreen or minimize helpers.
-- SUPER + LEFT/RIGHT were "focus window left/right"; now they move the
-- window within the tiling layout; at the edge it goes to the next (RIGHT)
-- or previous (LEFT) screen, whether that screen is beside, above or below.
-- SUPER + UP/DOWN stack windows vertically: they move the window up/down, and
-- turn side-by-side windows into a top/bottom stack (this window on top for UP,
-- at the bottom for DOWN). A single window snaps to the top/bottom half.
-- With a single window on the workspace, SUPER + LEFT/RIGHT snaps it to the
-- left/right half instead. It stays tiled (no floating): the workspace just
-- gets a wide outer gap on the other side. Pressing the opposite arrow, or
-- opening another window there, returns to normal full-width tiling.
hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")

local half_snap = {}  -- workspace id -> { dir = "l"|"r", rule = <workspace rule> }

local function gap_px()
  local g = hl.get_config("general.gaps_out")
  if type(g) == "table" then return g.top or g[1] or 10 end
  return tonumber(g) or 10
end

local function clear_half_snap(ws_id)
  local s = half_snap[ws_id]
  if s then
    s.rule:set_enabled(false)
    half_snap[ws_id] = nil
  end
end

local function tiled_count(ws)
  local n = 0
  for _, w in ipairs(hl.get_workspace_windows(ws.id)) do
    if w.mapped and not w.floating then n = n + 1 end
  end
  return n
end

local function center_x(w)
  local at, size = w.at or {}, w.size or {}
  return (at.x or at[1] or 0) + (size.x or size[1] or 0) / 2
end

-- Move the window to the next (r) / previous (l) screen, wherever that
-- screen physically sits (above, below or beside). Screen order comes from
-- desktops.lua: laptop first, then the others.
local function move_to_other_screen(win, dir)
  local mons = (_G.dotfiles_desktops and _G.dotfiles_desktops.monitors()) or hl.get_monitors()
  if #mons < 2 then return false end
  local cur = 1
  for i, m in ipairs(mons) do
    if win.monitor and m.name == win.monitor.name then cur = i end
  end
  local step = dir == "r" and 1 or -1
  local target = mons[((cur - 1 + step) % #mons) + 1]
  if not target.active_workspace then return false end
  clear_half_snap(win.workspace.id)
  hl.dispatch(hl.dsp.window.move({ window = "address:" .. win.address, workspace = tostring(target.active_workspace.id) }))
  return true
end

local function center_y(w)
  local at, size = w.at or {}, w.size or {}
  return (at.y or at[2] or 0) + (size.y or size[2] or 0) / 2
end

-- Is there another tiled window on this workspace in that direction?
local function neighbour_in(win, dir)
  local cx, cy = center_x(win), center_y(win)
  for _, w in ipairs(hl.get_workspace_windows(win.workspace.id)) do
    if w.address ~= win.address and w.mapped and not w.floating then
      local wx, wy = center_x(w), center_y(w)
      if (dir == "l" and wx < cx - 1) or (dir == "r" and wx > cx + 1)
        or (dir == "u" and wy < cy - 1) or (dir == "d" and wy > cy + 1) then return true end
    end
  end
  return false
end

-- SUPER + UP/DOWN with several windows: move the window up/down; if it has
-- nothing above or below (windows side by side), stack them vertically with
-- this window on top (UP) or at the bottom (DOWN).
local function stack(win, dir)
  if neighbour_in(win, dir) then
    hl.dispatch(hl.dsp.window.move({ direction = dir }))
    return
  end
  if neighbour_in(win, dir == "u" and "d" or "u") then return end  -- already at that end of a stack
  hl.dispatch(hl.dsp.layout("togglesplit"))
  local t
  t = hl.timer(function()
    t:set_enabled(false)
    local w = hl.get_active_window()
    if w and neighbour_in(w, dir) then hl.dispatch(hl.dsp.layout("swapsplit")) end
  end, { timeout = 60, type = "oneshot" })
end

local function snap(dir)
  local win = hl.get_active_window()
  if not win or not win.workspace then return end
  local ws = win.workspace
  local vertical = dir == "u" or dir == "d"
  local other = ({ l = "r", r = "l", u = "d", d = "u" })[dir]

  if win.floating or tiled_count(ws) > 1 then
    clear_half_snap(ws.id)
    if vertical then
      stack(win, dir)
    elseif neighbour_in(win, dir) or not move_to_other_screen(win, dir) then
      hl.dispatch(hl.dsp.window.move({ direction = dir }))
    end
    return
  end

  local current = half_snap[ws.id]
  if current and current.dir == other then  -- opposite arrow: back to full width
    clear_half_snap(ws.id)
    return
  end
  if current and current.dir == dir then    -- same arrow again: other screen (left/right only)
    if vertical then return end
    clear_half_snap(ws.id)
    move_to_other_screen(win, dir)
    return
  end
  if current then clear_half_snap(ws.id) end  -- e.g. left half -> top half

  local m = win.monitor or hl.get_active_monitor()
  local rotated = m.transform % 2 == 1
  local width = (rotated and m.height or m.width) / m.scale
  local height = (rotated and m.width or m.height) / m.scale
  local g = gap_px()
  local span = vertical and height or width
  local half = math.floor((span - 3 * g) / 2)
  local far = math.floor(span - g - half)
  local gaps = ({
    l = { top = g, right = far, bottom = g, left = g },
    r = { top = g, right = g, bottom = g, left = far },
    u = { top = g, right = g, bottom = far, left = g },
    d = { top = far, right = g, bottom = g, left = g },
  })[dir]
  half_snap[ws.id] = { dir = dir, rule = hl.workspace_rule({ workspace = tostring(ws.id), gaps_out = gaps }) }
end

-- Clear before the new window is laid out, so it splits side by side like
-- normal Omarchy tiling. open_early may not know the workspace yet, so fall
-- back to the active one.
local function xy(v)
  if type(v) ~= "table" then return 0, 0 end
  return v.x or v[1] or 0, v.y or v[2] or 0
end

local function unsnap_for(win)
  local ws = (win and win.workspace) or hl.get_active_workspace()
  if not (ws and half_snap[ws.id]) then return end
  clear_half_snap(ws.id)
  -- The layout may already have split the narrow half-window top/bottom;
  -- flip it to side by side once the new window is placed.
  local t
  t = hl.timer(function()
    t:set_enabled(false)
    local tiled = {}
    for _, w in ipairs(hl.get_workspace_windows(ws.id)) do
      if w.mapped and not w.floating then table.insert(tiled, w) end
    end
    if #tiled == 2 then
      local ax = xy(tiled[1].at)
      local bx = xy(tiled[2].at)
      if ax == bx then hl.dispatch(hl.dsp.layout("togglesplit")) end
    end
  end, { timeout = 80, type = "oneshot" })
end
hl.on("window.open_early", unsnap_for)
hl.on("window.open", unsnap_for)

_G.dotfiles_snap = snap  -- for testing
_G.dotfiles_move_to_other_screen = function(addr, dir) local w = hl.get_window("address:" .. addr); if w then return move_to_other_screen(w, dir) end end
o.bind("SUPER + LEFT", "Snap / move window left", function() snap("l") end)
o.bind("SUPER + RIGHT", "Snap / move window right", function() snap("r") end)
o.bind("SUPER + UP", "Stack / move window up", function() snap("u") end)
o.bind("SUPER + DOWN", "Stack / move window down", function() snap("d") end)

-- ── Network Displays: cast to a wireless display ────────────────────────
o.bind("SUPER + N", "Network Displays (cast)", bin .. "cast")

-- ── Sticky notes (omarchy/plugins/abu.stickynotes) ──────────────────────
-- Omarchy 4.5 added SUPER+M = "Minimize window to the dock"; tiling only here,
-- so remove it and keep SUPER+M for sticky notes alone.
hl.unbind("SUPER + M")
o.bind("SUPER + M", "Sticky notes panel", "omarchy-shell stickynotes toggle")

-- ── Files (Windows: Win+E) ──────────────────────────────────────────────
-- Same as SUPER+SHIFT+F: flea (see the flea --default block below).
-- Was: { omarchy = "nautilus" }.
o.bind("SUPER + E", "File manager", { launch = "flea --gui" })

-- ── Task Manager (Windows: Ctrl+Shift+Esc) ──────────────────────────────
-- Mission Center: CPU, memory, disk, network, GPU and processes.
-- btop (terminal) is on SUPER+SHIFT+T (Omarchy 4.5 moved it from SUPER+CTRL+T).
o.bind("CTRL + SHIFT + ESCAPE", "Task Manager", { launch = "missioncenter" })

-- ── Top bar show/hide ───────────────────────────────────────────────────
-- The bar shows by default; SUPER+B hides it (windows move up) or shows it again.
o.bind("SUPER + B", "Show / hide top bar", "omarchy-toggle-bar")

-- ── Screenshots (Windows: Win+Shift+S snip) ─────────────────────────────
-- Was: Google Maps.
hl.unbind("SUPER + SHIFT + S")
o.bind("SUPER + SHIFT + S", "Screenshot region", "omarchy-capture-screenshot region")

-- ── Project / display mode (Windows: Win+P) ─────────────────────────────
-- Was: Pseudo window.
hl.unbind("SUPER + P")
o.bind("SUPER + P", "Display mode", bin .. "display-mode")

-- ── SUPER + T: disabled ─────────────────────────────────────────────────
-- Was: Toggle window floating/tiling.
hl.unbind("SUPER + T")

-- ── ALT + TAB (Windows-style switcher panel) ────────────────────────────
-- Was: cycle windows on the current workspace only.
-- Now: panel of the windows on the current workspace, most recent
-- first. Hold ALT, tap TAB / SHIFT+TAB (or arrows) to pick, release ALT to
-- switch. ALT+ESC cancels. Panel: ~/dotfiles/omarchy/plugins/abu.alttab
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")

local function alttab(cmd)
  hl.exec_cmd("omarchy-shell -q alttab " .. cmd)
end

-- Is ALT physically held? Try keysym names and both keycode conventions
-- (xkb 64/108, evdev 56/100). Results are logged once per switch to
-- $XDG_RUNTIME_DIR/alttab.log for troubleshooting.
local alt_probes = { "Alt_L", "Alt_R", 64, 108, 56, 100 }
local function alt_down(log)
  local down, seen = false, {}
  for _, k in ipairs(alt_probes) do
    local ok, v = pcall(hl.is_key_down, k)
    if ok and v then down = true end
    table.insert(seen, tostring(k) .. "=" .. tostring(ok and v))
  end
  if log then
    hl.exec_cmd("sh -c 'echo \"$(date +%T) " .. table.concat(seen, " ") .. "\" >> \"$XDG_RUNTIME_DIR/alttab.log\"'")
  end
  return down
end

local alttab_timer = nil
local alttab_ticks = 0

local function alttab_done(cmd)
  if alttab_timer then alttab_timer:set_enabled(false) end
  if hl.get_current_submap() == "alttab" then
    alttab(cmd)
    hl.dispatch(hl.dsp.submap("reset"))
  end
end

-- Fail-safe: never stay in the alttab submap (it disables all other
-- shortcuts). Commit as soon as ALT is up, and always give up after 8s.
local function alttab_watch()
  alttab_ticks = 0
  if alttab_timer then alttab_timer:set_enabled(false) end
  alttab_timer = hl.timer(function()
    alttab_ticks = alttab_ticks + 1
    if hl.get_current_submap() ~= "alttab" then
      alttab_timer:set_enabled(false)
    elseif alttab_ticks >= 3 and not alt_down(alttab_ticks == 3) then
      alttab_done("commit")
    elseif alttab_ticks > 320 then
      alttab_done("cancel")
    end
  end, { timeout = 25, type = "repeat" })
end

local function alttab_start(dir)
  alttab("open " .. dir)
  hl.dispatch(hl.dsp.submap("alttab"))
  alttab_watch()
end

_G.dotfiles_alttab_start = alttab_start  -- for testing: hyprctl dispatch "(function() dotfiles_alttab_start(\"next\") end)"
o.bind("ALT + TAB", "Window switcher", function() alttab_start("next") end)
o.bind("ALT + SHIFT + TAB", "Window switcher (reverse)", function() alttab_start("prev") end)

hl.define_submap("alttab", function()
  hl.bind("ALT + TAB", function() alttab("next") end, { repeating = true })
  hl.bind("ALT + SHIFT + TAB", function() alttab("prev") end, { repeating = true })
  hl.bind("ALT + RIGHT", function() alttab("next") end)
  hl.bind("ALT + LEFT", function() alttab("prev") end)
  hl.bind("ALT + Alt_L", function() alttab_done("commit") end, { release = true })
  hl.bind("Alt_L", function() alttab_done("commit") end, { release = true })
  hl.bind("ALT + RETURN", function() alttab_done("commit") end)
  hl.bind("ALT + ESCAPE", function() alttab_done("cancel") end)
  hl.bind("ESCAPE", function() alttab_done("cancel") end)
end)

-- ── Lock screen (Windows: Win+L) ────────────────────────────────────────
-- Was: Toggle workspace layout.
hl.unbind("SUPER + L")
o.bind("SUPER + L", "Lock screen", "omarchy-system-lock")

-- ── Calculator (Fn+F12 on keyboards where it emits XF86Calculator) ──────
o.bind("XF86Calculator", "Calculator", "omacalc")

-- flea --default: begin. Written by `flea --default`; `flea --default off` removes the block whole.
hl.unbind("SUPER + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = 'flea --gui' })
hl.unbind("SUPER + ALT + SHIFT + F")
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", { launch = 'flea --gui "$(omarchy-cmd-terminal-cwd)"' })
-- flea --default: end.

-- flea --picker: begin. Written by `flea --picker`; `flea --picker off` removes the block whole.
o.window("com.thisisgm.flea.picker", { tag = "+floating-window" })
-- flea --picker: end.
