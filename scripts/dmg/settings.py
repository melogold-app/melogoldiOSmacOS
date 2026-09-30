# Оформление окна DMG для dmgbuild (scripts/release-macos.sh): фон с подсказкой и стрелкой (Config/dmg/background.tiff,
# рисует scripts/dmg/make-background.swift), значок приложения слева, «Программы» справа — стрелка между ними.
# dmgbuild пишет .DS_Store сам, без Finder и AppleScript: на раннере без окна входа это единственное, что работает.
#
#   dmgbuild -s scripts/dmg/settings.py -D root=. -D app=путь/к/Melogold.app "Melogold" Melogold.dmg
import os

application = defines["app"]  # noqa: F821 — `defines` даёт dmgbuild
app_name = os.path.basename(application)
root = defines.get("root", os.getcwd())  # noqa: F821 — корень репозитория; dmgbuild не задаёт __file__

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
background = os.path.join(root, "Config", "dmg", "background.tiff")

# Окно: 660×400 — фон, и ещё 32 pt заголовка окна Finder (рамка окна считается вместе с ним); центры значков совпадают
# со стрелкой на фоне
window_rect = ((200, 140), (660, 432))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {app_name: (180, 200), "Applications": (480, 200)}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False

# Значок тома — значок приложения, если он есть в собранном пакете
for name in ("Melogold.icns", "AppIcon.icns"):
    icon_file = os.path.join(application, "Contents", "Resources", name)
    if os.path.exists(icon_file):
        icon = icon_file
        break
