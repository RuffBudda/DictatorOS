-- Windows-style virtual desktops across monitors.
--
-- Hyprland gives every monitor its own workspace. To make an extended
-- monitor part of the *same* desktop, each desktop N (1-10) is a set of
-- workspaces, one per monitor:
--   laptop screen    -> workspace N
--   2nd monitor      -> workspace N + 10
--   3rd monitor      -> workspace N + 20
-- Switching desktops switches every screen together.
--
-- SUPER + 1..0             switch desktop (all screens)
-- SUPER + SHIFT + 1..0     move window to desktop N (same screen) and follow
-- SUPER + SHIFT + ALT + 1..0  ... without following
-- SUPER + TAB / SHIFT+TAB  next / previous desktop that has windows
-- SUPER + SHIFT + N        move window to the first empty desktop
-- After editing: hyprctl reload && hyprctl configerrors

local D = {}
local rules = {}

-- Monitors in desktop order: laptop panel first, then left-to-right.
function D.monitors()
  local mons = {}
  for _, m in ipairs(hl.get_monitors()) do table.insert(mons, m) end
  -- Lua patterns have no "|", so test each laptop-panel prefix separately.
  local function internal(name)
    return name:match("^eDP%-") or name:match("^LVDS%-") or name:match("^DSI%-")
  end
  table.sort(mons, function(a, b)
    local ai = internal(a.name) and 0 or 1
    local bi = internal(b.name) and 0 or 1
    if ai ~= bi then return ai < bi end
    return (a.x or 0) < (b.x or 0)
  end)
  return mons
end

local function index_of(mon_name)
  for i, m in ipairs(D.monitors()) do
    if m.name == mon_name then return i end
  end
  return 1
end

local function ws_for(desktop, mon_index)
  return desktop + 10 * (mon_index - 1)
end

local function desktop_of(ws_id)
  return ((ws_id - 1) % 10) + 1
end

-- Pin each monitor's workspace range to it, so workspace 11 always opens on
-- the second screen, etc. Rebuilt when monitors are plugged/unplugged.
function D.bind_rules()
  for _, r in ipairs(rules) do r:set_enabled(false) end
  rules = {}
  for i, m in ipairs(D.monitors()) do
    for n = 1, 10 do
      table.insert(rules, hl.workspace_rule({ workspace = tostring(ws_for(n, i)), monitor = m.name }))
    end
  end
end

function D.current()
  local ws = hl.get_active_workspace()
  return ws and ws.id > 0 and desktop_of(ws.id) or 1
end

function D.go(desktop)
  local active = hl.get_active_monitor()
  local mons = D.monitors()
  -- Focusing each monitor in turn would warp the mouse to its centre, so
  -- turn warping off while switching and restore it afterwards.
  local warps_off = hl.get_config("cursor.no_warps")
  hl.config({ cursor = { no_warps = true } })
  for i, m in ipairs(mons) do
    hl.dispatch(hl.dsp.focus({ monitor = m.name }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(ws_for(desktop, i)) }))
  end
  if active then hl.dispatch(hl.dsp.focus({ monitor = active.name })) end
  hl.config({ cursor = { no_warps = warps_off and true or false } })
end

function D.move_window(desktop, follow)
  local win = hl.get_active_window()
  if not win then return end
  local i = index_of(win.monitor and win.monitor.name or "")
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws_for(desktop, i)), follow = false }))
  if follow then D.go(desktop) end
end

-- Desktops that currently have windows on any screen.
local function occupied()
  local set, list = {}, {}
  for _, w in ipairs(hl.get_windows()) do
    if w.mapped and w.workspace and w.workspace.id > 0 then set[desktop_of(w.workspace.id)] = true end
  end
  for n = 1, 10 do if set[n] then table.insert(list, n) end end
  return list, set
end

function D.cycle(step)
  local cur = D.current()
  local list = occupied()
  local seen = false
  for _, n in ipairs(list) do if n == cur then seen = true end end
  if not seen then table.insert(list, cur); table.sort(list) end
  if #list < 2 then return end
  for idx, n in ipairs(list) do
    if n == cur then
      D.go(list[((idx - 1 + step) % #list) + 1])
      return
    end
  end
end

function D.move_to_empty()
  local _, set = occupied()
  for n = 1, 10 do
    if not set[n] then D.move_window(n, true); return end
  end
end

-- Keep whatever is on screen visible when this is first loaded: if a
-- secondary monitor shows a workspace outside its range, move those windows
-- onto that monitor's workspace for the current desktop.
function D.adopt()
  local cur = D.current()
  for i, m in ipairs(D.monitors()) do
    if i > 1 and m.active_workspace and m.active_workspace.id > 0 then
      local id = m.active_workspace.id
      if id < ws_for(1, i) or id > ws_for(10, i) then
        local target = tostring(ws_for(cur, i))
        for _, w in ipairs(hl.get_workspace_windows(id)) do
          hl.dispatch(hl.dsp.window.move({ window = "address:" .. w.address, workspace = target, follow = false }))
        end
      end
    end
  end
end

-- When a monitor is unplugged, Hyprland parks its workspaces (e.g. 11, 12)
-- on the remaining screens where nothing shows them. Merge their windows
-- into the same desktop on the screen that now owns that slot instead.
function D.merge_orphans()
  local count = #D.monitors()
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id > 10 * count then
      local d = desktop_of(ws.id)
      local target = tostring(ws_for(d, 1))
      for _, w in ipairs(hl.get_workspace_windows(ws.id)) do
        hl.dispatch(hl.dsp.window.move({ window = "address:" .. w.address, workspace = target, follow = false }))
      end
    end
  end
end

-- When a monitor is plugged in, Hyprland may hand it existing workspaces
-- (e.g. 1-3). Send every workspace back to the screen it belongs to:
-- 1-10 laptop, 11-20 second screen, 21-30 third.
function D.home_workspaces()
  local mons = D.monitors()
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id > 0 then
      local target = mons[math.floor((ws.id - 1) / 10) + 1]
      if target and ws.monitor and ws.monitor.name ~= target.name then
        hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(ws.id), monitor = target.name }))
      end
    end
  end
end

D.bind_rules()
hl.on("monitor.added", function()
  D.bind_rules()
  local t
  t = hl.timer(function()
    t:set_enabled(false)
    local cur = D.current()
    D.home_workspaces()
    D.go(cur)
    hl.exec_cmd("sleep 0.5; hyprctl reload")  -- re-send scales to moved windows
  end, { timeout = 400, type = "oneshot" })
end)
hl.on("monitor.removed", function()
  D.bind_rules()
  local t
  t = hl.timer(function()
    t:set_enabled(false)
    D.merge_orphans()
    -- Windows that came from the unplugged screen (e.g. Chromium/WhatsApp at
    -- 100%) can keep drawing at that screen's scale. A config reload re-sends
    -- every monitor's scale to every window so they re-render for the laptop.
    hl.exec_cmd("sleep 0.5; hyprctl reload")
  end, { timeout = 300, type = "oneshot" })
end)

-- ── Bindings (replace Omarchy's per-monitor workspace keys) ─────────────
for n = 1, 10 do
  local key = "code:" .. tostring(n + 9)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + " .. key, "Switch to desktop " .. n, function() D.go(n) end)
  o.bind("SUPER + SHIFT + " .. key, "Move window to desktop " .. n, function() D.move_window(n, true) end)
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to desktop " .. n, function() D.move_window(n, false) end)
end

hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
hl.unbind("SUPER + mouse_down")
hl.unbind("SUPER + mouse_up")
o.bind("SUPER + TAB", "Next desktop", function() D.cycle(1) end)
o.bind("SUPER + SHIFT + TAB", "Previous desktop", function() D.cycle(-1) end)
o.bind("SUPER + mouse_down", "Next desktop", function() D.cycle(1) end)
o.bind("SUPER + mouse_up", "Previous desktop", function() D.cycle(-1) end)

hl.unbind("SUPER + SHIFT + N")
o.bind("SUPER + SHIFT + N", "Move window to empty desktop", function() D.move_to_empty() end)

-- ── Show desktop (Windows: Win+D) ──────────────────────────────────────
-- Switches every screen to its own empty "desktop-N" workspace, so all
-- windows are out of sight (nothing is minimized or moved). Press again to
-- go back to the desktop you were on. Switching desktops yourself in the
-- meantime just forgets the saved one.
local desk_saved = nil

local function on_desktop_view()
  local ws = hl.get_active_workspace()
  return ws and type(ws.name) == "string" and ws.name:match("^desktop%-") ~= nil
end

function D.show_desktop()
  -- Decide from where we are, not from remembered state: on the empty
  -- desktop view -> bring windows back; anywhere else -> hide them.
  if on_desktop_view() then
    local d = desk_saved or 1
    desk_saved = nil
    D.go(d)
    return
  end
  desk_saved = D.current()
  local active = hl.get_active_monitor()
  local warps_off = hl.get_config("cursor.no_warps")
  hl.config({ cursor = { no_warps = true } })
  for i, m in ipairs(D.monitors()) do
    hl.dispatch(hl.dsp.focus({ monitor = m.name }))
    hl.dispatch(hl.dsp.focus({ workspace = "name:desktop-" .. i }))
  end
  if active then hl.dispatch(hl.dsp.focus({ monitor = active.name })) end
  hl.config({ cursor = { no_warps = warps_off and true or false } })
end

hl.unbind("SUPER + D")
o.bind("SUPER + D", "Show desktop / bring windows back", function() D.show_desktop() end)

_G.dotfiles_desktops = D  -- for testing from hyprctl
