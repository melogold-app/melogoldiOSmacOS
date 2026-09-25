#!/bin/zsh
# Ставит версию X.Y.Z и номер сборки major×10000 + minor×100 + patch в Config/Version.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Использование: scripts/set-version.sh X.Y.Z}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]{1,2}\.[0-9]{1,2}$' ]]; then
  echo "Версия должна быть X.Y.Z без суффиксов, minor и patch < 100" >&2
  exit 1
fi
parts=(${(s:.:)version})
build=$(( parts[1] * 10000 + parts[2] * 100 + parts[3] ))
sed -i '' -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build/" Config/Version.xcconfig
echo "Версия $version, сборка $build"
