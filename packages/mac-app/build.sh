#!/usr/bin/env bash
# DureClaw.app + DureClaw-Server-mac-arm64.dmg 빌드
#
# 사용법:
#   ./build.sh [RELEASE_DIR] [VERSION]
#     RELEASE_DIR : mix release 결과 (…/_build/prod/rel/harness_server)
#                   생략 시 packages/phoenix-server 에서 MIX_ENV=prod mix release 실행
#     VERSION     : 앱 버전 (생략 시 0.0.0-dev)
#
# 결과: packages/mac-app/dist/DureClaw.app, dist/DureClaw-Server-mac-arm64.dmg
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RELEASE_DIR="${1:-}"
VERSION="${2:-0.0.0-dev}"
DIST="$HERE/dist"
APP="$DIST/DureClaw.app"
DMG="$DIST/DureClaw-Server-mac-arm64.dmg"

if [[ -z "$RELEASE_DIR" ]]; then
  echo "→ mix release (prod)"
  (cd "$ROOT/packages/phoenix-server" && MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix release harness_server --overwrite)
  RELEASE_DIR="$ROOT/packages/phoenix-server/_build/prod/rel/harness_server"
fi
[[ -x "$RELEASE_DIR/bin/harness_server" ]] || { echo "release not found: $RELEASE_DIR" >&2; exit 1; }

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ swiftc (arm64)"
swiftc -O -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/DureClaw" "$HERE/DureClaw.swift"

echo "→ Info.plist ($VERSION)"
sed "s/__VERSION__/$VERSION/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"

echo "→ icon"
ICONSET="$DIST/DureClaw.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
SRC="$ROOT/web/favicon-256.png"
for s in 16 32 128 256; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/DureClaw.icns"
rm -rf "$ICONSET"

echo "→ bundle server release"
cp -R "$RELEASE_DIR" "$APP/Contents/Resources/server"
# 실행 중 생기는 파일은 ~/.dureclaw/server/tmp 로 간다 (번들은 읽기 전용 취급)
rm -rf "$APP/Contents/Resources/server/tmp"

echo "→ bundle non-system dylibs (crypto NIF → openssl)"
# OTP 의 crypto.so 등은 빌드 머신의 openssl(Homebrew·toolcache 등)을 절대경로로 링크한다.
# 그 경로가 없는 맥에서도 뜨도록 dylib 을 번들에 복사하고 @loader_path 로 바꾼다.
SERVER="$APP/Contents/Resources/server"
DYLIBS="$SERVER/dylibs"
mkdir -p "$DYLIBS"
_rel() { python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$1" "$2"; }
_fix_deps() {  # $1 = Mach-O 파일
  local f="$1" dep base rel changed=0
  while read -r dep; do
    base="$(basename "$dep")"
    if [[ ! -f "$DYLIBS/$base" ]]; then
      cp "$dep" "$DYLIBS/$base"
      chmod u+w "$DYLIBS/$base"
      install_name_tool -id "@loader_path/$base" "$DYLIBS/$base" 2>/dev/null
      _fix_deps "$DYLIBS/$base"
    fi
    rel="$(_rel "$DYLIBS" "$(dirname "$f")")"
    install_name_tool -change "$dep" "@loader_path/$rel/$base" "$f" 2>/dev/null
    changed=1
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/|@)' || true)
  [[ $changed == 1 ]] && codesign --force -s - "$f" >/dev/null 2>&1 || true
}
while IFS= read -r -d '' so; do _fix_deps "$so"; done < <(find "$SERVER" -type f \( -name "*.so" -o -name "*.dylib" \) -print0)
# OpenSSL 3 은 legacy 등 provider 를 컴파일 시점의 MODULESDIR(Homebrew)에서 dlopen 한다.
# 같이 번들하고, 앱이 OPENSSL_MODULES 로 이 폴더를 가리킨다.
CRYPTO_SRC=$(otool -L "$(find "$RELEASE_DIR" -name crypto.so | head -1)" | awk '/libcrypto/{print $1}' | head -1)
if [[ "$CRYPTO_SRC" == /* && -d "$(dirname "$CRYPTO_SRC")/ossl-modules" ]]; then
  mkdir -p "$SERVER/ossl-modules"
  for m in "$(dirname "$CRYPTO_SRC")"/ossl-modules/*.dylib; do
    cp "$m" "$SERVER/ossl-modules/" && chmod u+w "$SERVER/ossl-modules/$(basename "$m")"
    _fix_deps "$SERVER/ossl-modules/$(basename "$m")"
  done
fi
for d in "$DYLIBS"/*.dylib; do [[ -f "$d" ]] && codesign --force -s - "$d" >/dev/null 2>&1; done
LEFT=$(find "$SERVER" -type f \( -name "*.so" -o -name "*.dylib" \) -exec otool -L {} \; | grep -E '^\s+/' | grep -vE '^\s+(/usr/lib/|/System/)' || true)
[[ -z "$LEFT" ]] || { echo "unbundled dylib refs remain:"; echo "$LEFT"; exit 1; }
ls "$DYLIBS"

echo "→ ad-hoc codesign"
codesign --force --deep -s - "$APP"
codesign --verify --deep "$APP"

echo "→ dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DureClaw" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

ls -lh "$DMG"
echo "✅ $APP"
echo "✅ $DMG"
