-- ~/dotfiles/hypr/contain.lua
-- Keep new windows on the workspace of whatever launched them.
--
-- Hyprland opens every new window on the workspace you're looking at. So when
-- Claude (in a terminal on workspace 1) opens an image viewer or a browser
-- while you're on workspace 2, the window lands on 2. Here it goes to 1.
--
-- How: every terminal / app launch gets its own systemd scope, and everything
-- started inside it stays in that cgroup, even after detaching (setsid, `&`,
-- a shell that has already exited). A new window whose scope already has a
-- window on one workspace is moved there, without following it.
--
-- Left alone:
--  * apps from the launcher or a keybinding (their own scope, or Hyprland's);
--  * a process opening another window of its own (new Chromium / terminal
--    window), so new terminal windows still open where you are;
--  * a scope whose windows sit on more than one workspace (ambiguous);
--  * special workspaces (scratchpads, the quake console).

local function cgroup(pid)
  local f = io.open("/proc/" .. pid .. "/cgroup")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line and line:match("^0::(.+)$")
end

local own = cgroup("self") -- Hyprland's own (keybinding exec_cmd launches)

local function contain(win)
  if not (win and win.pid and win.pid > 0 and win.workspace) then return end
  if win.workspace.id <= 0 then return end
  local cg = cgroup(win.pid)
  if not cg or cg == own or not cg:match("%.scope$") then return end

  local target
  local seen = {}
  for _, w in ipairs(hl.get_windows()) do
    if w.address ~= win.address and w.mapped and w.workspace and w.workspace.id > 0 then
      if w.pid == win.pid then return end
      if seen[w.pid] == nil then seen[w.pid] = (cgroup(w.pid) == cg) end
      if seen[w.pid] then
        if target and target ~= w.workspace.id then return end
        target = w.workspace.id
      end
    end
  end

  if target and target ~= win.workspace.id then
    hl.dispatch(hl.dsp.window.move({
      window = "address:" .. win.address, workspace = tostring(target), follow = false,
    }))
  end
end

hl.on("window.open", contain)
