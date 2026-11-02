# dmgbuild settings for FocusDock.dmg, used by scripts/package.sh.
# `defines` comes from dmgbuild's -D flags.
app = defines.get("app", "build/FocusDock.app")  # noqa: F821

files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"

format = "UDZO"
filesystem = "HFS+"

window_rect = ((200, 200), (600, 380))
background = "builtin-arrow"
icon_size = 128
text_size = 13
icon_locations = {"FocusDock.app": (150, 175), "Applications": (450, 175)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
