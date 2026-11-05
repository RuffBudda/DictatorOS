-- Tile everything: no windows layered on top of others.
-- Omarchy floats a set of windows (installer/update terminals, btop, About,
-- imv, mpv, foot, Steam...). These rules load after Omarchy's defaults and
-- override them. File pickers and save dialogs stay floating on purpose.
-- After editing: hyprctl reload && hyprctl configerrors

o.window({ tag = "floating-window" }, { float = false })
o.window("org.omarchy.about", { float = false })
o.window("steam", { float = false })

-- Keep real dialogs floating (file chooser, save-as, portal prompts).
o.window("xdg-desktop-portal-gtk", { float = true })
o.window({
  class = "(sublime_text|DesktopEditors|org.gnome.Nautilus)",
  title = "^(Open.*Files?|Open [F|f]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to [open|save].*|[C|c]hoose.*)",
}, { float = true })
