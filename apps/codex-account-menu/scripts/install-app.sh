#!/bin/bash
set -euo pipefail
umask 077

task_root=$(cd "$(dirname "$0")/.." && pwd -P)
configuration=release
candidate=""
check_only=false
task_user_home="${HOME:?HOME must name the current user home directory}"
destination="$task_user_home/Applications/Codex Account Menu.app"
storage="$task_user_home/Library/Application Support/Codex Account Menu"
bundle_id=com.tree.codex-account-menu

usage() {
    cat <<'EOF'
用法：scripts/install-app.sh [debug|release] [--app APP_PATH] [--check]
默认先编译并打包 release，再安装到当前用户的 ~/Applications/Codex Account Menu.app。
--app PATH  安装已经打包的应用，不重新编译。
--check     只检查现有候选应用和安装位置，不编译、不写入、不启动。
旧版本保留在私有应用数据目录的 app-backups/；不会关闭任何运行中的应用。
EOF
}
fail() { echo "错误：$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|release) configuration=$1; shift ;;
        --app) [ "$#" -ge 2 ] || fail "--app 缺少路径"; candidate=$2; shift 2 ;;
        --check) check_only=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail "此脚本需要 macOS"
if [ -z "$candidate" ]; then
    if [ "$check_only" = true ]; then
        candidate="${HOME}/Library/Caches/Codex Account Menu/build/${configuration}/Codex Account Menu.app"
    else
        candidate=$("$task_root/scripts/build-app.sh" "$configuration")
    fi
fi

validate_app() {
    local validated_path
    validated_path=$(python3 -B - "$1" "$bundle_id" <<'PY'
from pathlib import Path
import os
import plistlib
import sys
app = Path(sys.argv[1])
if app.is_symlink() or not app.is_dir():
    raise SystemExit("候选应用必须是普通目录：" + str(app))
try:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
except (OSError, ValueError, plistlib.InvalidFileException):
    raise SystemExit("候选应用的 Info.plist 不可读或无效。")
if (info.get("CFBundleIdentifier") != sys.argv[2]
        or info.get("CFBundleExecutable") != "CodexAccountMenu"
        or info.get("CFBundlePackageType") != "APPL"
        or info.get("LSUIElement") is not True
        or info.get("CodexAccountMenuDemo") is not False):
    raise SystemExit("候选应用身份或生产模式标记不符，拒绝安装。")
resource = info.get("CodexAccountMenuResourceBundle")
if resource != "CodexAccountMenu_SwitcherCore.bundle":
    raise SystemExit("候选应用的资源包标记不符。")
for relative in ["Contents/MacOS/CodexAccountMenu", "Contents/Helpers/codex-menu",
                 "Contents/Resources/" + resource + "/copilot-status.py"]:
    path = app / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit("候选应用缺少普通文件：" + relative)
    if relative.startswith(("Contents/MacOS/", "Contents/Helpers/")) and not os.access(path, os.X_OK):
        raise SystemExit("候选应用的程序没有执行权限：" + relative)
print(str(app.resolve()))
PY
    ) || return 1
    codesign --verify --deep --strict --verbose=2 "$1" >&2 || return 1
    printf '%s\n' "$validated_path"
}
candidate=$(validate_app "$candidate")

# This also provides a no-write preflight for --check. Existing applications
# and all private storage ancestors are inspected before creating directories.
inspect_destination() {
    python3 -B - "$destination" "$storage" "$bundle_id" "$task_user_home" <<'PY'
from pathlib import Path
import os
import plistlib
import sys
destination, storage = map(Path, sys.argv[1:3])
user_home = Path(sys.argv[4])
if (not user_home.is_absolute() or not user_home.is_dir()
        or user_home.resolve() != user_home or user_home.stat().st_uid != os.getuid()):
    raise SystemExit("用户主目录必须是本人所有的规范化绝对目录。")
for directory in [destination.parent, storage, storage / "app-backups"]:
    if not directory.is_relative_to(user_home):
        raise SystemExit("安装和备份目录必须位于当前用户主目录内。")
    for parent in [directory, *directory.parents]:
        if parent == user_home.parent:
            break
        if parent.is_symlink():
            raise SystemExit("拒绝使用符号链接目录：" + str(parent))
        if parent.exists() and (not parent.is_dir() or parent.stat().st_uid != os.getuid()):
            raise SystemExit("目录类型或所有者不符：" + str(parent))
if destination.is_symlink():
    raise SystemExit("安装位置是符号链接，拒绝覆盖。")
if destination.exists():
    if not destination.is_dir() or destination.stat().st_uid != os.getuid():
        raise SystemExit("已有安装目录类型或所有者不符。")
    try:
        with (destination / "Contents/Info.plist").open("rb") as handle:
            identifier = plistlib.load(handle).get("CFBundleIdentifier")
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise SystemExit("无法核验同名位置的应用身份，拒绝覆盖。")
    if identifier != sys.argv[3]:
        raise SystemExit("同名位置已有其他应用，拒绝覆盖。")
    stat = destination.stat()
    print(str(stat.st_dev) + ":" + str(stat.st_ino))
else:
    print("absent")
PY
}
original_destination=$(inspect_destination)
ensure_tool_stopped() {
    if ps -axo comm= | awk -F/ '$NF == "CodexAccountMenu" { found=1 } END { exit !found }'; then
        fail "账号小工具仍在运行；请从其菜单正常退出后重试。脚本不会关闭应用。"
    fi
}
ensure_tool_stopped
if [ "$check_only" = true ]; then
    printf '检查通过。\n候选：%s\n安装位置：%s\n旧版备份目录：%s/app-backups\n' "$candidate" "$destination" "$storage"
    exit 0
fi

mkdir -p "$(dirname "$destination")" "$storage/app-backups"
chmod 700 "$storage" "$storage/app-backups"
install_lock="$storage/.app-install-lock"
mkdir "$install_lock" 2>/dev/null || fail "已有安装操作或遗留锁：$install_lock"
staging_dir=""
backup=""
rollback() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ -n "$backup" ] && [ ! -e "$destination" ] && [ -d "$backup" ]; then
        mv "$backup" "$destination" || echo "需要手动恢复旧应用：$backup" >&2
    elif [ "$status" -ne 0 ] && [ -n "$backup" ] && [ -d "$backup" ]; then
        echo "安装后检查未通过；旧应用保留于：$backup" >&2
    fi
    rmdir "$install_lock" 2>/dev/null || true
    if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
        echo "保留安装工作目录：$staging_dir" >&2
    fi
    exit "$status"
}
trap rollback EXIT
staging_dir=$(mktemp -d "$(dirname "$destination")/.codex-account-menu.XXXXXX")
staged_app="$staging_dir/Codex Account Menu.app"
ditto "$candidate" "$staged_app"
validate_app "$staged_app" >/dev/null
current_destination=$(inspect_destination)
[ "$current_destination" = "$original_destination" ] || fail "安装位置在检查后发生变化，未替换任何已有应用"
ensure_tool_stopped
if [ -e "$destination" ]; then
    backup_dir=$(mktemp -d "$storage/app-backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    backup="$backup_dir/Codex Account Menu.app"
    mv "$destination" "$backup"
fi
mv "$staged_app" "$destination"
rmdir "$staging_dir"
staging_dir=""
xattr -dr com.apple.FinderInfo "$destination" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$destination" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$destination" >&2
rmdir "$install_lock"
trap - EXIT
printf '已安装：%s\n' "$destination"
if [ -n "$backup" ]; then printf '旧版备份：%s\n' "$backup"; fi
printf 'CLI：%s/Contents/Helpers/codex-menu\n未启动应用；当前 Codex 未被关闭。\n' "$destination"
