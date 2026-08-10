# ADR 0024：入口发起的落地依赖准备

- 状态：已接受并实现，保持 dormant
- 日期：2026-08-08
- 关联：[ADR 0013](0013-controller-pinned-landing-transport.md)、[ADR 0015](0015-entry-initiated-landing-root-bootstrap.md)、[ADR 0017](0017-controller-landing-onboarding-orchestration.md)、[Issue #236](https://github.com/DTB201/sb-user-manager/issues/236)

## 背景

ADR 0015 故意不在一次性 root 引导中运行 APT：落地依赖缺失时，引导会在项目文件变更前失败。这样保护了通道事务的精确回退语义，但一台干净 Debian 12 机器仍需人工安装 `jq`、`sudo`、`nftables` 等依赖，无法满足未来“所有操作从入口完成”的产品目标。

系统包安装本身不能与项目文件共享无损事务。依赖准备因此必须先于秘密生成、引导收据、受限账户、控制器登记与数据面 apply 独立完成；失败时只能报告明确结果并允许幂等重试，不能假装已经回退 Debian 包管理器。

## 决定

增加一个尚未接入菜单的入口编排函数。它先验证已有入口控制器状态，再只接受地址、SSH 端口和受限格式的落地 ID，复用 ADR 0013 的 Ed25519 扫描并要求人工通过可信渠道核对；确认后创建新的 700 临时工作目录，连接前再次扫描同一指纹并生成仅含该主机密钥的 600 `known_hosts`。拒绝、EOF、扫描失败或二次指纹不一致都发生在 root 连接之前。

入口通过 OpenSSH stdin 发送独立的 600 Bash 包。包的 SHA-256 作为唯一远端命令数据，远端先把完整 stdin 写入随机 `/tmp` 目录并校验摘要，再用空环境执行。root SSH 继续固定 `/dev/null` 配置、禁用转发、代理、跳板、控制连接、DNS 主机密钥、主机密钥更新和非 Ed25519 算法；密码或键盘交互只由本机 OpenSSH 从控制终端读取，不进入参数、包、文件或状态。

依赖包只支持 Debian 12 x86_64 root。它先检查落地通道和 apply 所需的固定可执行文件：缺失与不可信分开处理；任一已经存在但所有者、类型、解析目标或写权限不可信时失败关闭，不用 APT 覆盖。全部就绪时直接返回 `ready`，完全不检查或调用 APT。

只有发现缺失依赖时，包才验证固定 `/usr/bin/apt-get` 与 `/usr/bin/env`，并用清空后的环境依次执行：

1. 带 60 秒锁等待、30 秒 HTTP/HTTPS 超时和三次重试的 `apt-get update`；
2. 对固定的 `bash coreutils gawk grep iproute2 jq nftables openssh-client openssl passwd procps python3 sudo systemd util-linux` 执行 `install -y --reinstall --no-install-recommends`；
3. 重新逐项验证全部固定可执行文件。

调用方不能增加包名、路径、APT 选项或远端命令。APT 输出不进入控制协议。响应只能是一行严格 JSON，且必须与 SSH 退出码一致；稳定区分 `ready`、`repaired`、平台不支持、可疑依赖、可疑运行时、update 失败、install 失败、复检失败和 SSH 结果不确定。响应超过 512 字节、额外字段、错误退出码、空响应或截断均按不确定失败处理。

## 边界

本能力不创建或修改控制器状态、onboarding 日志、每落地秘密、受限账户、引导收据、sing-box、nftables 规则或任何 `/etc/sb-user-manager`、`/var/lib/sb-user-manager` 项目路径；也不接入 v4、角色菜单、在线更新、服务器验收或发布。APT 安装的 Debian 官方包是唯一系统变更。

未来落地初始化向导必须先调用本决定，再进入落地 sing-box 运行时准备，最后才能复用 ADR 0017 的秘密、root 引导、登记和首次 apply。不得把依赖准备塞入已有持久 onboarding 日志中并误称其可回退；重试依据固定依赖复检，而不是本地阶段猜测。

## 验证与回退

测试覆盖依赖已就绪不运行 APT、缺失后修复、update/install/复检失败、不可信依赖和 APT 拒绝、平台拒绝、固定包与参数、指纹确认顺序、二次指纹失败、整包摘要、严格 SSH 参数、响应与退出码绑定、额外字段及超长响应。CI 同时运行私有版、分享版、Debian 12 jq 1.6 和既有 root 引导回归。

接入菜单前可删除本模块、定向测试和本文档，恢复 root 交换包装并重新生成单脚本。若测试环境曾执行依赖修复，不自动卸载 Debian 包；卸载可能破坏系统或其他软件，回退只停止使用本能力。
