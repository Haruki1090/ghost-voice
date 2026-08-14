#!/bin/bash
#
# Ghost Voice.app を組み立てて署名する。**これ 1 本で完結する。**
#
#   Scripts/make-app.sh                      # release でビルドし、証明書で署名する
#   Scripts/make-app.sh --debug              # debug ビルド
#   Scripts/make-app.sh --output ~/Desktop   # 置き場所を変える
#   Scripts/make-app.sh --identity <名前 or ハッシュ>
#   Scripts/make-app.sh --allow-adhoc        # 証明書が無い環境向け（**権限が保たれない**）
#
# ## なぜ Xcode プロジェクトを作らないか
#
# `.xcodeproj` を持ち込むとテスト経路が二重になり、`swift test`（415 件）の走らせ方が変わる。
# SwiftPM の実行ファイルをこのスクリプトで `.app` へ組み立てる方式を採る（フェーズ 2 の裁定）。
#
# ## なぜ ad-hoc 署名を既定にしないか
#
# **ad-hoc 署名の designated requirement（DR）は cdhash 単体である。**
# 実コードを 1 行変えて再ビルドすると cdhash は別物になる（実測。app-bundle.md §4.1）。
# TCC の許可は DR に紐づくので、ad-hoc のままだと**ビルドのたびに利用者が
# マイク・入力監視・アクセシビリティを付け直す**ことになる。
# 証明書で署名すれば DR から cdhash が消え、**再ビルドしても DR は 1 文字も変わらない**（実測 §4.2）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST_SOURCE="$REPO_ROOT/Resources/Info.plist"
ENTITLEMENTS="$REPO_ROOT/Resources/GhostVoice.entitlements"
CONFIGURATION="release"
OUTPUT_DIR="$REPO_ROOT/.build/app"
IDENTITY=""
ALLOW_ADHOC=0

fail() {
    # **失敗は無言にしない。** 何が足りないかと、どう直すかを必ず出す。
    echo "[失敗] $1" >&2
    shift
    for line in "$@"; do echo "        $line" >&2; done
    exit 1
}

usage() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) CONFIGURATION="debug"; shift ;;
        --release) CONFIGURATION="release"; shift ;;
        --output) OUTPUT_DIR="${2:-}"; [ -n "$OUTPUT_DIR" ] || fail "--output に置き場所がありません"; shift 2 ;;
        --identity) IDENTITY="${2:-}"; [ -n "$IDENTITY" ] || fail "--identity に署名 ID がありません"; shift 2 ;;
        --allow-adhoc) ALLOW_ADHOC=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "知らない引数です: $1" "使い方は --help を見てください" ;;
    esac
done

# ---------------------------------------------------------------- 前提の検査

command -v swift >/dev/null 2>&1 || fail "swift が見つかりません" "Xcode または Command Line Tools を入れてください"
command -v codesign >/dev/null 2>&1 || fail "codesign が見つかりません"
command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || fail "PlistBuddy が見つかりません"
xcrun --show-sdk-path --sdk macosx >/dev/null 2>&1 \
    || fail "macOS SDK が見つかりません" "xcode-select -p を確認し、必要なら xcode-select --switch してください"
[ -f "$INFO_PLIST_SOURCE" ] || fail "Resources/Info.plist がありません"
[ -f "$ENTITLEMENTS" ] || fail "Resources/GhostVoice.entitlements がありません"

# **バンドル ID と実行ファイル名は Info.plist が正である。** ここで二重に持たない
# （DR に焼き込まれる値がスクリプトと Info.plist で食い違うと、権限が黙って無効になる）。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST_SOURCE")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST_SOURCE")"
BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST_SOURCE")"
APP_PATH="$OUTPUT_DIR/$BUNDLE_NAME.app"

# ---------------------------------------------------------------- 署名 ID の決定

if [ -z "$IDENTITY" ]; then
    # Developer ID（配布用）があればそちらを優先し、無ければ Apple Development を使う。
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Developer ID Application|Apple Development)' \
        | head -n 1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')"
fi

SIGN_EXTRA=()
if [ -z "$IDENTITY" ]; then
    if [ "$ALLOW_ADHOC" -eq 1 ]; then
        IDENTITY="-"
        # ad-hoc の既定 DR は cdhash 単体なので、**identifier 固定の DR を明示的に与える。**
        # ただし tccd がこの DR をそのまま許可レコードに使うかは**未実測**（app-bundle.md §4.3 / 詳細設計書 §13 の V-18）。
        SIGN_EXTRA+=("-r=designated => identifier \"$BUNDLE_ID\"")
        cat >&2 <<WARN
[警告] 署名に使える証明書が見つからないため **ad-hoc 署名**にします。

        **この署名では、実装を 1 行変えて再ビルドしただけで別のアプリとして扱われます。**
        そのたびにマイク・入力監視・アクセシビリティを付け直すことになります
        （ad-hoc の designated requirement は cdhash 単体であるため。実測 app-bundle.md §4.1）。

        恒久的に使うなら、無料の Apple ID で作れる Apple Development 証明書を
        キーチェーンへ入れてから、このスクリプトを引数なしで走らせてください。

WARN
    else
        fail "署名に使える証明書がありません" \
            "security find-identity -v -p codesigning で確認してください" \
            "証明書が無いまま作るなら --allow-adhoc を付けます。ただし" \
            "**ビルドのたびに権限を付け直すことになります**（DR が cdhash 単体になるため）"
    fi
fi

# ---------------------------------------------------------------- ビルド

echo "==> swift build -c $CONFIGURATION --product $EXECUTABLE"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE" --package-path "$REPO_ROOT"
BINARY="$(swift build -c "$CONFIGURATION" --package-path "$REPO_ROOT" --show-bin-path)/$EXECUTABLE"
[ -x "$BINARY" ] || fail "ビルドした実行ファイルが見つかりません: $BINARY"

# ---------------------------------------------------------------- 組み立て

echo "==> 組み立て: $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$EXECUTABLE"
# **Info.plist は置換せずそのまま複製する。** 誰が走らせても同じ物ができるようにするため。
cp "$INFO_PLIST_SOURCE" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# ---------------------------------------------------------------- 署名

# SwiftPM の出す実行ファイルは既に ad-hoc 署名済み（identifier は gv-app-<ハッシュ> 相当の
# 不安定な文字列）。**--force で必ず上書きする。**
# --options runtime … Hardened Runtime（基本設計書 §10）
# -i … identifier を Info.plist の値で固定する（DR に焼き込まれる値をここで確定させる）
# --timestamp=none … 署名に外部の時刻認証を使わない（ネットワークに触らず、結果を安定させる）
echo "==> 署名: $IDENTITY"
codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp=none \
    ${SIGN_EXTRA[@]+"${SIGN_EXTRA[@]}"} \
    "$APP_PATH"
    # 展開が `${配列[@]+…}` なのは、macOS 既定の bash 3.2 では
    # `set -u` 下の空配列展開が「未定義変数」になって落ちるためである。

codesign --verify --strict --verbose=2 "$APP_PATH" \
    || fail "署名の検証に失敗しました"

echo
echo "==> codesign -d --verbose=4"
codesign -d --verbose=4 "$APP_PATH" 2>&1 | sed 's/^/    /'
echo
echo "==> codesign -d -r-  （designated requirement。**ここに cdhash が出たら権限は保たれない**）"
codesign -d -r- "$APP_PATH" 2>&1 | sed 's/^/    /'
echo
cat <<NEXT
できました: $APP_PATH

次にすること:
  1. $APP_PATH を /Applications へ移す（**後から場所を変えないこと**。TCC はパスも見ます）
  2. open "/Applications/$BUNDLE_NAME.app" で起動する
  3. システム設定 > プライバシーとセキュリティ の「入力監視」と「アクセシビリティ」で
     "$BUNDLE_NAME" をオンにする（マイクはダイアログで許可する）
  4. $BUNDLE_NAME を終了して起動し直す

  **ターミナルから $APP_PATH/Contents/MacOS/$EXECUTABLE を直接叩かないこと。**
  ターミナルの許可を引き継いでしまい、Finder から起動したときと結果が変わります。
NEXT
