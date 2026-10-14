# dmgbuild settings for the Conduit installer DMG.
# Usage: dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... -D icon=... Conduit out.dmg
# ruff: noqa: F821  (`defines` is injected by dmgbuild)
import os

app = defines["app"]  # noqa: F821
background = defines["background"]  # noqa: F821
icon = defines["icon"]  # noqa: F821

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

background = background
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
icon_size = 128
text_size = 13
# Content area is 640x400; Finder adds no toolbar so only the title bar is extra.
window_rect = ((200, 120), (640, 432))
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (470, 190),
}
