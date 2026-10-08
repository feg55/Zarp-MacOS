# dmgbuild settings for Zarp's disk image: the window people see when they open the .dmg.
# scripts/package.sh runs `dmgbuild -s scripts/dmg/settings.py -D app=... -D volume_icon=... -D background=...`;
# dmgbuild provides `defines`. The artwork is background.png / background@2x.png in this folder, drawn by
# `swift scripts/make-icon.swift dmg-background scripts/dmg` (dmgbuild finds the @2x file by itself), and
# the icon positions below have to agree with the tiles drawn there (dmgZarpCenter, dmgApplicationsCenter).

format = "UDZO"
filesystem = "HFS+"

files = [defines["app"]]                      # Zarp.app, copied with ditto so its signature survives
symlinks = {"Applications": "/Applications"}   # the drop target
icon = defines["volume_icon"]                 # the volume shows Zarp's icon
background = defines["background"]

# Position and size of the window (title bar included: the content area is 660 x 372, the size of the
# background), then what it shows: icons only, no toolbar or sidebar. Since macOS 13 the status bar and
# the path bar are global Finder settings that a disk image cannot hide, so the background keeps what
# matters in its upper part.
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_pathbar = False
show_status_bar = False
show_tab_view = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"

icon_locations = {
    "Zarp.app": (170, 196),
    "Applications": (490, 196),
}
# Do NOT add hide_extensions = ["Zarp.app"]: it sets the com.apple.FinderInfo attribute on the bundle, and
# `codesign --verify --strict` then rejects the app inside the image ("resource fork, Finder information,
# or similar detritus not allowed"). Finder hides the .app suffix by itself unless the user shows all
# extensions. package.sh verifies the signature inside the finished image.
