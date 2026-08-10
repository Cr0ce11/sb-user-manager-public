#!/usr/bin/env bash
# 每组 source 都必须在独立子进程中运行，环境修改不应跨用例保留。
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-public-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

bash "$ROOT/tools/build-manager.sh" --check
bash -n "$ROOT/sb-user-manager.sh"

grep -Fxq 'SCRIPT_EDITION_LABEL="公开版"' "$ROOT/sb-user-manager.sh"
grep -Fxq 'MANAGER_REPOSITORY="DTB201/sb-user-manager"' "$ROOT/sb-user-manager.sh"
grep -Fxq 'MANAGER_ASSET="sb-user-manager.sh"' "$ROOT/sb-user-manager.sh"
for forbidden in \
  'SCRIPT_EDITION_LABEL="私有版"' \
  'SCRIPT_EDITION_LABEL="分享版"' \
  'Authorization: Bearer' \
  'prompt_github_token()' \
  'github_curl_with_token()' \
  '# >>> private_' \
  'SB_CONFIG_TOKEN'; do
  if grep -Fq "$forbidden" "$ROOT/sb-user-manager.sh"; then
    printf '公开版仍包含私有更新特征：%s\n' "$forbidden" >&2
    exit 1
  fi
done

legacy_config="$WORK/legacy.conf"
printf '%s\n' \
  'HANDSHAKE_PORT=443' \
  'GITHUB_TOKEN="legacy-token-must-be-discarded"' > "$legacy_config"
chmod 600 "$legacy_config"
(
  export SB_USER_CONF="$legacy_config"
  export SB_USER_MANAGER_LIBRARY=true
  export GITHUB_TOKEN=environment-token-must-be-discarded
  export SB_GITHUB_TOKEN=legacy-environment-token
  source "$ROOT/sb-user-manager.sh"
  load_runtime_config
  [[ -z "${GITHUB_TOKEN+x}" && -z "${SB_GITHUB_TOKEN+x}" ]]
)

(
  export SB_USER_MANAGER_LIBRARY=true
  source "$ROOT/sb-user-manager.sh"
  curl_args="$WORK/curl-args"
  curl() {
    printf '%s\0' "$@" > "$curl_args"
    jq -cn --arg digest "sha256:$(printf 'a%.0s' {1..64})" '{
      tag_name:"v9.9.9",
      assets:[{
        name:"sb-user-manager.sh",
        browser_download_url:"https://github.com/DTB201/sb-user-manager/releases/download/v9.9.9/sb-user-manager.sh",
        digest:$digest
      }]
    }'
  }
  export GITHUB_TOKEN=must-not-enter-curl
  fetch_latest_manager_release
  [[ "$LATEST_MANAGER_VERSION" == 9.9.9 ]]
  [[ "$LATEST_MANAGER_URL" == https://github.com/DTB201/sb-user-manager/releases/download/v9.9.9/sb-user-manager.sh ]]
  [[ "$LATEST_MANAGER_SHA256" == "$(printf 'a%.0s' {1..64})" ]]
  if tr '\0' '\n' < "$curl_args" | grep -Fq must-not-enter-curl; then
    echo '匿名更新请求不应包含旧 GitHub Token' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$curl_args" | grep -Fq Authorization:; then
    echo '匿名更新请求不应包含 Authorization 头' >&2
    exit 1
  fi
  grep -Fxq 'https://api.github.com/repos/DTB201/sb-user-manager/releases/latest' \
    < <(tr '\0' '\n' < "$curl_args")
)

(
  export SB_USER_MANAGER_LIBRARY=true
  source "$ROOT/sb-user-manager.sh"
  environment_is_deployed() { return 0; }
  load_runtime_config() { unset GITHUB_TOKEN SB_GITHUB_TOKEN; }
  need_cmd() { return 0; }
  fetch_latest_releases() {
    printf '%s\n' "$1" > "$WORK/fetch-mode"
    LATEST_SINGBOX_VERSION=1.13.14
    LATEST_NFUSE_VERSION=0.1.13
    LATEST_MANAGER_VERSION=9.9.9
  }
  installed_singbox_version() { printf '1.13.14'; }
  installed_nfuse_version() { printf '0.1.13'; }
  installed_manager_version() { printf '%s' "$SCRIPT_VERSION"; }
  current_singbox_channel() { printf stable; }
  deploy_environment() { printf 'DEPLOY=%s,%s\n' "$1" "$2"; }
  exec() { printf 'EXEC=%s\n' "$*"; }
  printf 'y\n' | check_updates
) > "$WORK/update-output"

grep -Fxq true "$WORK/fetch-mode"
grep -Fq '管理脚本' "$WORK/update-output"
grep -Fq 'DEPLOY=false,true' "$WORK/update-output"
grep -Fq 'EXEC=/usr/local/sbin/sb-user-manager' "$WORK/update-output"
if grep -Fq '访问令牌' "$WORK/update-output"; then
  echo '公开版不应请求或显示 GitHub 访问令牌' >&2
  exit 1
fi

(
  export SB_USER_MANAGER_LIBRARY=true
  source "$ROOT/sb-user-manager.sh"
  prepare_menu_screen() { return 0; }
  interactive_main <<< '0'
) > "$WORK/menu-output"
grep -Fq "sb-user-manager $(sed -n 's/^SCRIPT_VERSION=\"\([^\"]*\)\"/\1/p' "$ROOT/sb-user-manager.sh" | head -n1)（公开版）" "$WORK/menu-output"

echo 'public edition checks passed'
