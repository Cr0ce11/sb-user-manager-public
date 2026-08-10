# ADR 0020：入口控制器依赖安装与修复

- 状态：已接受，基础模块尚未接入运行流程
- 日期：2026-08-08
- 关联：[ADR 0019](0019-entry-controller-role-initialization.md)、[Issue #228](https://github.com/DTB201/sb-user-manager/issues/228)

## 背景

ADR 0019 已能只读区分入口依赖就绪、缺失和不可信，但缺失时仍没有可供未来“安装或修复入口环境”调用的安全修复入口。直接复用 v4 的整套安装依赖会额外安装 nftables、Nfuse、二维码和 sing-box 相关工具，也无法表达“不可信依赖不能自动覆盖”的失败边界。

## 决定

新增 dormant 的 `repair_entry_controller_dependencies`。它只接受零参数，包清单在源码中固定为 `coreutils`、`gawk`、`grep`、`jq`、`openssh-client`、`openssl`、`python3` 和 `util-linux`，不接受菜单、配置、环境变量或远端输入追加包名。

调用顺序固定为：

1. 只读验证 root、Debian 12 x86_64 与控制器固定路径。
2. 复用 ADR 0019 的入口依赖门禁。全部就绪时返回 `dependencies_ready`，不调用 APT。
3. 只有结果为 `missing_dependency` 才验证 `/usr/bin/apt-get`、`/usr/bin/env` 的属主、权限与最终普通文件并执行 APT；`unsafe_dependency` 和其他失败保持现场并停止。
4. 通过固定 `/usr/bin/env -i` 清除 `APT_CONFIG`、代理和 shell 注入环境，仅保留固定 PATH、C.UTF-8 与非交互标记；APT 使用 60 秒 dpkg 锁等待、30 秒获取超时和三次获取重试，先更新索引，再以 `--reinstall --no-install-recommends` 安装固定包。
5. 安装后重新执行完整入口依赖门禁；只有全部可信才返回 `dependencies_repaired`。

APT 和 dpkg 自身负责包数据库锁与单包原子安装。索引更新或一组包的安装可能已产生部分加法型变化，因此本函数不承诺卸载或恢复系统包；失败返回 `dependency_repair_failed`，再次调用必须幂等收敛。未来交互层必须在用户明确选择入口环境修复后调用，非交互定时任务、恢复钩子和 v4 启动不得调用。

## 状态与秘密边界

结果继续使用 `CONTROLLER_ROLE_LAST_STATUS` 和 `CONTROLLER_ROLE_LAST_DETAIL`。详情只包含固定阶段或既有安全依赖名称，不包含 APT 输出、源地址、凭据或环境内容。APT 参数不含秘密。

依赖修复不创建 controller state、秘密目录或锁，不安装落地账户、sudo、systemd、nftables、sing-box 或 Nfuse，也不修改 v4 配置、服务和数据。

## 回退

在接入菜单前，撤销函数、测试与本文档并重新生成单脚本即可回退代码。已经由 APT 安装或重装的系统包不自动卸载；它们是 Debian 官方依赖且不改变项目业务状态。
