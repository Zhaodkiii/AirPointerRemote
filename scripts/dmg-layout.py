from pathlib import Path

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
