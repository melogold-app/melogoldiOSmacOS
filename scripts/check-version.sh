#!/bin/zsh
# Проверяет, что номер сборки в Config/Version.xcconfig посчитан из версии (docs/PROMPT.md §3).
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -nE 's/^MARKETING_VERSION = (.*)$/\1/p' Config/Version.xcconfig)
build=$(sed -nE 's/^CURRENT_PROJECT_VERSION = (.*)$/\1/p' Config/Version.xcconfig)
parts=(${(s:.:)version})
expected=$(( parts[1] * 10000 + parts[2] * 100 + parts[3] ))
if [[ "$build" != "$expected" ]]; then
  echo "CURRENT_PROJECT_VERSION = $build, а для версии $version нужно $expected (scripts/set-version.sh $version)" >&2
  exit 1
fi
echo "Версия $version, сборка $build — ок"
