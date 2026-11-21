#!/usr/bin/env python3
import os
import sys
from pathlib import Path

# dmgbuild supplies defines when loading this file as Finder layout settings.
if __name__ == "__main__" and "defines" not in globals():
    builder = Path(__file__).resolve().with_name("build-mac-dmg.sh")
    os.execv(builder, [str(builder), *sys.argv[1:]])

app = Path(defines["app"])

format = "UDZO"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon_locations = {
    app.name: (172, 190),
    "Applications": (468, 190),
}

background = defines["background"]
window_rect = ((140, 140), (640, 390))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 84
text_size = 14
