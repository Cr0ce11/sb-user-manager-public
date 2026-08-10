#!/usr/bin/env bash
set -Eeuo pipefail

repository="${1:-${GITHUB_REPOSITORY:-}}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo '无法确认要发布的 GitHub 仓库；不可变 Release 预检失败。' >&2
  exit 1
fi

settings=""
if ! settings="$(gh api --method GET "repos/${repository}/immutable-releases")"; then
  printf '无法读取 %s 的不可变 Release 设置；拒绝创建 Release。\n' "$repository" >&2
  exit 1
fi

if ! jq -e 'type == "object" and .enabled == true' <<<"$settings" >/dev/null; then
  printf '%s 未明确启用不可变 Release；拒绝创建 Release。\n' "$repository" >&2
  exit 1
fi

printf '不可变 Release 预检通过：%s\n' "$repository"
