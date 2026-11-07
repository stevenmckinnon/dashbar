# dmgbuild settings for the installer window. Built by scripts/make-dmg.sh, which passes -D app=<path to the .app>
# and -D root=<repository root>. The background is packaging/dmg/background.png (see make-background.sh).
import os

root = defines["root"]
app = defines["app"]
name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(root, "Resources/AppIcon.icns")   # the mounted volume's icon
background = os.path.join(root, "packaging/dmg/background.png")

format = "UDZO"
filesystem = "HFS+"

# A plain icon window, no toolbar or sidebar, sized to the background (660 x 400).
window_rect = ((200, 120), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
# Centres of the two icons; the arrow in the background runs between them.
icon_locations = {name: (180, 176), "Applications": (480, 176)}
