# gnome-network-displays (patched)

AUR package 0.99.0 + `fix-autofree-crash.patch`: the app aborted every time it
was closed (a `g_autofree` variable declared inside a `switch` case without
braces got freed uninitialised when the PulseAudio context disconnected).

Rebuild/reinstall:

    cd ~/dotfiles/packages/gnome-network-displays
    makepkg -sfi --nocheck

If `yay` later updates the package from the AUR and the crash comes back,
rebuild from here (bump pkgver if the AUR version moved and the patch still applies).
