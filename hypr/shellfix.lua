-- Put ~/dotfiles/omarchy-overrides/bin ahead of Omarchy's bin dir so that
-- Omarchy's autostart and `omarchy restart shell` run our omarchy-launch-shell
-- wrapper, which starts the bar without the GTK3 Qt theme (it crashed on
-- HDMI-switcher hotplugs). Runs after default.hypr.envs, which puts Omarchy's
-- bin first; we remove our own entry first so reloads don't add it twice.
local override = os.getenv("HOME") .. "/dotfiles/omarchy-overrides/bin"
local kept = { override }
for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
  if entry ~= override then table.insert(kept, entry) end
end
hl.env("PATH", table.concat(kept, ":"))
