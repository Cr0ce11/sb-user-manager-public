#!/usr/bin/env bash
# Bash 手册：命令的返回值被 ! 取反时，set -e 不因它失败而退出。
# 因此写成独立语句的 `! cmd` 断言命中缺陷也不会让测试变红 —— 看着有保护，实际是空操作。
# 正确写法是显式判断：
#   if cmd; then echo '说明为什么这是错的' >&2; exit 1; fi
#
# 条件上下文里的 ! 是合法的（`if ! cmd; then`、`while ! cmd; do` 等），本检查放行。
set -Eeuo pipefail

status=0
for file in "$@"; do
  [[ -f "$file" ]] || { printf 'missing file: %s\n' "$file" >&2; status=1; continue; }
  awk -v file="$file" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    {
      line = trim($0)
      # 上一行把本行拉进条件，或本行是上一行的续行
      if (prev ~ /(^|[[:space:];])(if|elif|while|until)$/ ||
          prev ~ /(&&|\|\|)$/ ||
          prev ~ /\\$/) { prev = line; next }
      if (line ~ /^![[:space:]]/) {
        # 本行自身构成条件的一部分，或续行到下一行
        if (line ~ /;[[:space:]]*(then|do)[[:space:]]*$/ ||
            line ~ /(&&|\|\|)[[:space:]]*$/ ||
            line ~ /\\$/) { prev = line; next }
        printf "%s:%d: bare `!` assertion is exempt from errexit; use `if cmd; then echo ...; exit 1; fi`\n", file, NR > "/dev/stderr"
        found = 1
      }
      prev = line
    }
    END { exit(found ? 1 : 0) }
  ' "$file" || status=1
done
exit "$status"
