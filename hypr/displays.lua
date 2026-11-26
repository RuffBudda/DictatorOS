-- Per-screen layout. Written by the bar's monitor panel (bin/monitor-layout).
-- External screens are matched by description, so each monitor keeps its own
-- mode; screens not plugged in keep their saved rules.

hl.monitor({
    output = "eDP-2",
    mode = "2560x1600@165.00",
    position = "0x80",
    scale = 1.6,
    transform = 0
})
hl.monitor({
    output = "desc:LG Electronics LG ULTRAWIDE 0x0001EE91",
    mode = "2560x1080@74.99",
    position = "1600x0",
    scale = 1,
    transform = 0
})
