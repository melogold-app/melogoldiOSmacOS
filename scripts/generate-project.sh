#!/bin/zsh
# Генерирует Melogold.xcodeproj из project.yml (docs/PROMPT.md §3). XcodeGen закреплён пакетом BuildTools
# и собирается из исходников — Homebrew не нужен; так же делает CI.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --package-path BuildTools -c release --product xcodegen -q
BuildTools/.build/release/xcodegen generate --spec project.yml --quiet

# Самый маленький обход (docs/PROMPT.md §3): XcodeGen 2.46 пишет у .icon тип wrapper.icon, а Xcode 27
# знает иконки Icon Composer как folder.iconcomposer.icon — иначе иконка не компилируется.
sed -i '' 's/lastKnownFileType = wrapper\.icon;/lastKnownFileType = folder.iconcomposer.icon;/' Melogold.xcodeproj/project.pbxproj

echo "Melogold.xcodeproj обновлён"
