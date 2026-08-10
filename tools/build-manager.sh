#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export LC_ALL=C

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
SOURCE_DIR="${SB_MANAGER_SOURCE_DIR:-$ROOT/src}"
MANIFEST="${SB_MANAGER_MODULE_MANIFEST:-$SOURCE_DIR/modules.list}"
TARGET="$ROOT/sb-user-manager.sh"
MODE='write'
TMP=""

die() {
  echo "构建失败：$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  bash tools/build-manager.sh
  bash tools/build-manager.sh --check
  bash tools/build-manager.sh --output <路径>
EOF
}

cleanup() {
  [[ -n "$TMP" ]] && rm -f -- "$TMP"
  return 0
}
trap cleanup EXIT

case "${1:-}" in
  "") ;;
  --check) MODE=check;;
  --output)
    [[ $# -eq 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
    TARGET="$2"
    ;;
  -h|--help) usage; exit 0;;
  *) usage >&2; exit 2;;
esac

[[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || die "源码目录无效：$SOURCE_DIR"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "模块清单无效：$MANIFEST"

modules=()
module_count=0
while IFS= read -r module || [[ -n "$module" ]]; do
  [[ "$module" =~ ^[0-9][0-9]-[a-z0-9-]+\.sh$ ]] || die "模块清单包含无效名称：${module:-空行}"
  for ((index=0; index<module_count; index++)); do
    existing="${modules[$index]}"
    [[ "$existing" != "$module" ]] || die "模块清单包含重复项：$module"
  done
  modules+=("$module")
  ((module_count+=1))
done < "$MANIFEST"
((module_count > 0)) || die "模块清单为空"

shopt -s nullglob
actual_paths=("$SOURCE_DIR"/*.sh)
shopt -u nullglob
[[ ${#actual_paths[@]} -eq $module_count ]] || die "源码模块数量与清单不一致"

for path in "${actual_paths[@]}"; do
  [[ -f "$path" && ! -L "$path" ]] || die "源码模块不是普通文件：$path"
  name="${path##*/}"
  listed=false
  for module in "${modules[@]}"; do
    if [[ "$name" == "$module" ]]; then listed=true; break; fi
  done
  [[ "$listed" == true ]] || die "存在未列入清单的源码模块：$name"
done

target_name="${TARGET##*/}"
target_dir="$(CDPATH='' cd -- "$(dirname -- "$TARGET")" && pwd -P)" || die "输出目录无效：$(dirname -- "$TARGET")"
TARGET="$target_dir/$target_name"
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  [[ -f "$TARGET" && ! -L "$TARGET" ]] || die "输出路径不是普通文件：$TARGET"
fi

TMP="$(mktemp "$target_dir/.sb-user-manager.build.XXXXXX")" || die "无法创建临时构建文件"
: > "$TMP"
for module in "${modules[@]}"; do
  path="$SOURCE_DIR/$module"
  [[ -f "$path" && ! -L "$path" ]] || die "模块缺失或不是普通文件：$module"
  cat -- "$path" >> "$TMP"
done

[[ "$(head -n 1 "$TMP")" == '#!/usr/bin/env bash' ]] || die "生成脚本缺少 Bash 启动行"
bash -n "$TMP" || die "生成脚本语法检查失败"
chmod 755 "$TMP"

if [[ "$MODE" == check ]]; then
  [[ -f "$TARGET" && ! -L "$TARGET" ]] || die "待检查的生成脚本不存在：$TARGET"
  cmp -s "$TMP" "$TARGET" || die "sb-user-manager.sh 不是当前模块的确定性生成结果"
  echo "manager build is current"
  exit 0
fi

mv -f -- "$TMP" "$TARGET"
TMP=""
echo "已生成：$TARGET"
