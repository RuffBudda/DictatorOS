-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Windows that came from another screen (e.g. Chromium/WhatsApp at 100%) can
-- keep drawing at that screen's scale after a plug or unplug. A reload re-sends
-- every monitor's scale to every window. Omarchy's monitor-workspaces.lua puts
-- the workspaces back on their screens; this only fixes the scale.
for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
  hl.on(event, function() hl.exec_cmd("sleep 0.5; hyprctl reload") end)
end

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })

-- Per-screen settings from Display settings (nwg-displays): arrangement,
-- scale, rotation, resolution. Overrides the generic line above.
local displays = os.getenv("HOME") .. "/dotfiles/hypr/displays.lua"
local df = io.open(displays, "r")
if df then
  df:close()
  dofile(displays)
end

-- SUPER+P display mode override (written by ~/dotfiles/bin/display-mode,
-- lives in $XDG_RUNTIME_DIR so it resets on reboot).
local display_mode = (os.getenv("XDG_RUNTIME_DIR") or "") .. "/display-mode.lua"
local f = io.open(display_mode, "r")
if f then
  f:close()
  dofile(display_mode)
else
  -- No SUPER+P choice yet (or the screen was unplugged since, which clears it):
  -- duplicate the laptop panel on every connected external screen. A mirror
  -- owns no workspaces, so plugging and unplugging never moves any.
  -- Connector names come from DRM, e.g. /sys/class/drm/card1-HDMI-A-1 -> HDMI-A-1.
  local internal, externals = nil, {}
  local p = io.popen('for s in /sys/class/drm/card*-*/status; do [ "$(cat "$s")" = connected ] && basename "${s%/status}"; done 2>/dev/null')
  for conn in (p and p:read("a") or ""):gmatch("[^\n]+") do
    local name = conn:gsub("^card%d+%-", "")
    if name:match("^eDP%-") or name:match("^LVDS%-") or name:match("^DSI%-") then
      internal = internal or name
    elseif name:match("^[%w._-]+$") then
      table.insert(externals, name)
    end
  end
  if p then p:close() end
  if internal then
    for _, e in ipairs(externals) do
      hl.monitor({ output = e, mode = "preferred", position = "auto", scale = "auto", mirror = internal })
    end
  end
end
