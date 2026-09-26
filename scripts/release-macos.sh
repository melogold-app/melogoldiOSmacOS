#!/bin/bash
#
# Выпуск Melogold для Mac (задание 0004): архив Release → подпись → проверка Info.plist → нотаризация → DMG →
# appcast Sparkle → GitHub Release. Workflow .github/workflows/release-macos.yml зовёт этот скрипт; локально —
# с --dry-run: всё, кроме публикации.
#
#   scripts/release-macos.sh [--dry-run]
#
# Секреты — только из окружения (GitHub Secrets), имена — как в задании 0004 §3:
#   APPLE_TEAM_ID, MACOS_DEVELOPER_ID_P12_BASE64, MACOS_DEVELOPER_ID_P12_PASSWORD,
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64 — подпись Developer ID и нотаризация, только все вместе;
#   SPARKLE_ED_PRIVATE_KEY — подпись обновления EdDSA; без него appcast не публикуется.
# Без секретов подписи приложение и DMG подписаны ad-hoc и не нотаризованы — так и пишется в итоге и в описании.
#
# Другие переменные:
#   MELOGOLD_BUILD_DIR   куда собирать (по умолчанию build/release в репозитории, он в .gitignore)
#   GITHUB_REF_TYPE, GITHUB_REF_NAME, GITHUB_SHA, GH_TOKEN, GITHUB_STEP_SUMMARY — из GitHub Actions
#   MELOGOLD_PUBLISH=1   публиковать и при запуске не по тегу (workflow_dispatch с publish)
#
set -euo pipefail

REPO="melogold-app/melogoldiOSmacOS"
MIN_MACOS="26.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "ОШИБКА: $*" >&2; summary "**Выпуск остановлен:** $*"; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

# ─── Версия ─────────────────────────────────────────────────────────────────────────────────────────────

step "Версия"
VERSION="$(sed -nE 's/^MARKETING_VERSION = (.*)$/\1/p' Config/Version.xcconfig)"
BUILD="$(sed -nE 's/^CURRENT_PROJECT_VERSION = (.*)$/\1/p' Config/Version.xcconfig)"
scripts/check-version.sh >/dev/null || fail "номер сборки не посчитан из версии (scripts/set-version.sh $VERSION)"
TAG="v$VERSION"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ "${GITHUB_REF_NAME:-}" != "$TAG" ]; then
  fail "тег ${GITHUB_REF_NAME} не совпадает с MARKETING_VERSION $VERSION в Config/Version.xcconfig"
fi
NOTES_RU="release-notes/$VERSION.ru.md"
NOTES_EN="release-notes/$VERSION.en.md"
[ -s "$NOTES_RU" ] && [ -s "$NOTES_EN" ] || fail "нет «Что нового»: $NOTES_RU и $NOTES_EN"
echo "  $VERSION ($BUILD), тег $TAG"

PUBLISH=0
if [ "$DRY_RUN" -eq 0 ] && { [ "${GITHUB_REF_TYPE:-}" = "tag" ] || [ "${MELOGOLD_PUBLISH:-0}" = "1" ]; }; then PUBLISH=1; fi

# ─── Что из секретов есть ───────────────────────────────────────────────────────────────────────────────

MISSING=""
for name in APPLE_TEAM_ID MACOS_DEVELOPER_ID_P12_BASE64 MACOS_DEVELOPER_ID_P12_PASSWORD ASC_API_KEY_ID ASC_API_ISSUER_ID ASC_API_KEY_P8_BASE64; do
  if [ -z "${!name:-}" ]; then MISSING="$MISSING $name"; fi
done
# Подпись без нотаризации пользователю не лучше ad-hoc: полная цепочка — только со всеми секретами
if [ -z "$MISSING" ]; then SIGNED=1; else SIGNED=0; fi
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then HAS_SPARKLE_KEY=1; else HAS_SPARKLE_KEY=0; MISSING="$MISSING SPARKLE_ED_PRIVATE_KEY"; fi
if [ "$SIGNED" -eq 1 ]; then echo "  подпись: Developer ID и нотаризация"; else echo "  подпись: ad-hoc, без нотаризации (нет:$MISSING)"; fi

BUILD_DIR="${MELOGOLD_BUILD_DIR:-$ROOT/build/release}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/Melogold.xcarchive"
DERIVED="$BUILD_DIR/DerivedData"
SECRETS="$BUILD_DIR/secrets"
mkdir -p "$SECRETS"
KEYCHAIN=""
cleanup() {
  rm -rf "$SECRETS"
  if [ -n "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# ─── Связка ключей и ключ API (с секретами) ─────────────────────────────────────────────────────────────

if [ "$SIGNED" -eq 1 ]; then
  step "Временная связка ключей"
  KEYCHAIN="$BUILD_DIR/melogold-release.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  echo "$MACOS_DEVELOPER_ID_P12_BASE64" | base64 --decode > "$SECRETS/developer-id.p12"
  security import "$SECRETS/developer-id.p12" -k "$KEYCHAIN" -P "$MACOS_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -nE 's/.*"(Developer ID Application:[^"]+)".*/\1/p' | head -1)"
  [ -n "$IDENTITY" ] || fail "в MACOS_DEVELOPER_ID_P12_BASE64 нет сертификата «Developer ID Application»"
  echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$SECRETS/AuthKey_$ASC_API_KEY_ID.p8"
  echo "  $IDENTITY"
fi

# ─── Архив ──────────────────────────────────────────────────────────────────────────────────────────────

step "Архив Release"
SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
if [ "$SIGNED" -eq 1 ]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
             "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN --timestamp")
fi
# Без «xcodebuild | xcbeautify || xcodebuild»: под pipefail это молча пересобирает всё при любой ошибке (грабли §9, п. 17)
XCODEBUILD=(xcodebuild archive -project Melogold.xcodeproj -scheme Melogold -configuration Release
            -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED"
            ENABLE_HARDENED_RUNTIME=YES "${SIGN_ARGS[@]}")
if command -v xcbeautify >/dev/null 2>&1; then
  "${XCODEBUILD[@]}" | xcbeautify
else
  "${XCODEBUILD[@]}" > "$BUILD_DIR/archive.log" 2>&1 || { tail -50 "$BUILD_DIR/archive.log"; fail "архив не собрался (журнал: $BUILD_DIR/archive.log)"; }
fi
[ -d "$ARCHIVE/Products/Applications/Melogold.app" ] || fail "в архиве нет Melogold.app"

APP_DIR="$BUILD_DIR/app"
mkdir -p "$APP_DIR"
APP="$APP_DIR/Melogold.app"
if [ "$SIGNED" -eq 1 ]; then
  step "Экспорт Developer ID"
  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$APP_DIR"
  [ -d "$APP" ] || fail "экспорт не дал Melogold.app"
else
  step "Подпись ad-hoc"
  ditto "$ARCHIVE/Products/Applications/Melogold.app" "$APP"
  # Без --options runtime: у ad-hoc нет Team ID, и Hardened Runtime с проверкой библиотек не дал бы загрузить
  # Sparkle.framework («different Team ID») — приложение падало бы при запуске
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" || fail "подпись приложения не проходит проверку"

# ─── Проверка собранного приложения ─────────────────────────────────────────────────────────────────────

step "Info.plist собранного приложения"
PLIST="$APP/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
[ "$(read_key CFBundleShortVersionString)" = "$VERSION" ] || fail "CFBundleShortVersionString = $(read_key CFBundleShortVersionString), а выпускаем $VERSION"
# CFBundleVersion обязан совпасть с sparkle:version в appcast, иначе обновление молча не придёт никогда (грабли §9, п. 15)
[ "$(read_key CFBundleVersion)" = "$BUILD" ] || fail "CFBundleVersion = $(read_key CFBundleVersion), а номер сборки $BUILD"
FEED="$(read_key SUFeedURL)"
PUBLIC_KEY="$(read_key SUPublicEDKey)"
[ -n "$FEED" ] || fail "в Info.plist нет SUFeedURL — приложение не обновится никогда"
if [ -z "$PUBLIC_KEY" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  ВНИМАНИЕ: SUPublicEDKey пуст (Config/Project.xcconfig) — без --dry-run выпуск остановится"
  else
    fail "в Info.plist пуст SUPublicEDKey — Sparkle отвергнет любое обновление (SPARKLE_PUBLIC_ED_KEY в Config/Project.xcconfig)"
  fi
fi
echo "  $VERSION ($BUILD), фид $FEED"

# ─── Нотаризация приложения ─────────────────────────────────────────────────────────────────────────────

notarize() {
  xcrun notarytool submit "$1" --key "$SECRETS/AuthKey_$ASC_API_KEY_ID.p8" --key-id "$ASC_API_KEY_ID" \
    --issuer "$ASC_API_ISSUER_ID" --wait --timeout 60m
}
if [ "$SIGNED" -eq 1 ]; then
  step "Нотаризация приложения"
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/Melogold-notarize.zip"
  notarize "$BUILD_DIR/Melogold-notarize.zip"
  # Без stapler первый запуск без сети упрётся в проверку Gatekeeper (грабли §9, п. 16)
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# ─── DMG ────────────────────────────────────────────────────────────────────────────────────────────────

step "DMG"
DMG="$BUILD_DIR/Melogold-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Melogold.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Melogold" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ "$SIGNED" -eq 1 ]; then
  # Gatekeeper проверяет то, что скачали: DMG подписывается и нотаризуется сам
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
hdiutil verify "$DMG" >/dev/null || fail "DMG не проходит hdiutil verify"
DMG_SIZE="$(stat -f %z "$DMG")"
echo "  $DMG ($DMG_SIZE байт)"

# ─── Appcast ────────────────────────────────────────────────────────────────────────────────────────────

APPCAST=""
SIGN_UPDATE="$(find "$DERIVED/SourcePackages/artifacts" -path '*/bin/sign_update' -type f 2>/dev/null | head -1)"
if [ "$HAS_SPARKLE_KEY" -eq 1 ]; then
  step "Appcast"
  [ -n "$SIGN_UPDATE" ] || fail "не найден sign_update Sparkle в $DERIVED/SourcePackages/artifacts"
  # Ключ — во временный файл, в конце он удаляется (cleanup)
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$SECRETS/sparkle-ed-key"
  SIGNATURE_LINE="$("$SIGN_UPDATE" --ed-key-file "$SECRETS/sparkle-ed-key" "$DMG")"
  ED_SIGNATURE="$(echo "$SIGNATURE_LINE" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
  [ -n "$ED_SIGNATURE" ] || fail "sign_update не дал подписи: $SIGNATURE_LINE"
  APPCAST="$BUILD_DIR/appcast.xml"
  # «Что нового» на двух языках — своим шаблоном (generate_appcast двух языков в одном выпуске не пишет)
  python3 - "$APPCAST" "$VERSION" "$BUILD" "$MIN_MACOS" "$DMG_SIZE" "$ED_SIGNATURE" \
    "https://github.com/$REPO/releases/download/$TAG/Melogold-$VERSION.dmg" "$NOTES_RU" "$NOTES_EN" <<'PY'
import html, sys
from email.utils import formatdate
out, version, build, minimum, size, signature, url, notes_ru, notes_en = sys.argv[1:]

def to_html(path):
    items, paragraphs = [], []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line.startswith(("- ", "* ")):
            items.append("<li>" + html.escape(line[2:]) + "</li>")
        elif line:
            paragraphs.append("<p>" + html.escape(line) + "</p>")
    body = "".join(paragraphs)
    if items:
        body += "<ul>" + "".join(items) + "</ul>"
    return body

xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Melogold</title>
    <link>https://github.com/melogold-app/melogoldiOSmacOS</link>
    <item>
      <title>Melogold {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description xml:lang="ru"><![CDATA[{to_html(notes_ru)}]]></description>
      <description xml:lang="en"><![CDATA[{to_html(notes_en)}]]></description>
      <enclosure url="{url}" length="{size}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(xml)
PY
  xmllint --noout "$APPCAST" || fail "appcast.xml не разбирается"
  grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || fail "в appcast нет номера сборки $BUILD"
  echo "  $APPCAST"
else
  echo "  appcast не публикуется: нет SPARKLE_ED_PRIVATE_KEY"
fi

# ─── Описание выпуска ───────────────────────────────────────────────────────────────────────────────────

NOTES="$BUILD_DIR/release-notes.md"
{
  cat "$NOTES_RU"
  echo
  cat "$NOTES_EN"
  if [ "$SIGNED" -eq 0 ]; then
    echo
    echo "Приложение не подписано Apple. Первый запуск: «Системные настройки › Конфиденциальность и безопасность › Всё равно открыть»."
    echo
    echo "The app is not signed by Apple. First launch: System Settings › Privacy & Security › Open Anyway."
  fi
} > "$NOTES"

# ─── Публикация ─────────────────────────────────────────────────────────────────────────────────────────

if [ "$PUBLISH" -eq 1 ]; then
  step "GitHub Release $TAG"
  ASSETS=("$DMG")
  if [ -n "$APPCAST" ]; then ASSETS+=("$APPCAST"); fi
  TARGET_ARGS=()
  if [ -n "${GITHUB_SHA:-}" ]; then TARGET_ARGS=(--target "$GITHUB_SHA"); fi
  # ${arr[@]+…}: пустой массив под set -u в bash 3.2 (раннер macOS) иначе — «unbound variable»
  gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "Melogold $VERSION" --notes-file "$NOTES" --latest \
    ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}
else
  step "Публикация пропущена (пробный прогон или запуск не по тегу)"
fi

# ─── Итог ───────────────────────────────────────────────────────────────────────────────────────────────

yes_no() { if [ "$1" -eq 1 ]; then echo "да"; else echo "нет"; fi; }
summary "## Melogold $VERSION ($BUILD) для Mac"
summary ""
summary "| | |"
summary "|---|---|"
summary "| DMG | Melogold-$VERSION.dmg, $DMG_SIZE байт |"
summary "| Подписан Developer ID | $(yes_no "$SIGNED") |"
summary "| Нотаризован | $(yes_no "$SIGNED") |"
if [ -n "$APPCAST" ]; then summary "| Appcast | да |"; else summary "| Appcast | нет |"; fi
summary "| Опубликован | $(yes_no "$PUBLISH") |"
if [ -n "$MISSING" ]; then summary ""; summary "Не хватает секретов:$MISSING"; fi

step "Готово"
echo "  DMG:      $DMG"
if [ -n "$APPCAST" ]; then echo "  appcast:  $APPCAST"; fi
echo "  подписан: $(yes_no "$SIGNED"), нотаризован: $(yes_no "$SIGNED"), опубликован: $(yes_no "$PUBLISH")"
if [ -n "$MISSING" ]; then echo "  нет секретов:$MISSING"; fi
