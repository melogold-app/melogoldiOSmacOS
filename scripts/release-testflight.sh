#!/bin/bash
#
# Сборки для App Store Connect и TestFlight (задание 0005): архив iOS (iPhone, iPad и приложение часов внутри) и архив
# visionOS, экспорт с загрузкой в App Store Connect ключом API. Workflow .github/workflows/testflight.yml зовёт этот
# скрипт; локально — с --dry-run: архивы без подписи, без загрузки.
#
#   scripts/release-testflight.sh [--dry-run]
#
# Секреты — только из окружения (GitHub Secrets), имена — как в заданиях 0004 §3 и 0005 §3:
#   APPLE_TEAM_ID, ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64,
#   APPLE_DISTRIBUTION_P12_BASE64, APPLE_DISTRIBUTION_P12_PASSWORD.
# Без них архивы собираются с CODE_SIGNING_ALLOWED=NO, загрузки нет, в итоге — каких секретов не хватило.
# Публикация в App Store — только по команде пользователя, в App Store Connect; этот скрипт её не делает.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "ОШИБКА: $*" >&2; summary "**Сборка остановлена:** $*"; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

step "Версия"
VERSION="$(sed -nE 's/^MARKETING_VERSION = (.*)$/\1/p' Config/Version.xcconfig)"
BUILD="$(sed -nE 's/^CURRENT_PROJECT_VERSION = (.*)$/\1/p' Config/Version.xcconfig)"
scripts/check-version.sh >/dev/null || fail "номер сборки не посчитан из версии (scripts/set-version.sh $VERSION)"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ "${GITHUB_REF_NAME:-}" != "v$VERSION" ]; then
  fail "тег ${GITHUB_REF_NAME} не совпадает с MARKETING_VERSION $VERSION в Config/Version.xcconfig"
fi
echo "  $VERSION ($BUILD). Одну версию App Store Connect дважды не примет: для повтора поднимите patch."

MISSING=""
for name in APPLE_TEAM_ID ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64 APPLE_DISTRIBUTION_P12_BASE64 APPLE_DISTRIBUTION_P12_PASSWORD; do
  if [ -z "${!name:-}" ]; then MISSING="$MISSING $name"; fi
done
if [ -z "$MISSING" ] && [ "$DRY_RUN" -eq 0 ]; then UPLOAD=1; else UPLOAD=0; fi
if [ "$UPLOAD" -eq 1 ]; then echo "  подпись Apple Distribution и загрузка в App Store Connect"; else echo "  без подписи и загрузки${MISSING:+ (нет:$MISSING)}"; fi

BUILD_DIR="${MELOGOLD_BUILD_DIR:-$ROOT/build/testflight}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
SECRETS="$BUILD_DIR/secrets"
mkdir -p "$SECRETS"
KEYCHAIN=""
cleanup() {
  rm -rf "$SECRETS"
  if [ -n "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

AUTH_ARGS=()
if [ "$UPLOAD" -eq 1 ]; then
  step "Временная связка ключей и ключ API"
  KEYCHAIN="$BUILD_DIR/melogold-testflight.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  echo "$APPLE_DISTRIBUTION_P12_BASE64" | base64 --decode > "$SECRETS/distribution.p12"
  security import "$SECRETS/distribution.p12" -k "$KEYCHAIN" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  KEY_FILE="$SECRETS/AuthKey_$ASC_API_KEY_ID.p8"
  echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$KEY_FILE"
  # Профили подписи создаются сами (-allowProvisioningUpdates) тем же ключом App Store Connect
  AUTH_ARGS=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$ASC_API_KEY_ID"
             -authenticationKeyIssuerID "$ASC_API_ISSUER_ID")
fi

# archive <имя> <назначение>
archive() {
  local name="$1" destination="$2"
  local path="$BUILD_DIR/Melogold-$name.xcarchive"
  step "Архив $name"
  local sign=(CODE_SIGNING_ALLOWED=NO)
  if [ "$UPLOAD" -eq 1 ]; then
    # Архив — автоматической подписью (сертификат разработки Xcode создаёт сам по ключу API), экспорт переподписывает
    # «Apple Distribution» из временной связки
    sign=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "CODE_SIGN_IDENTITY=Apple Development")
  fi
  local command=(xcodebuild archive -project Melogold.xcodeproj -scheme Melogold -configuration Release
                 -destination "$destination" -archivePath "$path" -derivedDataPath "$BUILD_DIR/DerivedData"
                 "${sign[@]}" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"})
  # Без «| xcbeautify || xcodebuild»: под pipefail это молча пересобирает всё при любой ошибке (грабли §9, п. 17)
  if command -v xcbeautify >/dev/null 2>&1; then
    "${command[@]}" | xcbeautify
  else
    "${command[@]}" > "$BUILD_DIR/archive-$name.log" 2>&1 || { tail -50 "$BUILD_DIR/archive-$name.log"; fail "архив $name не собрался"; }
  fi
  [ -d "$path/Products/Applications/Melogold.app" ] || fail "в архиве $name нет Melogold.app"
  local plist="$path/Products/Applications/Melogold.app/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$VERSION" ] || fail "$name: версия в Info.plist не $VERSION"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$BUILD" ] || fail "$name: номер сборки в Info.plist не $BUILD"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist" 2>/dev/null)" = "false" ] \
    || fail "$name: нет ITSAppUsesNonExemptEncryption = NO — каждая сборка спросит про шифрование"
  if [ "$name" = "iOS" ]; then
    [ -d "$path/Products/Applications/Melogold.app/Watch/Melogold Watch.app" ] || fail "в архиве iOS нет приложения часов"
  fi
}

upload() {
  local name="$1"
  step "Загрузка $name в App Store Connect"
  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$BUILD_DIR/Melogold-$name.xcarchive" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/export-$name" "${AUTH_ARGS[@]}"
}

archive iOS 'generic/platform=iOS'
archive visionOS 'generic/platform=visionOS'
UPLOADED=""
if [ "$UPLOAD" -eq 1 ]; then
  upload iOS
  upload visionOS
  UPLOADED="iOS (с часами), visionOS"
fi

summary "## Melogold $VERSION ($BUILD) для App Store Connect"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Архив iOS (iPhone, iPad, часы) | собран |"
summary "| Архив visionOS | собран |"
summary "| Загружено в App Store Connect | ${UPLOADED:-нет} |"
if [ -n "$MISSING" ]; then summary ""; summary "Не хватает секретов:$MISSING"; fi
summary ""
summary "Внутренние тестировщики получат сборку после обработки; внешние — после проверки бета-версии Apple."

step "Готово"
echo "  архивы: $BUILD_DIR/Melogold-iOS.xcarchive, $BUILD_DIR/Melogold-visionOS.xcarchive"
echo "  загружено: ${UPLOADED:-нет}"
if [ -n "$MISSING" ]; then echo "  нет секретов:$MISSING"; fi
