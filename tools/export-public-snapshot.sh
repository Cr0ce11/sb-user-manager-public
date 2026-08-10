#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export LC_ALL=C

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
MODE='write'
TARGET=
WORK=

die() {
  printf '公开快照导出失败：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  bash tools/export-public-snapshot.sh --output <新目录>
  bash tools/export-public-snapshot.sh --check <已有目录>
EOF
}

cleanup() {
  [[ -n "$WORK" ]] || return 0
  case "$WORK" in
    */.sb-public-snapshot.*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT

case "${1:-}" in
  --output) MODE='write' ;;
  --check) MODE='check' ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
TARGET="$2"

git -C "$ROOT" diff --quiet --no-ext-diff || die '工作区存在未提交改动'
git -C "$ROOT" diff --cached --quiet --no-ext-diff || die '暂存区存在未提交改动'
[[ -z "$(git -C "$ROOT" ls-files --others --exclude-standard)" ]] || die '工作区存在未跟踪文件'
[[ -z "$(git -C "$ROOT" ls-files -s | awk '$1 == "120000" {print $4}')" ]] || die '公开快照不允许包含符号链接'

bash "$ROOT/tools/audit-public-readiness.sh" --current-tree --check-public-tree "$ROOT" >/dev/null ||
  die '当前源码没有通过公开策略审计'

target_parent="$(dirname -- "$TARGET")"
target_name="$(basename -- "$TARGET")"
[[ -d "$target_parent" && ! -L "$target_parent" ]] || die "目标父目录无效：$target_parent"
target_parent="$(CDPATH='' cd -- "$target_parent" && pwd -P)"
TARGET="$target_parent/$target_name"
[[ ! -L "$TARGET" ]] || die "目标不能是符号链接：$TARGET"

if [[ "$MODE" == write ]]; then
  [[ ! -e "$TARGET" ]] || die "目标已经存在，拒绝覆盖：$TARGET"
else
  [[ -d "$TARGET" ]] || die "待检查目录不存在：$TARGET"
fi

WORK="$(mktemp -d "$target_parent/.sb-public-snapshot.XXXXXX")" || die '无法创建临时目录'
mkdir "$WORK/tree"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$WORK/tree"
[[ ! -e "$WORK/tree/.git" ]] || die '导出结果意外包含 Git 历史'

if [[ "$MODE" == check ]]; then
  diff -qr "$WORK/tree" "$TARGET" >/dev/null || die '公开快照与当前提交不一致'
  printf '公开源码快照与当前提交一致\n'
  exit 0
fi

mv -- "$WORK/tree" "$TARGET"
printf '已导出公开源码快照：%s\n' "$TARGET"
