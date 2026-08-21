#!/usr/bin/env bash
# 门禁运行环境自检。各门禁测试脚本在 set -Eeuo pipefail 之后立刻 source 本文件。
#
# 为什么必须自检：本仓库的测试大量使用裸 `[[ ... ]]` 作为断言，靠 set -E-e 在它
# 求值为假时中止脚本来变红。Bash 5（CI 与 Debian 12）确实会中止；开发机 macOS
# 自带的 Bash 3.2 不会——脚本继续往下跑，最后照常打印通过。也就是说这类断言在
# Bash 3.2 上全部空转，跑出来的绿是不可信的。公开 Issue #167 记录的真实后果是：
# 本地 12 条门禁全绿，推上去后 CI 的 validate 立刻失败，而且失败时没有任何输出。
#
# 这里不改写那些断言，只拒绝在不具备该行为的解释器上运行门禁——断言本身在 Bash 5
# 上是有效的，问题只出在运行环境，把「只有在 Linux 门禁机上跑才算数」从靠人记得
# 变成脚本自己强制。
#
# 探针用当前解释器自己（$BASH）另起一个进程跑一遍最小用例，而不是探 PATH 里的
# bash：门禁可能被别的 bash 启动。用 if 包住是必需的——写成 `probe=... || true`
# 会让整条命令落进条件上下文，errexit 连子进程那一层都不生效，探针在 Bash 5 上
# 也会返回 REACHED，自检因此永远不报。

if sb_strict_errexit_probe="$("$BASH" -c "set -Eeuo pipefail
[[ 0 == 1 ]]
printf REACHED" 2>/dev/null)"; then :; fi

if [[ "$sb_strict_errexit_probe" == REACHED ]]; then
  printf '门禁拒绝运行：当前 Bash（%s）不会因为求值为假的 [[ ]] 而中止脚本。\n' "${BASH_VERSION:-未知}" >&2
  printf '本仓库的测试大量使用裸 [[ ]] 断言，在这样的 Bash 上它们全部空转，跑出来的通过不可信。\n' >&2
  printf '请改到 Linux 上的 Bash 5 运行，例如开发机上的门禁机：\n' >&2
  printf '  orb -m sbm-gate bash %s\n' "${BASH_SOURCE[1]:-tests/<门禁脚本>}" >&2
  exit 1
fi
unset sb_strict_errexit_probe
