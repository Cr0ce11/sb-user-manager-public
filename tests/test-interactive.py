#!/usr/bin/env python3
"""Exercise menu return paths in a real pseudo-terminal."""

import errno
import os
import pty
import select
import subprocess
import tempfile
import termios
import time


SHELL_FIXTURE = r"""
set -Eeuo pipefail
export SB_USER_MANAGER_LIBRARY=true
source ./sb-user-manager.sh

LOCK_FILE="$TEST_LOCK_PATH"
CONF_FILE="$TEST_CONF_PATH"
EXPECTED_PWD="$PWD"
EXPECTED_UMASK="$(umask)"
EXPECTED_IFS="$(printf '%q' "$IFS")"
EXPECTED_TRAPS="$(trap -p EXIT ERR INT TERM)"

assert_shell_state() {
  [[ "$PWD" == "$EXPECTED_PWD" ]] || { echo 'PWD_LEAKED_IN_MENU'; exit 92; }
  [[ "$(umask)" == "$EXPECTED_UMASK" ]] || { echo 'UMASK_LEAKED_IN_MENU'; exit 93; }
  [[ "$(printf '%q' "$IFS")" == "$EXPECTED_IFS" ]] || { echo 'IFS_LEAKED_IN_MENU'; exit 94; }
  [[ "$(trap -p EXIT ERR INT TERM)" == "$EXPECTED_TRAPS" ]] || { echo 'TRAP_LEAKED_IN_MENU'; exit 95; }
  { : <&0; } 2>/dev/null || { echo 'STDIN_CLOSED_IN_MENU'; exit 96; }
  { : >&1; } 2>/dev/null || { echo 'STDOUT_CLOSED_IN_MENU'; exit 97; }
  { : >&2; } 2>/dev/null || { echo 'STDERR_CLOSED_IN_MENU'; exit 98; }
}

clear() {
  assert_shell_state
  if { : >&9; } 2>/dev/null; then
    echo 'FD9_LEAKED_IN_MENU'
    exit 91
  fi
}

acquire_test_lock() {
  exec 9>"$LOCK_FILE"
}

install_environment() {
  local secret
  read -r -s -p 'mock secret prompt：' secret
  echo
  [[ "$secret" == 'test-secret' ]]
  acquire_test_lock
}

uninstall_environment() {
  acquire_test_lock
  echo 'mock uninstall return'
  MENU_RETURNED=true
}

check_updates() {
  acquire_test_lock
  echo 'mock update check'
}

show_service_status() {
  acquire_test_lock
  echo 'mock service status'
}

prompt_remove_user() {
  acquire_test_lock
  MENU_RETURNED=true
}

prompt_edit_user() {
  acquire_test_lock
  echo 'mock edit user'
  MENU_RETURNED=true
}

prompt_manage_user_protocols() {
  acquire_test_lock
  echo 'mock manage user protocols'
  MENU_RETURNED=true
}

prompt_user_status_action() {
  acquire_test_lock
  echo 'mock user status action'
  MENU_RETURNED=true
}

prompt_split_action() {
  acquire_test_lock
  MENU_RETURNED=true
}

prompt_add_split() {
  acquire_test_lock
  echo 'mock add split return'
  MENU_RETURNED=true
}

prompt_split_details() {
  acquire_test_lock
  echo 'mock split details'
  MENU_RETURNED=true
}

prompt_edit_split() {
  acquire_test_lock
  echo 'mock edit split'
  MENU_RETURNED=true
}

prompt_move_split() {
  acquire_test_lock
  echo 'mock move split'
  MENU_RETURNED=true
}

prompt_split_diagnostic() {
  acquire_test_lock
  echo 'mock split diagnostic'
  MENU_RETURNED=true
}

prompt_consistency() {
  acquire_test_lock
  echo 'mock consistency check'
}

create_diagnostic_report() {
  acquire_test_lock
  echo 'mock diagnostic create'
}

print_diagnostic_reports() {
  acquire_test_lock
  echo 'mock diagnostic list'
}

show_diagnostic_report() {
  acquire_test_lock
  echo 'mock diagnostic show'
}

delete_diagnostic_report() {
  acquire_test_lock
  echo 'mock diagnostic delete'
}

cleanup_diagnostic_reports() {
  acquire_test_lock
  echo 'mock diagnostic cleanup'
}

import_migration_backup() {
  acquire_test_lock
  echo 'mock migration import'
}

singbox_channel_menu() {
  acquire_test_lock
  echo 'mock sing-box channel menu'
}

interactive_main
"""


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sb-menu-test-") as work:
        lock_path = os.path.join(work, "manager.lock")
        conf_path = os.path.join(work, "sb-user-manager.conf")
        open(conf_path, "w", encoding="utf-8").close()
        env = os.environ.copy()
        env["TEST_LOCK_PATH"] = lock_path
        env["TEST_CONF_PATH"] = conf_path
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", "-c", SHELL_FIXTURE],
            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            env=env,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)
        pending = b""
        transcript = bytearray()

        def expect(text: str, timeout: float = 8.0) -> None:
            nonlocal pending
            token = text.encode("utf-8")
            deadline = time.monotonic() + timeout
            while token not in pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"timeout waiting for {text!r}")
                ready, _, _ = select.select([master], [], [], remaining)
                if not ready:
                    continue
                try:
                    chunk = os.read(master, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if not chunk:
                    raise AssertionError(
                        f"menu process exited while waiting for {text!r}"
                    )
                pending += chunk
                transcript.extend(chunk)
            _, pending = pending.split(token, 1)

        def send(text: str) -> None:
            os.write(master, text.encode("utf-8"))

        def expect_choice_prompt() -> None:
            expect("请选择：")
            attributes = termios.tcgetattr(master)
            if not attributes[3] & termios.ECHO:
                raise AssertionError("terminal echo disabled at menu prompt")

        try:
            expect("sb-user-manager")
            expect("（公开版）")
            expect_choice_prompt()

            send("wrong\n")
            expect("请输入 0-3 之间的编号")
            expect_choice_prompt()

            send("3\n")
            expect("系统管理")
            expect_choice_prompt()
            send("1\n")
            expect("部署与卸载")
            expect_choice_prompt()
            send("1\n")
            expect("mock secret prompt：")
            send("test-secret\n")
            expect("按回车返回菜单…")
            send("\n")
            expect("部署与卸载")
            expect_choice_prompt()
            send("2\n")
            expect("mock uninstall return")
            expect("部署与卸载")
            expect_choice_prompt()
            send("0\n")
            expect("系统管理")
            expect_choice_prompt()

            send("2\n")
            expect("mock update check")
            expect("按回车返回菜单…")
            send("\n")
            expect("系统管理")
            expect_choice_prompt()
            send("0\n")
            expect("sb-user-manager")
            expect_choice_prompt()

            send("1\n")
            expect("用户管理")
            expect("管理用户协议")
            expect_choice_prompt()
            send("11\n")
            expect("请输入 0-10 之间的编号")
            expect_choice_prompt()
            send("10\n")
            expect("用户管理")
            expect_choice_prompt()
            send("3\n")
            expect("mock edit user")
            expect("用户管理")
            expect_choice_prompt()
            send("5\n")
            expect("mock manage user protocols")
            expect("用户管理")
            expect_choice_prompt()
            send("6\n")
            expect("mock user status action")
            expect("用户管理")
            expect_choice_prompt()
            send("7\n")
            expect("mock user status action")
            expect("用户管理")
            expect_choice_prompt()
            send("0\n")
            expect("sb-user-manager")
            expect_choice_prompt()

            send("2\n")
            expect("分流管理")
            expect_choice_prompt()
            send("4\n")
            expect("mock add split return")
            expect("分流管理")
            expect_choice_prompt()
            send("2\n")
            expect("分流管理")
            expect_choice_prompt()
            send("2\n")
            expect("mock split details")
            expect("分流管理")
            expect_choice_prompt()
            send("5\n")
            expect("mock edit split")
            expect("分流管理")
            expect_choice_prompt()
            send("6\n")
            expect("mock move split")
            expect("分流管理")
            expect_choice_prompt()
            send("7\n")
            expect("分流管理")
            expect_choice_prompt()
            send("8\n")
            expect("分流管理")
            expect_choice_prompt()
            send("3\n")
            expect("mock split diagnostic")
            expect("分流管理")
            expect_choice_prompt()
            send("0\n")
            expect("sb-user-manager")
            expect_choice_prompt()

            send("3\n")
            expect("系统管理")
            expect_choice_prompt()
            send("3\n")
            expect("mock service status")
            expect("按回车返回菜单…")
            send("\n")
            expect("系统管理")
            expect_choice_prompt()

            send("4\n")
            expect("检查与故障报告")
            expect("0. 返回上一级")
            expect_choice_prompt()
            send("1\n")
            expect("mock consistency check")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("2\n")
            expect("mock diagnostic create")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("3\n")
            expect("mock diagnostic list")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("4\n")
            expect("mock diagnostic show")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("5\n")
            expect("mock diagnostic delete")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("6\n")
            expect("mock diagnostic cleanup")
            expect("按回车返回菜单…")
            send("\n")
            expect("检查与故障报告")
            expect_choice_prompt()
            send("0\n")
            expect("系统管理")
            expect_choice_prompt()
            send("5\n")
            expect("数据备份与恢复")
            expect_choice_prompt()
            send("2\n")
            expect("mock migration import")
            expect("按回车返回菜单…")
            send("\n")
            expect("数据备份与恢复")
            expect_choice_prompt()
            send("0\n")
            expect("系统管理")
            expect_choice_prompt()
            send("6\n")
            expect("默认连接域名（SNI）")
            expect_choice_prompt()
            send("0\n")
            expect("系统管理")
            expect_choice_prompt()
            send("7\n")
            expect("mock sing-box channel menu")
            expect("系统管理")
            expect_choice_prompt()
            send("0\n")
            expect("sb-user-manager")
            expect_choice_prompt()

            os.unlink(conf_path)
            send("1\n")
            expect("尚未部署管理环境")
            expect("系统管理 → 部署与卸载 → 安装或修复环境")
            expect("按回车返回菜单…")
            send("\n")
            expect("sb-user-manager")
            expect_choice_prompt()
            send("2\n")
            expect("尚未部署管理环境")
            expect("系统管理 → 部署与卸载 → 安装或修复环境")
            expect("按回车返回菜单…")
            send("\n")
            expect("sb-user-manager")
            expect_choice_prompt()
            send("3\n")
            expect("系统管理")
            expect_choice_prompt()
            send("5\n")
            expect("尚未部署管理环境")
            expect("系统管理 → 部署与卸载 → 安装或修复环境")
            expect("按回车返回菜单…")
            send("\n")
            expect("系统管理")
            expect_choice_prompt()
            send("6\n")
            expect("尚未部署管理环境")
            expect("系统管理 → 部署与卸载 → 安装或修复环境")
            expect("按回车返回菜单…")
            send("\n")
            expect("系统管理")
            expect_choice_prompt()
            send("0\n")
            expect("sb-user-manager")
            expect_choice_prompt()
            if "错误：管理配置不是普通文件".encode("utf-8") in transcript:
                raise AssertionError("uninstalled menu path used fatal config validation")
            send("0\n")
            process.wait(timeout=8)
            if process.returncode != 0:
                raise AssertionError(f"menu process exited with {process.returncode}")
        except Exception as exc:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
            output = transcript.decode("utf-8", errors="replace")
            raise AssertionError(f"{exc}\n--- transcript ---\n{output}") from exc
        finally:
            os.close(master)

    print("interactive pty checks passed")


if __name__ == "__main__":
    main()
