#!/bin/bash
set -euo pipefail
umask 077

task_root=$(cd "$(dirname "$0")/.." && pwd -P)
configuration=release
output_dir=""
skip_build=false
demo_bundle=false

usage() {
    cat <<'EOF'
用法：scripts/build-app.sh [debug|release] [--output DIR] [--skip-build] [--demo-bundle]
默认编译 release，生成签名后的应用；只打包，不安装、不启动。
--output DIR   指定输出目录；应用的绝对路径写到 stdout。
--skip-build   使用已编译的同配置产物，不重新编译。
--demo-bundle  创建始终使用演示数据的独立测试包，不能用于正式安装。
EOF
}
fail() { echo "错误：$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|release) configuration=$1; shift ;;
        --output) [ "$#" -ge 2 ] || fail "--output 缺少目录"; output_dir=$2; shift 2 ;;
        --skip-build) skip_build=true; shift ;;
        --demo-bundle) demo_bundle=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail "此脚本需要 macOS"
swift_bin=$(xcrun --find swift) || fail "找不到当前 Xcode/Command Line Tools 的 Swift"
command -v python3 >/dev/null || fail "找不到 python3"

mkdir -p "$task_root/.build"
build_log=$(mktemp "$task_root/.build/app-build-${configuration}.XXXXXX")
if [ "$skip_build" = false ]; then
    echo "正在编译 ${configuration}；日志：${build_log}" >&2
    if ! "$swift_bin" build --package-path "$task_root" -c "$configuration" -j 4 >"$build_log" 2>&1; then
        tail -n 60 "$build_log" >&2
        fail "编译失败；完整日志：$build_log"
    fi
    tail -n 5 "$build_log" >&2
else
    echo "跳过编译，使用已有 $configuration 产物；不会核对其是否包含最新源码。" >&2
fi
bin_dir=$("$swift_bin" build --package-path "$task_root" -c "$configuration" --show-bin-path)
bin_dir=$(cd "$bin_dir" && pwd -P)
for product in CodexAccountMenu codex-menu; do
    [ -f "$bin_dir/$product" ] && [ -x "$bin_dir/$product" ] || fail "缺少产物：$bin_dir/$product"
done

# SwiftPM's generated accessor is the source of truth for the bundle name.
# Its app-root fallback is unsuitable for a signed .app. SwitcherCore also
# searches Contents/Resources for the GUI and the adjacent Helpers CLI.
accessor="$bin_dir/SwitcherCore.build/DerivedSources/resource_bundle_accessor.swift"
[ -f "$accessor" ] || fail "缺少生成的资源定位文件：$accessor"
resource_name=$(python3 - "$accessor" <<'PY'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text()
match = re.search(r'let mainPath\s*=\s*Bundle\.main\.bundleURL\.appendingPathComponent\("([A-Za-z0-9_.-]+\.bundle)"\)\.path', source)
if not match:
    raise SystemExit("SwiftPM 资源定位方式已变化，请先复核生成的 accessor，不能猜测打包位置。")
name = match.group(1)
if name != "CodexAccountMenu_SwitcherCore.bundle":
    raise SystemExit("资源包名称已变化，请同步复核 SwitcherCore 的已安装应用查找路径。")
print(name)
PY
)
[ -f "$bin_dir/$resource_name/copilot-status.py" ] || fail "资源包缺少 Copilot 读取程序"
[ -f "$bin_dir/$resource_name/codex-api-relay.mjs" ] || fail "资源包缺少本机模型转发程序"

[ -n "$output_dir" ] || output_dir="${HOME}/Library/Caches/Codex Account Menu/build/${configuration}"
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)
bundle_id=com.tree.codex-account-menu
display_name=Codex账号
app_name="Codex Account Menu.app"
if [ "$demo_bundle" = true ]; then
    bundle_id="$bundle_id.demo"
    display_name="Codex账号（演示）"
    app_name="Codex Account Menu Demo.app"
fi
destination="$output_dir/$app_name"
staging_dir=$(mktemp -d "$output_dir/.package.XXXXXX")
staged_app="$staging_dir/$app_name"
trap 'if [ -d "$staging_dir" ]; then echo "保留打包工作目录：$staging_dir" >&2; fi' EXIT
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Helpers" "$staged_app/Contents/Resources"
install -m 755 "$bin_dir/CodexAccountMenu" "$staged_app/Contents/MacOS/CodexAccountMenu"
install -m 755 "$bin_dir/codex-menu" "$staged_app/Contents/Helpers/codex-menu"
ditto --noextattr "$bin_dir/$resource_name" "$staged_app/Contents/Resources/$resource_name"

python3 - "$staged_app" "$bundle_id" "$display_name" "$configuration" "$demo_bundle" "$resource_name" <<'PY'
from pathlib import Path
import plistlib
import sys
app, identifier, name, configuration, demo, resource = sys.argv[1:]
info = {
    "CFBundleIdentifier": identifier, "CFBundleName": name,
    "CFBundleDisplayName": name, "CFBundleExecutable": "CodexAccountMenu",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True, "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication", "CodexAccountMenuDemo": demo == "true",
    "CodexAccountMenuBuildConfiguration": configuration,
    "CodexAccountMenuResourceBundle": resource,
}
with (Path(app) / "Contents/Info.plist").open("wb") as handle:
    plistlib.dump(info, handle, sort_keys=True)
PY
plutil -lint "$staged_app/Contents/Info.plist" >&2
# Only remove Finder/resource-fork decoration from this generated artifact.
# Do not remove quarantine or change any machine-wide trust setting.
xattr -dr com.apple.FinderInfo "$staged_app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$staged_app" 2>/dev/null || true
codesign --force --sign - --timestamp=none --identifier "$bundle_id.cli" "$staged_app/Contents/Helpers/codex-menu" >&2
codesign --force --sign - --timestamp=none "$staged_app" >&2
codesign --verify --deep --strict --verbose=2 "$staged_app" >&2

# Preserve an earlier generated build while publishing the replacement. Never
# replace a symlink or an unrelated app merely because its filename matches.
if [ -e "$destination" ] || [ -L "$destination" ]; then
    python3 - "$destination" "$bundle_id" <<'PY'
from pathlib import Path
import plistlib
import sys
app = Path(sys.argv[1])
if app.is_symlink() or not app.is_dir():
    raise SystemExit("输出位置不是普通应用目录，拒绝覆盖：" + str(app))
with (app / "Contents/Info.plist").open("rb") as handle:
    identifier = plistlib.load(handle).get("CFBundleIdentifier")
if identifier != sys.argv[2]:
    raise SystemExit("输出位置已有其他应用，拒绝覆盖：" + str(app))
PY
    mv "$destination" "$staging_dir/previous.app"
    if ! mv "$staged_app" "$destination"; then
        mv "$staging_dir/previous.app" "$destination"
        fail "发布新构建失败，先前构建已恢复"
    fi
    echo "上一份构建保留于：$staging_dir/previous.app" >&2
else
    mv "$staged_app" "$destination"
    rmdir "$staging_dir"
fi
trap - EXIT
xattr -dr com.apple.FinderInfo "$destination" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$destination" 2>/dev/null || true
codesign --verify --deep --strict "$destination" >&2
echo "应用已打包；未安装或启动。" >&2
printf '%s\n' "$destination"
