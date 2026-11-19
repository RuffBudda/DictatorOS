# gnome-network-displays (patched)

This is the AUR package 0.99.0 with `fix-autofree-crash.patch`. Without the patch, the app
stops with an abort each time that you close it.

The cause: a `g_autofree` variable is declared in a `switch` case without braces. When the
PulseAudio context disconnects, the app frees this variable before it has a value.

To build and install the package again, run these commands:

    cd ~/dotfiles/packages/gnome-network-displays
    makepkg -sfi --nocheck

If `yay` updates the package from the AUR later, the crash can come back. If this occurs,
build the package again from this directory. If the AUR version is different and the patch
still applies, increase `pkgver` first.
