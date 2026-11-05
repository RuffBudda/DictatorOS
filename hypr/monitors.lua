-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

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
end
