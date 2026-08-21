#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

[[ -x tools/build-manager.sh ]]
[[ -f src/modules.list && ! -L src/modules.list ]]
source_module_count="$(find src -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' | wc -l | tr -d ' ')"
if [[ "$source_module_count" != 11 ]]; then
  printf 'expected 11 source modules, found %s\n' "$source_module_count" >&2
  exit 1
fi
expected_modules='00-bootstrap.sh
05-kernel.sh
10-state-transactions.sh
20-migration-backup.sh
30-user-runtime.sh
40-split-runtime.sh
50-install-update.sh
60-operations-diagnostics.sh
70-split-prompts.sh
79-standalone-startup.sh
80-menus-main.sh'
[[ "$(<src/modules.list)" == "$expected_modules" ]]
if find src tests -maxdepth 1 -type f \
    \( -name '*controller*' -o -name '*landing*' -o -name '*manager-role*' \) | grep -q .; then
  echo 'retired v5 source or dedicated test files remain' >&2
  exit 1
fi
# 已退役的 v5 决定文档编号为 0005-0027，不得复活；POC 文档同样不得回来。
# 这里按编号区间判断而不是冻结 ADR 总数 —— 冻结总数会把新增的合法决定一并挡住。
retired_decisions="$(find docs/DECISIONS -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.md' \
  | sed 's|.*/||; s|-.*||' | awk '$1 >= 5 && $1 <= 27')"
if [[ -n "$retired_decisions" || -e docs/V5-ENTRY-CONTROLLER-POC.md ]]; then
  echo 'retired v5 ADR or POC documents remain' >&2
  exit 1
fi
bash tools/build-manager.sh --check >/dev/null
bash tests/check-managed-step-errexit.sh sb-user-manager.sh
python3 tests/check-shell-call-targets.py sb-user-manager.sh
if grep -REn --include='*.sh' \
  "<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?[[:space:]]*\\|\\|[[:space:]]*$" \
  src tests tools; then
  echo 'heredoc opener must not end with a dangling ||; wrap the heredoc in a group' >&2
  exit 1
fi

managed_step_fixture="$(mktemp "${TMPDIR:-/tmp}/sb-managed-step-negative.XXXXXX")"
managed_step_output="$(mktemp "${TMPDIR:-/tmp}/sb-managed-step-output.XXXXXX")"
shell_target_fixture="$(mktemp "${TMPDIR:-/tmp}/sb-shell-target-negative.XXXXXX")"
shell_target_output="$(mktemp "${TMPDIR:-/tmp}/sb-shell-target-output.XXXXXX")"
convention_fixture="$(mktemp "${TMPDIR:-/tmp}/sb-convention-fixture.XXXXXX")"
convention_output="$(mktemp "${TMPDIR:-/tmp}/sb-convention-output.XXXXXX")"
negation_fixture="$(mktemp "${TMPDIR:-/tmp}/sb-negation-fixture.XXXXXX")"
negation_output="$(mktemp "${TMPDIR:-/tmp}/sb-negation-output.XXXXXX")"
kernel_adapter_fixture="$(mktemp -d "${TMPDIR:-/tmp}/sb-kernel-adapter.XXXXXX")"
manager_data_fixture="$(mktemp -d "${TMPDIR:-/tmp}/sb-manager-data.XXXXXX")"
trap 'rm -f -- "$managed_step_fixture" "$managed_step_output" "$shell_target_fixture" "$shell_target_output" "$convention_fixture" "$convention_output" "$negation_fixture" "$negation_output"; rm -rf -- "$kernel_adapter_fixture" "$manager_data_fixture"' EXIT
# 读取内核配置必须经 src/05-kernel.sh 的适配层，其它模块不得直接调用内核。
# 上游在小版本之间修改配置规范时，只应改适配层一处，而不是逐个模块跟进。
# 说明：tests/ 下的直接调用是有意的，那里测的就是内核自身的行为。
# 覆盖四类内核命令：配置读取、配置校验、密钥生成（应完全脱离内核）、
# 以及服务控制、版本解析与规则集编译。
# 注意不要误伤 Nfuse：它的版本查询与代理内核无关，刻意不纳入适配层。
kernel_adapter_violations() {
  grep -REn --include='*.sh' \
    '"\$SINGBOX_BIN" format|sing-box format|check -c|generate rand|rule-set (compile|decompile)|systemctl [a-z-]+ "\$(SINGBOX|MIHOMO)_SERVICE"|(version|-v) 2>/dev/null \| awk .NR==1|"\$MIHOMO_BIN" |mihomo -[tv]|-t -d ' \
    "$1" | grep -v '/05-kernel\.sh:' | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
if [[ -n "$(kernel_adapter_violations src)" ]]; then
  kernel_adapter_violations src >&2
  echo 'kernel invocations (config/check/service/version/rule-set) must go through src/05-kernel.sh; key generation must use generate_random_base64' >&2
  exit 1
fi
# 反面样本：确认该门禁在有人绕过适配层时确实会失败，而不是恒真断言。
for kernel_adapter_bypass in '"$SINGBOX_BIN" format -c "$SINGBOX_CONFIG"' '"$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"' '/usr/local/bin/sing-box check -c /etc/sing-box/config.json' '/usr/local/bin/sing-box format -c /etc/sing-box/config.json' '"$SINGBOX_BIN" generate rand --base64 32' '"$1" rule-set compile --output "$2" "$3"' 'systemctl restart "$SINGBOX_SERVICE"' '"$1" version 2>/dev/null | awk '"'"'NR==1 {print $3}'"'"'' '"$MIHOMO_BIN" -t -f "$MIHOMO_CONFIG"' '/usr/local/bin/mihomo -t -d /var/lib/mihomo -f /etc/mihomo/config.json' 'systemctl restart "$MIHOMO_SERVICE"' '"$1" -v 2>/dev/null | awk '"'"'NR==1 {print $3}'"'"''; do
  printf 'x() {\n  %s\n}\n' "$kernel_adapter_bypass" > "$kernel_adapter_fixture/90-bypass.sh"
  if [[ -z "$(kernel_adapter_violations "$kernel_adapter_fixture")" ]]; then
    printf 'kernel adapter check must reject a direct kernel invocation outside the adapter: %s\n' "$kernel_adapter_bypass" >&2
    exit 1
  fi
done
rm -f -- "$kernel_adapter_fixture/90-bypass.sh"

# 适配层里凡是提到某个内核的函数，都必须同时提到另一个内核：
# 只实现一个内核而让另一个悄悄走同一条路，产生的是坏数据而不是错误。
# 尚未实现的操作也要写出该内核的分支并在其中明确报错。
if ! python3 tests/check-kernel-dispatch.py src/05-kernel.sh; then
  echo 'every kernel adapter function naming one proxy kernel must also handle the other' >&2
  exit 1
fi
# 反面样本：只实现 sing-box 的适配层函数必须被拒绝。
{
  cat src/05-kernel.sh
  printf '\nkernel_only_singbox_probe() {\n  case "$PROXY_KERNEL" in\n    singbox) "$SINGBOX_BIN" whatever ;;\n  esac\n}\n'
} > "$kernel_adapter_fixture/05-kernel-probe.sh"
if python3 tests/check-kernel-dispatch.py "$kernel_adapter_fixture/05-kernel-probe.sh" >/dev/null; then
  echo 'kernel dispatch check must reject an adapter function that implements only one kernel' >&2
  exit 1
fi
rm -f -- "$kernel_adapter_fixture/05-kernel-probe.sh"

# 管理器自身的数据（用户资料、内部备份、AnyTLS 证书）只能经 MANAGER_DATA_DIR
# 派生的变量取得，不得在 src/ 里写死 /etc/sing-box 下的路径。
# 写死一处，将来把这些数据搬出 sing-box 目录时就会漏掉一处，而漏掉的那处
# 指向的正是用户数据（公开 Issue #172）。这条规则刻意不管 config.json——
# 那是 sing-box 自己的文件，不是管理器的。
manager_data_path_literals() {
  grep -rn '/etc/sing-box/\(managed-users\.json\|backups\|cert\)' "$1" |
    grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}
if [[ -n "$(manager_data_path_literals src)" ]]; then
  manager_data_path_literals src >&2
  echo 'manager data paths must derive from MANAGER_DATA_DIR, not hardcode /etc/sing-box' >&2
  exit 1
fi
# 反面样本：三类路径各写回一处都必须被拒绝，否则这条门禁只是看起来在。
for manager_data_literal in \
  'state="/etc/sing-box/managed-users.json"' \
  'backups="/etc/sing-box/backups"' \
  'cert="/etc/sing-box/cert/anytls.crt"'; do
  printf 'x() {\n  %s\n}\n' "$manager_data_literal" > "$manager_data_fixture/90-literal.sh"
  if [[ -z "$(manager_data_path_literals "$manager_data_fixture")" ]]; then
    printf 'manager data path check must reject a hardcoded literal: %s\n' "$manager_data_literal" >&2
    exit 1
  fi
done
rm -f -- "$manager_data_fixture/90-literal.sh"
# 对照：sing-box 自己的配置路径不受这条规则约束，写死它不应变红。
printf 'x() {\n  config="/etc/sing-box/config.json"\n}\n' > "$manager_data_fixture/91-config.sh"
if [[ -n "$(manager_data_path_literals "$manager_data_fixture")" ]]; then
  echo 'manager data path check must not flag the sing-box kernel config path' >&2
  exit 1
fi
rm -f -- "$manager_data_fixture/91-config.sh"

# 使用者的分流规则目录只能经 MIHOMO_RULES_DIR 取得。它必须与 mihomo 单元里
# SAFE_PATHS 的第二条一字不差，写死两处之后改一处就是「配置根本加载不了」，
# 而 mihomo 给出的错误信息不会提到是哪一边不对（公开 Issue #186）。
mihomo_rules_dir_literals() {
  grep -rn '/etc/mihomo/rules' "$1" |
    grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}
if [[ -n "$(mihomo_rules_dir_literals src)" ]]; then
  mihomo_rules_dir_literals src >&2
  echo 'the split rule directory must derive from MIHOMO_RULES_DIR, not be hardcoded' >&2
  exit 1
fi
printf 'x() {\n  rules="/etc/mihomo/rules/mine.yaml"\n}\n' > "$manager_data_fixture/92-rules.sh"
if [[ -z "$(mihomo_rules_dir_literals "$manager_data_fixture")" ]]; then
  echo 'the rule directory check must reject a hardcoded literal' >&2
  exit 1
fi
rm -f -- "$manager_data_fixture/92-rules.sh"
# 对照：mihomo 自己的配置路径不受这条规则约束。
printf 'x() {\n  config="/etc/mihomo/config.json"\n}\n' > "$manager_data_fixture/93-config.sh"
if [[ -n "$(mihomo_rules_dir_literals "$manager_data_fixture")" ]]; then
  echo 'the rule directory check must not flag the mihomo kernel config path' >&2
  exit 1
fi
rm -f -- "$manager_data_fixture/93-config.sh"

# 诊断模块不得直接读 sing-box 专有的配置形状。审计要问运行配置的问题都已经
# 抽成按内核分派的取值函数与判断函数；在这里直接写 .inbounds / .outbounds /
# .route. 就意味着又长出一条只对一个内核成立的路径，而它在另一个内核上不会
# 报错，只会静静地什么都查不到——2e 之前那条「尚未支持」的守卫正是为了挡住
# 这种情况才存在的，守卫撤掉之后需要这条门禁接上。
singbox_shape_in_diagnostics() {
  grep -n '\.route\.\|\.inbounds\|\.outbounds' src/60-operations-diagnostics.sh |
    grep -v '^[0-9]*:[[:space:]]*#' || true
}
if [[ -n "$(singbox_shape_in_diagnostics)" ]]; then
  singbox_shape_in_diagnostics >&2
  echo 'diagnostics must reach the running config through the kernel-dispatched helpers' >&2
  exit 1
fi

# SAFE_PATHS 只能由 mihomo_safe_paths 给出。单元里写一份、配置校验里再写一份，
# 两边一旦不一致就会出现「管理器说配置不可用、服务其实跑得起来」这种自相矛盾的
# 失败——2d 实测撞到过一次，当时校验那一侧根本没设这个环境变量。
safe_paths_outside_single_source() {
  grep -rn 'SAFE_PATHS' src |
    grep -v 'mihomo_safe_paths' |
    grep -v 'Environment=SAFE_PATHS=\$safe_paths' |
    grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}
if [[ -n "$(safe_paths_outside_single_source)" ]]; then
  safe_paths_outside_single_source >&2
  echo 'SAFE_PATHS must come from mihomo_safe_paths only' >&2
  exit 1
fi

# mihomo 的路由规则是字符串，拼错一个字符就是另一条规则。因此规则语法只许
# 出现在适配层的渲染函数里；分流模块与界面模块里不得自己拼 RULE-SET / IN-NAME
# / SUB-RULE。散着写第二处，两处迟早只改一处，而 mihomo 只会说「规则类型不支持」。
mihomo_rule_syntax_outside_adapter() {
  grep -rn '"\(RULE-SET\|IN-NAME\|SUB-RULE\),' src/40-split-runtime.sh src/70-split-prompts.sh \
    src/60-operations-diagnostics.sh src/30-user-runtime.sh 2>/dev/null || true
}
if [[ -n "$(mihomo_rule_syntax_outside_adapter)" ]]; then
  mihomo_rule_syntax_outside_adapter >&2
  echo 'mihomo rule syntax must only be produced by kernel_render_split_plan' >&2
  exit 1
fi

# 派发条目必须真的指向那个托管 sub-rule。这两个常量分开写，拼不上时
# mihomo 会拒绝加载整份配置——机器停在起不来的状态上。
dispatch_rule="$(sed -n 's/^MIHOMO_SPLIT_DISPATCH_RULE="\(.*\)"$/\1/p' src/05-kernel.sh)"
if [[ "$dispatch_rule" != *',${MIHOMO_MANAGED_SUB_RULE}' ]]; then
  printf 'the mihomo dispatch rule must end with the managed sub-rule name: %s\n' "$dispatch_rule" >&2
  exit 1
fi
if [[ "$dispatch_rule" != SUB-RULE,\(*\),* ]]; then
  printf 'the mihomo dispatch rule must be a SUB-RULE with a parenthesised condition: %s\n' "$dispatch_rule" >&2
  exit 1
fi

# GitHub 的 API 查询与资产下载必须经 github_api_get / github_download_to，
# 不得在调用点各写一份 curl。散落时一旦要调整重试或超时策略就得逐处跟进，
# Issue #140 正是因此漏掉了 TLS 瞬时失败的重试。
github_call_violations() {
  grep -REn --include='*.sh' "application/vnd\\.github\\+json|--max-time 300" "$1" \
    | grep -v 'github_api_get\|github_download_to' || true
}
github_helper_hits="$(grep -REn --include='*.sh' 'application/vnd\.github\+json' src | wc -l | tr -d ' ')"
if [[ "$github_helper_hits" != 1 ]]; then
  echo 'GitHub API 请求头只应出现在 github_api_get 中' >&2
  grep -REn --include='*.sh' 'application/vnd\.github\+json' src >&2
  exit 1
fi
if ! grep -Fq -- '--retry-all-errors' <<<"$(sed -n '/^github_api_get() {/,/^}$/p' src/50-install-update.sh)"; then
  echo 'github_api_get must retry transient TLS failures' >&2
  exit 1
fi
if ! grep -Fq -- '--retry-all-errors' <<<"$(sed -n '/^github_download_to() {/,/^}$/p' src/50-install-update.sh)"; then
  echo 'github_download_to must retry transient TLS failures' >&2
  exit 1
fi
# 更一般的约定：凡是带 --retry 的 curl 都必须同时带 --retry-all-errors。
# curl 的 --retry 不覆盖 TLS 握手失败，只写 --retry 会给人「已经重试过」的错觉。
# 这条同时覆盖验收工具，Issue #140 的修复当初只改了 src/ 就漏掉了它。
# 排除本文件：它按设计存放反面样本，其中就有一条故意只写 --retry 的 curl。
retry_without_all_errors() {
  grep -REn --include='*.sh' --exclude='test-static.sh' -- '--retry [0-9]' "$@" \
    | grep -v -- '--retry-all-errors' || true
}
if [[ -n "$(retry_without_all_errors src tests tools)" ]]; then
  retry_without_all_errors src tests tools >&2
  echo 'curl --retry must be paired with --retry-all-errors; --retry alone does not cover TLS handshake failures' >&2
  exit 1
fi
printf 'x() {\n  curl -fsSL --retry 3 "$1"\n}\n' > "$kernel_adapter_fixture/91-retry.sh"
if [[ -z "$(retry_without_all_errors "$kernel_adapter_fixture")" ]]; then
  echo 'retry pairing check must reject a bare --retry' >&2
  exit 1
fi
rm -f -- "$kernel_adapter_fixture/91-retry.sh"

sed '/^download_singbox_binary() {/,/^}$/ {
  /LATEST_KERNEL_URL/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded download command' >&2
  exit 1
fi
grep -Fq 'managed function download_singbox_binary has an unguarded command' "$managed_step_output"

# 同一条负面样本对 mihomo 分支再做一次。两个内核各有一份下载与单元写入实现，
# 只验证其中一份等于把另一份留在安全网之外——第一步的教训正是
# 「给操作换个名字就可能绕过按名字工作的检查器」。
sed '/^download_mihomo_binary() {/,/^}$/ {
  /gzip -dc/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded mihomo download command' >&2
  exit 1
fi
grep -Fq 'managed function download_mihomo_binary has an unguarded command' "$managed_step_output"

sed '/^write_kernel_unit() {/,/^}$/ {
  /write_singbox_unit || return 1/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded mutation helper' >&2
  exit 1
fi
grep -Fq 'managed function write_kernel_unit has an unguarded command' "$managed_step_output"

sed '/^write_kernel_unit() {/,/^}$/ {
  /write_mihomo_unit || return 1/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded mihomo mutation helper' >&2
  exit 1
fi
grep -Fq 'managed function write_kernel_unit has an unguarded command' "$managed_step_output"

cp sb-user-manager.sh "$managed_step_fixture"
printf '\nunclassified_managed_step() {\n  :\n}\nmanaged_step_manifest_fixture() {\n  run_managed_step unclassified_managed_step\n}\n' >> "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unclassified managed function' >&2
  exit 1
fi
grep -Fq 'managed shell-function targets changed' "$managed_step_output"

cp sb-user-manager.sh "$shell_target_fixture"
printf '\nstatic_gate_negative_fixture() {\n  undefined_static_probe\n  if undefined_condition_probe; then :; fi\n  value="$(undefined_substitution_probe)"\n  printf x | undefined_pipeline_probe\n}\n' >> "$shell_target_fixture"
printf '\nstatic_dispatch_gate_negative_fixture() {\n  run_step_or_rollback undefined_rollback_dispatch_probe undefined_step_dispatch_probe\n  run_managed_step undefined_managed_dispatch_probe\n  run_managed_step run_quietly undefined_nested_dispatch_probe\n  run_managed_step "undefined_quoted_dispatch_probe"\n  run_quietly undefined_quiet_dispatch_probe\n  write_command_output output undefined_output_dispatch_probe\n  validate_without_exit undefined_validator_dispatch_probe value\n  read_validated_value prompt default cancel undefined_read_validator_dispatch_probe\n  prompt_user_status_action undefined_status_action_dispatch_probe active label\n  dynamic_dispatch_target=undefined_dynamic_dispatch_probe\n  run_managed_step "$dynamic_dispatch_target"\n}\n' >> "$shell_target_fixture"
if python3 tests/check-shell-call-targets.py "$shell_target_fixture" >"$shell_target_output" 2>&1; then
  echo 'shell call-target check must reject an undefined bare command' >&2
  exit 1
fi
grep -Fq 'undefined bare command target undefined_static_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_condition_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_substitution_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_pipeline_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_rollback_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_step_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_managed_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_nested_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_quoted_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_quiet_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_output_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_validator_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_read_validator_dispatch_probe' "$shell_target_output"
grep -Fq 'undefined bare command target undefined_status_action_dispatch_probe' "$shell_target_output"
if grep -Fq 'undefined_dynamic_dispatch_probe' "$shell_target_output"; then
  echo 'shell call-target check must skip dynamically expanded dispatch targets' >&2
  exit 1
fi

# 分词器读不懂的写法必须当场变红。原先的做法是把该处到文件末尾的全部内容当成一团
# 不透明内容咽下去、退出码 0，于是该位置之后的所有静态约定都不再生效而无人知晓
# （公开 Issue #102）。这里用一个没闭合的引号做反向样例。
printf '#!/usr/bin/env bash\nstatic_tokenizer_giveup_fixture() {\n  local probe="缺一个右引号\n}\n' \
  > "$convention_fixture"
if python3 tests/check-shell-call-targets.py "$convention_fixture" >"$convention_output" 2>&1; then
  echo 'shell call-target check must reject input its tokenizer cannot parse' >&2
  exit 1
fi
grep -Fq 'tokenizer gave up' "$convention_output"

# `$( )` 里的双引号串再套 `$(( ))` 是合法且实际用得到的写法，必须能解析：此前分词器会
# 在算术展开的 `))` 处提前给命令替换收尾，并把之后的内容全部作废。探针放在这一行之后，
# 报不出探针就说明检查在那里停了。
cp sb-user-manager.sh "$convention_fixture"
cat >> "$convention_fixture" <<'EOF'

static_nested_arithmetic_fixture() {
  local total=3 done_count=1 problems='[]'
  problems="$(jq -c --arg m "共 ${total} 项，其中 $((total - done_count)) 项待处理" \
    '. += [$m]' <<<"$problems")"
  undefined_after_nested_arithmetic_probe
}
EOF
if python3 tests/check-shell-call-targets.py "$convention_fixture" >"$convention_output" 2>&1; then
  echo 'shell call-target check must still report an undefined target after a nested expansion' >&2
  exit 1
fi
grep -Fq 'undefined bare command target undefined_after_nested_arithmetic_probe' "$convention_output"
if grep -Fq 'tokenizer gave up' "$convention_output"; then
  cat "$convention_output" >&2
  echo 'the tokenizer must parse an arithmetic expansion nested in a quoted command substitution' >&2
  exit 1
fi

# 覆盖率实测：除了分词器自己承认的放弃点，还可能有别的机制（例如 heredoc 屏蔽误判）
# 让检查悄悄跳过文件中段，那种情况不会走到放弃出口。在管理脚本的多个位置各插一个
# 未定义命令探针，每个都必须被报出来。
coverage_probe_program='
import pathlib, re, subprocess, sys

fixture = sys.argv[1]
lines = pathlib.Path("sb-user-manager.sh").read_text(encoding="utf-8").splitlines(keepends=True)
spots = [n for n, line in enumerate(lines) if re.match(r"^[a-z_][a-z0-9_]*\(\) \{$", line)]
if len(spots) < 20:
    print("could not locate enough top-level function definitions to probe")
    raise SystemExit(1)
missed = []
for fraction in (0.02, 0.35, 0.65, 0.95):
    at = spots[int(len(spots) * fraction)]
    probed = list(lines)
    probed.insert(at, "static_coverage_probe_fixture() {\n  undefined_coverage_probe\n}\n\n")
    pathlib.Path(fixture).write_text("".join(probed), encoding="utf-8")
    if subprocess.run(["bash", "-n", fixture]).returncode != 0:
        print(f"the probe inserted before line {at + 1} did not produce valid shell; pick another spot")
        raise SystemExit(1)
    result = subprocess.run(
        [sys.executable, "tests/check-shell-call-targets.py", fixture],
        capture_output=True,
        text=True,
    )
    if "undefined_coverage_probe" not in result.stdout + result.stderr:
        missed.append(at + 1)
if missed:
    print("static checks no longer cover the manager around line(s) "
          + ", ".join(str(line) for line in missed))
    raise SystemExit(1)
'
if ! python3 -c "$coverage_probe_program" "$convention_fixture" >"$convention_output" 2>&1; then
  cat "$convention_output" >&2
  echo 'the shell call-target check must cover the whole manager, not only its opening lines' >&2
  exit 1
fi

# 调用约定的反向样例：每条约定都要能在故意写错的样例上报出来。
cat > "$convention_fixture" <<'EOF'
read_menu_choice() { :; }
read_numbered_index() { :; }
run_quietly() { "$@" >/dev/null; }

static_prompt_convention_negative_fixture() {
  read_numbered_index '请选择编号：' 3
  read_menu_choice '请选择：' '0,1' '' '请输入 1 或 0'
}

static_status_convention_negative_fixture() {
  local probe_rc
  if run_quietly true; then return 0; fi
  probe_rc=$?
  return "$probe_rc"
}

static_secret_convention_negative_fixture() {
  qrencode -t ANSIUTF8 -l L -m 1 -- "$1"
}

static_radix_convention_negative_fixture() {
  local radix_probe
  read -r -p '请选择：' radix_probe
  [[ "$radix_probe" =~ ^[0-9]+$ ]] || return 1
  ((radix_probe == 0)) && return 1
  return 0
}
EOF
if python3 tests/check-shell-call-targets.py "$convention_fixture" >"$convention_output" 2>&1; then
  echo 'shell convention check must reject the negative fixture' >&2
  exit 1
fi
grep -Fq 'unchecked cancellable prompt read_numbered_index' "$convention_output"
grep -Fq 'unchecked cancellable prompt read_menu_choice' "$convention_output"
grep -Fq 'exit status read into probe_rc after an if without else' "$convention_output"
grep -Fq 'payload passed to qrencode as an argument' "$convention_output"
grep -Fq 'prompt value radix_probe used without 10#' "$convention_output"

# 同一批约定的正向样例：项目里已确立的写法不得被误报。
cat > "$convention_fixture" <<'EOF'
read_menu_choice() { :; }
read_numbered_index() { :; }
run_quietly() { "$@" >/dev/null; }

static_prompt_convention_positive_fixture() {
  read_numbered_index '请选择编号：' 3 || return 1
  if ! read_menu_choice '请选择：' '0,1' '' '请输入 1 或 0'; then return 1; fi
}

static_status_convention_positive_fixture() {
  local probe_rc
  if run_quietly true; then
    return 0
  else
    probe_rc=$?
  fi
  return "$probe_rc"
}

static_secret_convention_positive_fixture() {
  printf '%s' "$1" | qrencode -t ANSIUTF8 -l L -m 1
}

static_radix_convention_positive_fixture() {
  local radix_probe
  read -r -p '请选择：' radix_probe
  [[ "$radix_probe" =~ ^[0-9]+$ ]] || return 1
  radix_probe=$((10#$radix_probe))
  ((radix_probe == 0)) && return 1
  return 0
}
EOF
if ! python3 tests/check-shell-call-targets.py "$convention_fixture" >"$convention_output" 2>&1; then
  cat "$convention_output" >&2
  echo 'shell convention check must accept the established writing' >&2
  exit 1
fi

# 需要已部署环境的入口必须先过 ensure_management_environment_ready 护栏，
# 否则未部署的服务器会直接撞上 prepare_core 里的 die。
function_contains_program='
  $0 == function_name "() {" {inside=1}
  inside && index($0, needle) {found=1}
  inside && /^}/ {exit}
  END {exit(found ? 0 : 1)}
'
for guarded_entry in user_management_menu split_management_menu migration_backup_menu \
  global_sni_menu prompt_consistency; do
  if ! awk -v function_name="$guarded_entry" -v needle='ensure_management_environment_ready' \
      "$function_contains_program" sb-user-manager.sh; then
    echo "$guarded_entry must refuse to run before the management environment is deployed" >&2
    exit 1
  fi
done
sed '/^user_management_menu() {$/,/^}$/ {
  /ensure_management_environment_ready || return 0/ d
}' sb-user-manager.sh > "$convention_fixture"
if awk -v function_name=user_management_menu -v needle='ensure_management_environment_ready' \
    "$function_contains_program" "$convention_fixture"; then
  echo 'management environment guard check must reject an unguarded menu' >&2
  exit 1
fi

# 保留现有部署的流程不得把测试通道静默换成正式版；check_updates 已经给出正确写法。
preview_channel_program='
  /^[[:alpha:]_][[:alnum:]_]*\(\) \{$/ {
    current=$0
    sub(/\(\) \{$/, "", current)
    start=FNR
    preserving=0
    channel=0
    next
  }
  current != "" && /^}$/ {
    if (preserving && !channel) {
      printf "%s:%d: %s 保留现有部署时必须先判断 sing-box 通道\n", FILENAME, start, current > "/dev/stderr"
      failed=1
    }
    current=""
    next
  }
  current != "" {
    if ($0 ~ /deploy_environment[[:space:]]+false([[:space:]]|$)/) preserving=1
    if ($0 ~ /current_singbox_channel/) channel=1
  }
  END {exit failed ? 1 : 0}
'
if ! awk "$preview_channel_program" sb-user-manager.sh; then
  echo 'flows that keep the existing deployment must reuse the check_updates preview-channel guard' >&2
  exit 1
fi
sed '/^check_updates() {$/,/^}$/ {
  /current_channel="$(current_singbox_channel)"/ d
}' sb-user-manager.sh > "$convention_fixture"
if awk "$preview_channel_program" "$convention_fixture" 2>/dev/null; then
  echo 'preview-channel check must reject a repair flow that ignores the current channel' >&2
  exit 1
fi

# 可选文本字段：本项目把「空字符串」和「字段不存在」当成同一件事，
# 只能用 (.field // "") 判空；(.field // null) 会把已保存的空串判成有值。
#
# 唯一例外是结构校验器：它的职责是区分良构与畸形输入，因此有意把空串与缺省
# 分开对待（空串由启动期清洗负责归一，校验器充当哨兵）。这类行必须带
# `static-allow: strict-empty-check` 标记显式声明，本检查跳过它们。
optional_text_null_pattern='\.(outbound_preset|rule_preset|runtime_rule_tag|runtime_outbound_tag|runtime_transport_tag)[[:space:]]*//[[:space:]]*null'
if grep -En "$optional_text_null_pattern" sb-user-manager.sh | grep -Fv 'static-allow: strict-empty-check'; then
  echo 'optional text fields must be emptiness-checked with (.field // "") instead of (.field // null)' >&2
  exit 1
fi
printf 'static_optional_text_negative_fixture() {\n  jq -e '\''(.rule_preset // null) == null'\'' "$STATE_FILE"\n}\n' \
  > "$convention_fixture"
if ! grep -En "$optional_text_null_pattern" "$convention_fixture" | grep -Fqv 'static-allow: strict-empty-check'; then
  echo 'optional text emptiness check must reject a (.field // null) probe' >&2
  exit 1
fi
printf 'static_optional_text_allowed_fixture() {\n  jq -e '\''(.rule_preset // null) == null'\'' "$STATE_FILE" # static-allow: strict-empty-check\n}\n' \
  > "$convention_fixture"
if grep -En "$optional_text_null_pattern" "$convention_fixture" | grep -Fv 'static-allow: strict-empty-check'; then
  echo 'optional text emptiness check must honour an explicit strict-empty-check allowance' >&2
  exit 1
fi

# 测试断言不得依赖裸 `!`：命令返回值被 ! 取反时 set -e 不会因它失败而退出，
# 断言命中缺陷也不会让测试变红。条件上下文里的 ! 合法，检查器会放行。
if ! bash tests/check-bare-negation.sh tests/*.sh >"$negation_output" 2>&1; then
  cat "$negation_output" >&2
  echo 'test assertions must not rely on a bare `!` command; use `if cmd; then echo ...; exit 1; fi`' >&2
  exit 1
fi
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' "! grep -Fq 'x' /dev/null" 'echo done' \
  > "$negation_fixture"
if bash tests/check-bare-negation.sh "$negation_fixture" >/dev/null 2>&1; then
  echo 'bare negation check must reject a standalone `! cmd` assertion' >&2
  exit 1
fi
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
  "if ! grep -Fq 'x' /dev/null; then" '  exit 1' 'fi' \
  "while ! grep -Fq 'y' /dev/null; do" '  break' 'done' \
  'if [[ ! -f /dev/null ]]; then' '  exit 1' 'fi' \
  > "$negation_fixture"
if ! bash tests/check-bare-negation.sh "$negation_fixture" >/dev/null 2>&1; then
  echo 'bare negation check must allow `!` inside a conditional' >&2
  exit 1
fi

rm -f -- "$managed_step_fixture" "$managed_step_output" "$shell_target_fixture" "$shell_target_output"
rm -f -- "$convention_fixture" "$convention_output" "$negation_fixture" "$negation_output"
trap - EXIT

version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' sb-user-manager.sh | head -n1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
grep -Fq "## $version " CHANGELOG.md
grep -Fxq 'SCRIPT_EDITION_LABEL="公开版"' sb-user-manager.sh
grep -Fq 'PORT_MIN=20001' sb-user-manager.sh
grep -Fq 'PORT_MAX=30000' sb-user-manager.sh
grep -Fq 'MANAGER_REPOSITORY="Cr0ce11/sb-user-manager-public"' sb-user-manager.sh
grep -Fq 'SINGBOX_REPOSITORY="SagerNet/sing-box"' sb-user-manager.sh
grep -Fq 'validate_runtime_config_file()' sb-user-manager.sh
grep -Fq 'parse_runtime_config()' sb-user-manager.sh
grep -Fq 'run_standalone_interactive_startup()' sb-user-manager.sh
grep -Fq 'run_standalone_internal_expire()' sb-user-manager.sh
grep -Fq '"") run_standalone_interactive_startup "${@:2}" ;;' sb-user-manager.sh
grep -Fq -- '--internal-expire) run_standalone_internal_expire "${@:2}" ;;' sb-user-manager.sh
grep -Fq -- '--take-over-installed-manager) take_over_installed_manager "${@:2}" ;;' sb-user-manager.sh
grep -Fq 'MIN_SUPPORTED_STATE_SCHEMA_VERSION=0' sb-user-manager.sh
grep -Fq 'recover_manager_handoff || die' sb-user-manager.sh
grep -Fq 'exec "$recovered_installed" "$@"' sb-user-manager.sh
[[ "$(grep -Fc '# >>> manager_channel_handoff' src/50-install-update.sh)" == 1 ]]
[[ "$(grep -Fc '# <<< manager_channel_handoff' src/50-install-update.sh)" == 1 ]]
grep -Fq 'sb-user-manager-landing-agent|sb-user-manager-landing-apply)' sb-user-manager.sh
grep -Fq 'v5 入口与落地能力已经退役，拒绝运行遗留 helper 入口' sb-user-manager.sh
if grep -Eq 'CONTROLLER_STATE_SCHEMA_VERSION|CONTROLLER_ROLE_LAST_STATUS|controller_role_preflight|detect_manager_role|controller_(apply|register|onboard)_landing|LANDING_APPLY_SCHEMA_VERSION|landing_(agent|apply_helper)_main|install_landing_restricted_channel|LANDING_STARTUP_RECOVERY_UNIT_NAME' \
    sb-user-manager.sh src/*.sh; then
  echo 'retired v5 executable implementation remains in the manager' >&2
  exit 1
fi
grep -Fq 'harden_existing_environment_backups()' sb-user-manager.sh
grep -Fq 'if ! harden_existing_environment_backups; then' sb-user-manager.sh
grep -Fq 'migrate_legacy_ss2022_udp_inbounds()' sb-user-manager.sh
grep -Fq 'if ! migrate_legacy_ss2022_udp_inbounds; then' sb-user-manager.sh
grep -Fq 'run_managed_step rebuild_all_split_configs' sb-user-manager.sh
grep -Fq 'make_ss2022_inbound()' sb-user-manager.sh
grep -Fq 'transport:"direct"' sb-user-manager.sh
# sing-box 的 SS2022 + ShadowTLS 需要一个单独承载 UDP 的入站；mihomo 一个监听器
# 同时承载 TCP 与 UDP，靠 "udp":true（实测确认，公开 Issue #180）。两条各盯一个内核，
# 漏掉任一侧的 UDP 都会变红。生成的形状本身由单元测试逐字段断言。
grep -Fq '"tag":("ss-udp-" + $name)' sb-user-manager.sh
grep -Fq '"cipher":$method,"password":$ENV.SB_JQ_SS_PASSWORD,"udp":true' sb-user-manager.sh
# ShadowTLS 严格模式在 mihomo 侧的键名是 strict-mode，不是 strictmode：监听器配置
# 走 inbound 结构体标签而不是 yaml 标签（公开 Issue #154 的更正）。写错会被静默丢弃，
# 严格模式悄悄关闭，而配置测试与启动日志都不会有任何提示。
grep -Fq '"strict-mode":$strict' sb-user-manager.sh
# 只盯键的写法（带引号或 jq 的裸键），不然解释这件事的注释自己会把门禁弄红。
strictmode_key_typos() {
  grep -En '"strictmode"|[^a-z-]strictmode:' "$1" || true
}
if [[ -n "$(strictmode_key_typos sb-user-manager.sh)" ]]; then
  strictmode_key_typos sb-user-manager.sh >&2
  echo 'mihomo ShadowTLS strict mode key is strict-mode; strictmode is silently dropped' >&2
  exit 1
fi
# 反面样本：两种写错的形态都必须被抓到，同时确认正确写法与解释它的注释不会误伤。
printf 'x() {\n  jq -n %s{"shadow-tls":{"strictmode":$s}}%s\n}\n' "'" "'" > "$manager_data_fixture/92-strictmode.sh"
if [[ -z "$(strictmode_key_typos "$manager_data_fixture/92-strictmode.sh")" ]]; then
  echo 'strict mode key check must reject a quoted strictmode key' >&2
  exit 1
fi
printf 'x() {\n  jq -n %s{shadow-tls:{strictmode:$s}}%s\n}\n' "'" "'" > "$manager_data_fixture/92-strictmode.sh"
if [[ -z "$(strictmode_key_typos "$manager_data_fixture/92-strictmode.sh")" ]]; then
  echo 'strict mode key check must reject a bare strictmode key' >&2
  exit 1
fi
printf '# 键名是 strict-mode 不是 strictmode，写错会被静默丢弃\nx() {\n  jq -n %s{"strict-mode":$s}%s\n}\n' "'" "'" \
  > "$manager_data_fixture/92-strictmode.sh"
if [[ -n "$(strictmode_key_typos "$manager_data_fixture/92-strictmode.sh")" ]]; then
  echo 'strict mode key check must not flag the correct key or the comment explaining it' >&2
  exit 1
fi
rm -f -- "$manager_data_fixture/92-strictmode.sh"
# 握手目标的 TLS 1.3 预检必须走适用条件（公开 Issue #194）。绕过
# shadowtls_handshake_probe_applies 直接探，会在 sing-box 机器上、严格模式关着时、
# 或者根本没有旧版 ShadowTLS 用户的机器上凭空多出一次网络请求和一条没人要处理的
# 提示——那正是「狼来了」的做法。
unguarded_handshake_probes() {
  awk '
    /shadowtls_handshake_probe_applies/ { guarded = NR }
    /\$\(probe_handshake_tls13 / { if (guarded == 0 || NR - guarded > 8) print FILENAME ":" NR ": " $0 }
  ' "$1"
}
if [[ -n "$(unguarded_handshake_probes sb-user-manager.sh)" ]]; then
  unguarded_handshake_probes sb-user-manager.sh >&2
  echo 'handshake TLS 1.3 probe must be guarded by shadowtls_handshake_probe_applies' >&2
  exit 1
fi
# 反面样本：不带守卫的探测必须被抓到，带守卫的不得误伤。
printf 'x() {\n  status="$(probe_handshake_tls13 "$sni" 443)"\n}\n' > "$manager_data_fixture/93-probe.sh"
if [[ -z "$(unguarded_handshake_probes "$manager_data_fixture/93-probe.sh")" ]]; then
  echo 'probe guard check must reject an unguarded probe call' >&2
  exit 1
fi
printf 'x() {\n  if shadowtls_handshake_probe_applies; then\n    status="$(probe_handshake_tls13 "$sni" 443)"\n  fi\n}\n' \
  > "$manager_data_fixture/93-probe.sh"
if [[ -n "$(unguarded_handshake_probes "$manager_data_fixture/93-probe.sh")" ]]; then
  echo 'probe guard check must not flag a guarded probe call' >&2
  exit 1
fi
rm -f -- "$manager_data_fixture/93-probe.sh"
# 网络探测只能有这一处实现：第二处 openssl s_client 会带来第二套判定与第二套超时。
[[ "$(grep -Fc 'openssl s_client' sb-user-manager.sh)" == 2 ]] || {
  echo 'openssl s_client must appear only inside probe_handshake_tls13 (timeout 与无 timeout 两支)' >&2
  exit 1
}
grep -Fq 'shadow-tls-version=3, udp-relay=true' sb-user-manager.sh
grep -Fq 'shadowrocket_anytls_url()' sb-user-manager.sh
grep -Fq 'shadowrocket_ss2022_url()' sb-user-manager.sh
grep -Fq 'shadowrocket_ss2022_direct_url()' sb-user-manager.sh
grep -Fq 'printf '"'"'%s'"'"' "$1" | qrencode -t ANSIUTF8 -l L -m 1' sb-user-manager.sh
grep -Fq 'apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar gzip openssl python3 qrencode' sb-user-manager.sh
if grep -Fq "printf '%s=ss,%s,%s,encrypt-method=%s" sb-user-manager.sh || grep -Fq '%s=anytls,%s,%s,password=%s' sb-user-manager.sh; then
  echo 'legacy Shadowrocket text export must not remain in the manager' >&2
  exit 1
fi
if grep -Fq 'source "$CONF_FILE"' sb-user-manager.sh; then
  echo 'runtime config must be parsed as data instead of sourced as root shell code' >&2
  exit 1
fi
if grep -Eq 'runs-on: ubuntu-latest|uses: actions/checkout@v[0-9]+|container: debian:(12-slim|bookworm-slim)' .github/workflows/ci-release.yml; then
  echo 'release workflow contains a floating runner, action or Debian image reference' >&2
  exit 1
fi
[[ "$(grep -Ec '^[[:space:]]+container: debian:bookworm-[0-9]+-slim@sha256:[0-9a-f]{64}$' .github/workflows/ci-release.yml)" == 2 ]]
grep -Fq 'bash tests/test-release-workflow.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-manager-handoff.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-standalone-startup.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-public-readiness.sh' .github/workflows/ci-release.yml
grep -Fq 'debian-standalone-e2e:' .github/workflows/ci-release.yml
grep -Fq 'needs: [validate, jq16-compat, debian-standalone-e2e]' .github/workflows/ci-release.yml
if grep -Fq 'debian-landing-e2e' .github/workflows/ci-release.yml; then
  echo 'retired Debian landing check name remains in the release workflow' >&2
  exit 1
fi
if grep -Eq 'tests/test-(controller|landing|manager-role-detection)|SB_LANDING|openssh-server|NET_ADMIN|--privileged' \
    .github/workflows/ci-release.yml; then
  echo 'retired v5 tests or elevated container capabilities remain in CI' >&2
  exit 1
fi
grep -Fq 'fetch_singbox_channel_releases()' sb-user-manager.sh
grep -Fq 'singbox_release_metadata()' sb-user-manager.sh
grep -Fq 'check_singbox_release_compatibility()' sb-user-manager.sh
grep -Fq 'check_rule_set_with_binary()' sb-user-manager.sh
grep -Fq 'prepare_singbox_release_binary()' sb-user-manager.sh
grep -Fq 'perform_singbox_channel_switch()' sb-user-manager.sh
grep -Fq 'write_singbox_channel_state()' sb-user-manager.sh
grep -Fq 'update_current_singbox_channel()' sb-user-manager.sh
grep -Fq 'singbox_channel_menu()' sb-user-manager.sh
grep -Fq 'system_management_menu()' sb-user-manager.sh
grep -Fq 'deployment_management_menu()' sb-user-manager.sh
grep -Fq "deploy '部署与卸载'" sb-user-manager.sh
grep -Fq "uninstall '完整卸载'" sb-user-manager.sh
grep -Fq 'uninstall_environment()' sb-user-manager.sh
grep -Fq 'uninstall_managed_environment()' sb-user-manager.sh
grep -Fq 'managed_uninstall_paths()' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_complete_uninstall()' sb-user-manager.sh
grep -Fq 'cleanup_internal_material_after_uninstall()' sb-user-manager.sh
grep -Fq '完整卸载需要停止 %s，继续会立即中断当前连接' sb-user-manager.sh
grep -Fq '加密迁移备份已保留在' sb-user-manager.sh
grep -Fq "channel 'sing-box 版本管理'" sb-user-manager.sh
grep -Fq 'audit_consistency()' sb-user-manager.sh
grep -Fq 'is_public_ipv4()' sb-user-manager.sh
grep -Fq 'https://api.ipify.org' sb-user-manager.sh
grep -Fq 'PUBLIC_SERVER_OVERRIDE=""' sb-user-manager.sh
grep -Fq 'repair_consistency()' sb-user-manager.sh
grep -Fq 'rewrite_kernel_config()' sb-user-manager.sh
grep -Fq 'make_user_inbounds_from_state()' sb-user-manager.sh
grep -Fq 'replace_user_inbounds()' sb-user-manager.sh
grep -Fq 'state_replace_user()' sb-user-manager.sh
grep -Fq 'cmd_edit_user()' sb-user-manager.sh
grep -Fq 'prompt_edit_user()' sb-user-manager.sh
grep -Fq 'ensure_global_sni_config()' sb-user-manager.sh
grep -Fq 'cmd_set_global_sni()' sb-user-manager.sh
grep -Fq 'global_sni_menu()' sb-user-manager.sh
grep -Fq 'validate_split_rule_source()' sb-user-manager.sh
grep -Fq 'rebuild_all_split_configs()' sb-user-manager.sh
grep -Fq 'build_split_runtime_plan()' sb-user-manager.sh
grep -Fq 'stable_managed_tag()' sb-user-manager.sh
grep -Fq 'validate_split_relationships()' sb-user-manager.sh
grep -Fq 'migrate_shared_preset_runtime_configs()' sb-user-manager.sh
grep -Fq 'split_preset_fields_are_current()' sb-user-manager.sh
grep -Fq 'state_normalize_split_preset_fields()' sb-user-manager.sh
grep -Fq 'migrate_empty_split_preset_fields()' sb-user-manager.sh
[[ "$(grep -Fc 'migrate_empty_split_preset_fields' sb-user-manager.sh)" == 2 ]]
grep -Fq 'if ! cmd_split_add "$name" "$source" "$scope" "$user" "$upstream" "$outbound_tag" "$rule_preset" "$outbound_preset" "$behavior" "$rule_url"; then' sb-user-manager.sh
grep -Fq '分流没有添加，现有配置没有改变。' sb-user-manager.sh
grep -Fq 'SHARED_PRESET_RUNTIME_MARKER=' sb-user-manager.sh
grep -Fq '同一用户不能让同一条预置规则同时使用两个不同出口' sb-user-manager.sh
if grep -Fq '本分流的出口名称' sb-user-manager.sh; then
  echo 'per-split outbound name prompt must not return after shared preset runtime reuse' >&2
  exit 1
fi
grep -Fq 'cmd_split_show()' sb-user-manager.sh
grep -Fq 'cmd_split_edit()' sb-user-manager.sh
grep -Fq 'cmd_split_move()' sb-user-manager.sh
grep -Fq 'prompt_edit_split()' sb-user-manager.sh
grep -Fq 'prompt_move_split()' sb-user-manager.sh
grep -Fq 'prompt_split_diagnostic()' sb-user-manager.sh
grep -Fq 'cmd_outbound_preset_edit()' sb-user-manager.sh
grep -Fq 'cmd_rule_preset_edit()' sb-user-manager.sh
grep -Fq 'outbound_preset_management_menu()' sb-user-manager.sh
grep -Fq 'rule_preset_management_menu()' sb-user-manager.sh
grep -Fq 'state_remove_outbound_preset()' sb-user-manager.sh
grep -Fq 'state_remove_rule_preset()' sb-user-manager.sh
grep -Fq "ui_section '预置内容（保存后不会自动生效）'" sb-user-manager.sh
grep -Fq 'extract_split_diagnostic_connections()' sb-user-manager.sh
grep -Fq "diagnose '验证分流是否生效'" sb-user-manager.sh
grep -Fq 'create_diagnostic_report()' sb-user-manager.sh
grep -Fq 'redact_diagnostic_file()' sb-user-manager.sh
grep -Fq 'validate_diagnostic_report()' sb-user-manager.sh
grep -Fq 'diagnostic_report_menu()' sb-user-manager.sh
grep -Fq "diagnostics '检查与故障报告'" sb-user-manager.sh
grep -Fq '生成故障诊断报告（只读）' sb-user-manager.sh
grep -Fq '/root/sb-user-manager-diagnostics' sb-user-manager.sh
grep -Fq 'DEFAULT_SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"' sb-user-manager.sh
grep -Fq 'DEFAULT_ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"' sb-user-manager.sh
if grep -Fq 'ShadowTLS SNI（留空使用全局默认 ${SS2022_SHADOWTLS_SNI}；输入 0 返回协议选择）' sb-user-manager.sh; then
  echo 'new SS2022 users must not be prompted for a ShadowTLS SNI' >&2
  exit 1
fi
grep -Fq 'AnyTLS SNI（留空使用全局默认 ${ANYTLS_SNI}；输入 0 返回协议选择）' sb-user-manager.sh
grep -Fq '请选择使用方式 [1]：' sb-user-manager.sh
grep -Fq 'prompt_managed "$protocol" "$method" "$protocol_sni"' sb-user-manager.sh
grep -Fq 'prompt_multi_account managed' sb-user-manager.sh
grep -Fq 'cmd_add_user_endpoint()' sb-user-manager.sh
grep -Fq 'cmd_remove_user_endpoint()' sb-user-manager.sh
grep -Fq 'read_menu_choice()' sb-user-manager.sh
grep -Fq 'read_numbered_index()' sb-user-manager.sh
grep -Fq 'create_migration_backup()' sb-user-manager.sh
grep -Fq '设置迁移密码（至少 8 位；输入 0 取消）' sb-user-manager.sh
grep -Fq 'if ! read_backup_password_twice; then' sb-user-manager.sh
grep -Fq 'restore_migration_backup()' sb-user-manager.sh
grep -Fq 'build_merge_migration_payload()' sb-user-manager.sh
grep -Fq 'select_migration_restore_mode()' sb-user-manager.sh
grep -Fq '合并到这台服务器（推荐；保留已有用户和分流）' sb-user-manager.sh
grep -Fq '确认继续？请输入 ${confirm_token}：' sb-user-manager.sh
grep -Fq 'import_migration_backup()' sb-user-manager.sh
grep -Fq 'preview_migration_backup()' sb-user-manager.sh
grep -Fq 'validate_migration_bundle()' sb-user-manager.sh
grep -Fq 'cleanup_backup_retention()' sb-user-manager.sh
grep -Fq 'write_migration_restore_report()' sb-user-manager.sh
grep -Fq 'verify_migration_auth_file()' sb-user-manager.sh
grep -Fq 'verify_environment_backup()' sb-user-manager.sh
grep -Fq 'restore_environment_backup()' sb-user-manager.sh
grep -Fq 'install_runtime_traps()' sb-user-manager.sh
grep -Fq "handle_runtime_signal HUP 129" sb-user-manager.sh
grep -Fq "handle_runtime_signal QUIT 131" sb-user-manager.sh
grep -Fxq '# >>> check_updates' sb-user-manager.sh
grep -Fxq '# <<< check_updates' sb-user-manager.sh
grep -Fq 'restore_state_backup_atomically()' sb-user-manager.sh
grep -Fq 'validate_public_rule_set_url()' sb-user-manager.sh
grep -Fq "curl --proto '=https' --proto-redir '=https'" sb-user-manager.sh
grep -Fq -- '--max-redirs 0' sb-user-manager.sh
grep -Fq -- '--connect-timeout 10 --max-time 30' sb-user-manager.sh
grep -Fq -- '--connect-timeout 10 --max-time 300' sb-user-manager.sh
grep -Fq 'apt-get update || return 1' sb-user-manager.sh
grep -Fq 'apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar gzip openssl python3 qrencode || return 1' sb-user-manager.sh
grep -Fq 'openssl enc -aes-256-cbc -md sha256 -pbkdf2' sb-user-manager.sh
grep -Fq 'echo '\''用户列表暂时无法格式化，敏感字段已隐藏。'\''' sb-user-manager.sh
grep -Fq 'prepare_menu_screen()' sb-user-manager.sh
grep -Fq 'handoff_to_newer_installed_manager()' sb-user-manager.sh
grep -Fq 'ssh_connection_uses_local_kernel()' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_kernel_restart()' sb-user-manager.sh
grep -Fq 'ss -Htnp state established' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_kernel_restart || return 0' sb-user-manager.sh
grep -A3 -F 'prompt_add_node()' sb-user-manager.sh | grep -Fq 'ensure_safe_ssh_for_kernel_restart || return 0'
grep -Fq 'sync_manager_launch_copy()' sb-user-manager.sh
grep -Fq 'initialize_deployed_state()' sb-user-manager.sh
grep -Fq 'deployed_state_path()' sb-user-manager.sh
grep -Fq 'cleanup_deploy_created_paths()' sb-user-manager.sh
grep -Fq 'wait_for_nfuse_ready()' sb-user-manager.sh
grep -Fq 'default_network_interface()' sb-user-manager.sh
grep -Fq 'ensure_anytls_certificate()' sb-user-manager.sh
grep -Fq 'install_manager_binary()' sb-user-manager.sh
grep -Fq 'validate_manager_shortcut_path()' sb-user-manager.sh
grep -Fq 'install_manager_shortcut()' sb-user-manager.sh
grep -Fq 'ensure_manager_shortcut_for_interactive_startup()' sb-user-manager.sh
grep -Fq "target='/usr/local/sbin/sb-user-manager'" sb-user-manager.sh
grep -Fq 'shortcut="$(system_path /usr/local/bin/sbm)"' sb-user-manager.sh
grep -Fq 'run_step_or_rollback rollback_deploy install_manager_shortcut' sb-user-manager.sh
grep -Fq '/usr/local/bin/sbm|/usr/local/bin/sing-box' sb-user-manager.sh
[[ "$(grep -Fc 'ensure_manager_shortcut_for_interactive_startup' sb-user-manager.sh)" == 2 ]]
grep -Fq 'write_deployed_versions()' sb-user-manager.sh
grep -Fq 'activate_managed_services()' sb-user-manager.sh
grep -Fq 'restore_failed_environment_change()' sb-user-manager.sh
grep -Fq 'complete_environment_change()' sb-user-manager.sh
# 这几个助手必须被复用而不是各写一份。调用点数量钉死，多出来一处通常意味着
# 有人又抄了一遍实现；改动调用点时同步改这里的期望值，并想清楚新增的那一处
# 为什么必须存在。
# 这些数字在 2f 撤除「接管既有 sing-box 安装」之后整体降了一档：那条流程曾经是
# 其中每一个的第二个调用点（公开 Issue #157）。
# default_network_interface 的四处：全新部署、服务单元漂移的检查与修复（公开
# Issue #190），以及换内核（公开 Issue #203）——后三处必须现场识别接口，不能读旧
# 单元里的那个，那正是可能不对的东西。
# activate_managed_services 的三处：部署、重写单元之后的重新激活（不 daemon-reload
# 就等于「修了但没生效」），以及换内核之后启用新内核的服务。
# restore_failed_environment_change 与 complete_environment_change 的四处：部署、
# 卸载、换内核、清理 sing-box 残留——四条都是改环境的动作，必须走同一套事务与回滚。
# 后面三个降到 1 之后这条断言只剩「别再抄一份实现」这一层意思，仍然值得留着。
for shared_helper in default_network_interface:4 ensure_anytls_certificate:1 install_manager_binary:1 \
  write_deployed_versions:1 activate_managed_services:3 restore_failed_environment_change:4 \
  complete_environment_change:4; do
  expected_calls="${shared_helper##*:}"
  shared_helper="${shared_helper%%:*}"
  shared_helper_calls="$(awk -v helper="$shared_helper" 'index($0, helper) && !index($0, helper "()") {count++} END {print count+0}' sb-user-manager.sh)"
  if [[ "$shared_helper_calls" != "$expected_calls" ]]; then
    echo "expected shared $shared_helper to have $expected_calls callers, found $shared_helper_calls" >&2
    exit 1
  fi
done
[[ "$(grep -Fc 'openssl req -x509 -newkey rsa:2048' sb-user-manager.sh)" == 1 ]]
[[ "$(grep -Fc 'systemctl enable nfuse "$kernel_service" sb-user-expiry.timer' sb-user-manager.sh)" == 1 ]]
grep -Fq 'begin_operation_transaction()' sb-user-manager.sh
grep -Fq 'recover_pending_transaction()' sb-user-manager.sh
grep -Fq 'restore_nfuse_snapshot()' sb-user-manager.sh
grep -Fq 'run_step_or_rollback()' sb-user-manager.sh
grep -Fq 'run_managed_step()' sb-user-manager.sh
grep -Fq 'begin_environment_transaction()' sb-user-manager.sh
grep -Fq 'recover_environment_transaction()' sb-user-manager.sh
grep -Fq 'acquire_operation_lock()' sb-user-manager.sh
# 取锁的五处：部署、卸载、迁移恢复，加上换内核与清理 sing-box 残留（公开 Issue
# #203）——都是改环境的动作，不取锁就会与别的写入撞车。接管既有安装曾经是第六处。
[[ "$(grep -Fc 'if ! acquire_operation_lock; then' sb-user-manager.sh)" == 5 ]]
for serialized_recovery in recover_environment_transaction acquire_manager_handoff_lock; do
  if ! awk -v function_name="$serialized_recovery" '
      $0 == function_name "() {" {inside=1}
      inside && /acquire_operation_lock/ {found=1}
      inside && /^}/ {exit}
      END {exit(found ? 0 : 1)}
    ' sb-user-manager.sh; then
    echo "$serialized_recovery must acquire the shared operation lock before recovery" >&2
    exit 1
  fi
done
grep -Fq '发现尚未完成的环境操作。为保护现有数据，本次用户或分流操作已停止' sb-user-manager.sh
grep -Fq '发现尚未完成的用户或分流操作。为保护现有数据，本次环境操作已停止' sb-user-manager.sh
if awk '/^cleanup_internal_material_after_uninstall\(\) \{/{inside=1} inside{print} inside && /^}/{exit}' \
    sb-user-manager.sh | grep -Eq 'rm .*\$(ENVIRONMENT_LOCK_FILE|LOCK_FILE)|operation_lock'; then
  echo 'complete uninstall must not unlink persistent lock files' >&2
  exit 1
fi
grep -Fq 'migrate_backup_retention_once()' sb-user-manager.sh
[[ "$(grep -Fc 'migrate_backup_retention_once' sb-user-manager.sh)" == 2 ]]
grep -Fq 'SB_BACKUP_RETENTION_MIGRATION_MARKER' sb-user-manager.sh
grep -Fq 'prompt_user_status_action()' sb-user-manager.sh
grep -Fq 'config_path="$(system_path /etc/sing-box/config.json)"' sb-user-manager.sh
grep -Fq 'if ! deploy_environment false "$update_manager"; then' sb-user-manager.sh
if grep -Fq 'prompt_name_action' sb-user-manager.sh; then
  echo 'legacy free-form enable/disable user prompt should not remain' >&2
  exit 1
fi
wait_ready_call_count="$(grep -Ec '^[[:space:]]+.*wait_for_nfuse_ready' sb-user-manager.sh || true)"
[[ "$wait_ready_call_count" == 2 ]]
managed_operation_start_count="$(grep -Ec '^[[:space:]]+.*start_managed_operation ' sb-user-manager.sh || true)"
managed_operation_finish_count="$(grep -Ec '^[[:space:]]+.*finish_managed_operation' sb-user-manager.sh || true)"
split_operation_finish_count="$(grep -Ec '^[[:space:]]+.*rebuild_and_finish_split_operation' sb-user-manager.sh || true)"
# finish_managed_operation 在分流收尾函数内部出现一次；该实现行本身不是新的事务入口。
managed_operation_finish_coverage=$((managed_operation_finish_count - 1 + split_operation_finish_count))
if [[ "$managed_operation_start_count" != 26 || "$split_operation_finish_count" != 9 ||
      "$managed_operation_finish_coverage" != "$managed_operation_start_count" ]]; then
  echo "managed operations must keep one finish path each: starts=$managed_operation_start_count direct_finishes=$managed_operation_finish_count split_finishes=$split_operation_finish_count coverage=$managed_operation_finish_coverage" >&2
  exit 1
fi
managed_step_count="$(grep -Ec '^[[:space:]]+run_managed_step ' sb-user-manager.sh || true)"
if ((managed_step_count < 50)); then
  echo "expected managed operations to use the shared step runner, found $managed_step_count calls" >&2
  exit 1
fi
# 改环境的三条流程都必须把会失败的步骤显式包进事务：部署、换内核、清理 sing-box
# 残留。接管既有安装曾经是第四条，2f 之后已整段删掉（公开 Issue #157）。
deploy_step_count="$(grep -Ec '^[[:space:]]+run_step_or_rollback rollback_deploy ' sb-user-manager.sh || true)"
switch_step_count="$(grep -Ec '^[[:space:]]+run_step_or_rollback rollback_switch ' sb-user-manager.sh || true)"
cleanup_step_count="$(grep -Ec '^[[:space:]]+run_step_or_rollback rollback_cleanup ' sb-user-manager.sh || true)"
if ((deploy_step_count < 10 || switch_step_count < 10 || cleanup_step_count < 2)); then
  echo "environment flows must explicitly wrap failure-prone steps: deploy=$deploy_step_count switch=$switch_step_count cleanup=$cleanup_step_count" >&2
  exit 1
fi
if grep -Fq 'rollback_takeover' sb-user-manager.sh; then
  echo 'takeover flow should be gone; no rollback_takeover steps must remain' >&2
  exit 1
fi
if grep -Fq 'repair_consistency_step' sb-user-manager.sh; then
  echo 'legacy consistency-only transaction step wrapper should not remain' >&2
  exit 1
fi
grep -Fq 'run_step_or_rollback rollback_deploy initialize_deployed_state "$fresh"' sb-user-manager.sh
deploy_config_line="$(grep -nF 'run_step_or_rollback rollback_deploy write_base_config' sb-user-manager.sh | cut -d: -f1)"
deploy_state_line="$(grep -nF 'run_step_or_rollback rollback_deploy initialize_deployed_state' sb-user-manager.sh | cut -d: -f1)"
[[ "$deploy_config_line" =~ ^[0-9]+$ && "$deploy_state_line" =~ ^[0-9]+$ ]]
((deploy_state_line > deploy_config_line))
grep -Fq 'deployed_state_file="$(trap - ERR; deployed_state_path)"' sb-user-manager.sh
grep -Fq 'cleanup_deploy_created_paths "${deploy_created[@]}"' sb-user-manager.sh
if grep -Fq -- '--arg label' sb-user-manager.sh; then
  echo 'jq 1.6 reserves label; use a non-reserved jq variable name' >&2
  exit 1
fi
grep -Fq 'SB_ACCEPTANCE_CONFIRM=YES' tests/acceptance.sh
grep -Fq "fail '空机迁移保护'" tests/acceptance.sh
if grep -Eq '^[[:space:]]*exec[[:space:]].*2>/dev/null' sb-user-manager.sh; then
  echo 'unsafe persistent exec stderr redirection detected' >&2
  exit 1
fi
if grep -Eq 'if[[:space:]]+run_lifecycle|run_mutation .*\|\|[[:space:]]+return' tests/acceptance.sh; then
  echo 'acceptance lifecycle must not run mutations inside an errexit-suppressed condition' >&2
  exit 1
fi
grep -Fq "trap 'handle_runtime_signal INT 130' INT" sb-user-manager.sh
grep -Fq "trap 'handle_runtime_signal TERM 143' TERM" sb-user-manager.sh
signal_rollback_count="$(grep -Ec '^[[:space:]]+set_signal_rollback rollback_' sb-user-manager.sh || true)"
clear_rollback_count="$(grep -Ec '^[[:space:]]+clear_signal_rollback$' sb-user-manager.sh || true)"
# 八处登记：部署、卸载、迁移恢复、用户与分流的写入路径，加上换内核与清理
# sing-box 残留（公开 Issue #203）。接管既有安装曾经是第九处。收到 INT/TERM 时
# 没登记回滚的那条路，会把机器停在改了一半的状态上。
if [[ "$signal_rollback_count" != 8 ]]; then
  echo "expected 8 signal rollback registrations, found $signal_rollback_count" >&2
  exit 1
fi
if [[ "$clear_rollback_count" != 13 ]]; then
  echo "expected 13 signal rollback clears, found $clear_rollback_count" >&2
  exit 1
fi
grep -Fq 'set_signal_rollback rollback_manager_handoff' sb-user-manager.sh
grep -Fq 'MIGRATION_FORMAT_VERSION=1' sb-user-manager.sh
grep -Fq 'MIGRATION_BUNDLE_VERSION=1' sb-user-manager.sh
if perl -ne '$found=1 if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/; END { exit($found ? 0 : 1) }' sb-user-manager.sh; then
  echo 'shell variable directly followed by non-ASCII text; use ${name} to avoid locale-dependent parsing' >&2
  exit 1
fi

echo "static checks passed for $version"
