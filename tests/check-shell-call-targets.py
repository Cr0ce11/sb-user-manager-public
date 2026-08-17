#!/usr/bin/env python3
"""Reject bare shell command calls that have no declared target.

This is deliberately a conservative, dependency-free Bash scanner rather than a
full parser.  It follows simple-command boundaries, nested command
substitutions, loops and case arms closely enough to audit the generated
manager.  Quoted or dynamically expanded command names are outside this gate.

The same scanner also enforces a small set of call conventions that the manager
already established in one place but repeatedly lost at sibling call sites.
Every convention below is deliberately narrow so that the current manager
reports nothing:

* cancellable prompts must have their exit status checked;
* `$?` must not be read after an `if` that has no `else`;
* payloads must reach `qrencode` through stdin instead of argv;
* a numeric answer typed at a prompt must be normalised with `10#`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import re
import sys
from pathlib import Path


IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
COMMAND_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?\+?=")
FUNCTION_DEFINITION = re.compile(
    r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*\{"
)

# Bash keywords and builtins used by the generated manager.  Keeping the list
# explicit makes a newly introduced command target reviewable.
SHELL_TARGETS = {
    ".",
    ":",
    "[",
    "alias",
    "bg",
    "bind",
    "break",
    "builtin",
    "caller",
    "case",
    "cd",
    "command",
    "compgen",
    "complete",
    "continue",
    "coproc",
    "declare",
    "dirs",
    "disown",
    "do",
    "done",
    "echo",
    "elif",
    "else",
    "enable",
    "esac",
    "eval",
    "exec",
    "exit",
    "export",
    "false",
    "fc",
    "fg",
    "fi",
    "for",
    "function",
    "getopts",
    "hash",
    "help",
    "history",
    "if",
    "in",
    "jobs",
    "kill",
    "let",
    "local",
    "logout",
    "mapfile",
    "popd",
    "printf",
    "pushd",
    "pwd",
    "read",
    "readarray",
    "readonly",
    "return",
    "select",
    "set",
    "shift",
    "shopt",
    "source",
    "suspend",
    "test",
    "then",
    "time",
    "times",
    "trap",
    "true",
    "type",
    "typeset",
    "ulimit",
    "umask",
    "unalias",
    "unset",
    "until",
    "wait",
    "while",
}

# External commands are limited to Debian base utilities (coreutils, findutils,
# grep, sed, gawk, systemd and ncurses-bin), packages installed by
# install_prerequisites() (ca-certificates, curl, jq, nftables, iproute2,
# util-linux, bsdextrautils, tar, openssl, python3 and qrencode), plus sing-box
# and nfuse which the manager itself installs before their use.
EXTERNAL_TARGETS = {
    "apt-get",
    "awk",
    "base64",
    "basename",
    "bash",
    "cat",
    "chmod",
    "chown",
    "clear",
    "cmp",
    "column",
    "cp",
    "curl",
    "cut",
    "date",
    "dd",
    "df",
    "dirname",
    "du",
    "env",
    "find",
    "flock",
    "getent",
    "grep",
    "head",
    "hostname",
    "id",
    "install",
    "ip",
    "journalctl",
    "jq",
    "ln",
    "ls",
    "mkdir",
    "mktemp",
    "mv",
    "nfuse",
    "nft",
    "openssl",
    "paste",
    "python3",
    "qrencode",
    "readlink",
    "realpath",
    "rm",
    "rmdir",
    "sed",
    "sha256sum",
    "sing-box",
    "sleep",
    "sort",
    "ss",
    "stat",
    "sync",
    "systemctl",
    "tail",
    "tar",
    "timeout",
    "tee",
    "touch",
    "tr",
    "tput",
    "uname",
    "wc",
    "xargs",
}

# These helpers execute one or more positional arguments as commands.  Literal
# targets must pass the same allowlist as an ordinary bare command.  Dynamic
# targets such as "$action" remain a runtime concern and are deliberately
# skipped by this static gate.  The forwarded position identifies the command
# that receives all following arguments, so nested wrappers such as
# `run_managed_step run_quietly nfuse ...` are checked recursively.
DISPATCH_TARGET_POSITIONS = {
    "run_step_or_rollback": (1, 2),
    "run_managed_step": (1,),
    "run_quietly": (1,),
    "write_command_output": (2,),
    "validate_without_exit": (1,),
    "read_validated_value": (4,),
    "prompt_user_status_action": (1,),
}
DISPATCH_FORWARDED_POSITION = {
    "run_step_or_rollback": 2,
    "run_managed_step": 1,
    "run_quietly": 1,
    "write_command_output": 2,
    "validate_without_exit": 1,
    "read_validated_value": 4,
    "prompt_user_status_action": 1,
}

# 这些提示函数在用户取消或输入结束时返回非零，调用点必须检查返回值，
# 否则会拿着上一轮的全局结果继续执行。参照 select_migration_restore_mode。
CANCELLABLE_PROMPTS = {
    "prompt_migration_choice",
    "read_menu_choice",
    "read_numbered_index",
    "read_validated_value",
    "ui_menu_select",
}
PROMPT_GUARD_PREFIXES = {"!", "elif", "if", "until", "while"}
PROMPT_GUARD_TERMINATORS = {"&&", "||"}

# 命令行参数对同机其他进程可见，涉密内容只能走环境变量或管道。
STDIN_ONLY_PAYLOAD_TARGETS = {"qrencode"}


@dataclass(frozen=True)
class Token:
    value: str
    line: int
    bare: bool = True


OPERATORS = (
    ";;&",
    "<<<",
    "&&",
    "||",
    ";;",
    ";&",
    "((",
    "))",
    "[[",
    "]]",
    "<<",
    ">>",
    "<&",
    ">&",
    "<>",
    ">|",
    "$((",
    ";",
    "|",
    "&",
    "(",
    ")",
    "{",
    "}",
    "<",
    ">",
)
SEPARATORS = {"\n", ";", "&&", "||", "|", "&", "(", "{"}
REDIRECTIONS = {"<<<", "<<", ">>", "<&", ">&", "<>", ">|", "<", ">"}
COMMAND_TERMINATORS = SEPARATORS | {")", "}", ";;", ";&", ";;&"}


def mask_heredoc_bodies(source: str) -> str:
    result: list[str] = []
    pending: list[tuple[str, bool]] = []
    opener = re.compile(r"(?<!<)<<(-)?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
    for line in source.splitlines(keepends=True):
        if pending:
            delimiter, strip_tabs = pending[0]
            candidate = line.rstrip("\r\n")
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            result.append("\n" if line.endswith("\n") else "")
            if candidate == delimiter:
                pending.pop(0)
            continue
        result.append(line)
        for match in opener.finditer(line):
            pending.append((match.group(3), bool(match.group(1))))
    return "".join(result)


def matching_substitution(source: str, start: int) -> int | None:
    depth = 1
    quote = ""
    escaped = False
    i = start
    while i < len(source):
        char = source[i]
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote:
            if char == quote:
                quote = ""
            elif quote == '"' and source.startswith("$((", i):
                # 双引号串里的算术展开必须整段跳过。按 `$(` 记一层、而引号内的裸括号
                # 又不计数，深度就会少算一层，命令替换会在算术展开的 `))` 处提前收尾，
                # 之后的内容全部作废（公开 Issue #102）。
                end = matching_arithmetic_expansion(source, i + 3)
                if end is None:
                    return None
                i = end + 1
                continue
            elif quote == '"' and source.startswith("$(", i):
                depth += 1
                i += 1
            elif quote == '"' and char == ")":
                depth -= 1
                if depth == 0:
                    return i
        elif char in "'\"":
            quote = char
        elif source.startswith("$((", i):
            # 引号外的两个括号恰好各记一层，深度虽然算得平，但含义是错的：
            # 算术展开里的引号和括号不该按命令替换的规则解释。这里同样整段跳过。
            end = matching_arithmetic_expansion(source, i + 3)
            if end is None:
                return None
            i = end + 1
            continue
        elif source.startswith("$(", i):
            depth += 1
            i += 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def matching_parameter_expansion(source: str, start: int) -> int | None:
    depth = 1
    i = start
    while i < len(source):
        if source.startswith("${", i):
            depth += 1
            i += 2
            continue
        if source[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        if source[i] == "\\" and i + 1 < len(source):
            i += 2
            continue
        i += 1
    return None


def matching_arithmetic_expansion(source: str, start: int) -> int | None:
    depth = 1
    quote = ""
    i = start
    while i < len(source) - 1:
        char = source[i]
        if quote:
            if char == "\\" and quote == '"':
                i += 2
                continue
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif source.startswith("((", i):
            depth += 1
            i += 2
            continue
        elif source.startswith("))", i):
            depth -= 1
            if depth == 0:
                return i + 1
            i += 2
            continue
        i += 1
    return None


# 分词器碰到读不懂的写法时，原先的做法是把该处到输入末尾的全部内容当成一个
# 不透明词元咽下去，然后正常返回。调用方无从察觉，于是该位置之后的所有静态约定
# 都不再生效，而退出码仍是 0（公开 Issue #102）。现在每个放弃点都记进 giveups，
# 由 main 报错退出：宁可当场变红，也不要门禁长期只覆盖文件的前半部分。
def tokenize(
    source: str,
    first_line: int = 1,
    giveups: list[tuple[int, str]] | None = None,
) -> list[list[Token]]:
    if giveups is None:
        giveups = []
    streams: list[list[Token]] = []
    tokens: list[Token] = []
    line = first_line
    i = 0
    while i < len(source):
        char = source[i]
        if char == "\n":
            tokens.append(Token("\n", line))
            line += 1
            i += 1
            continue
        if char.isspace():
            i += 1
            continue
        if char == "#":
            newline = source.find("\n", i)
            if newline < 0:
                break
            i = newline
            continue
        if source.startswith("$(<", i):
            end = matching_substitution(source, i + 2)
            if end is not None:
                tokens.append(Token("$(<)", line, False))
                line += source[i + 2 : end].count("\n")
                i = end + 1
                continue
        if source.startswith("$((${", i) or source.startswith("$((", i):
            end = matching_arithmetic_expansion(source, i + 3)
            if end is not None:
                tokens.append(Token("$(())", line, False))
                line += source[i + 3 : end - 1].count("\n")
                i = end + 1
                continue
        if source.startswith("((", i):
            end = matching_arithmetic_expansion(source, i + 2)
            if end is not None:
                tokens.append(Token("$(())", line, False))
                line += source[i + 2 : end - 1].count("\n")
                i = end + 1
                continue
        operator = next((item for item in OPERATORS if source.startswith(item, i)), None)
        if operator is not None:
            if operator == "$((":
                end = matching_arithmetic_expansion(source, i + 3)
                if end is not None:
                    tokens.append(Token("$(())", line, False))
                    line += source[i + 3 : end - 1].count("\n")
                    i = end + 1
                    continue
            tokens.append(Token(operator, line))
            i += len(operator)
            continue

        start_line = line
        value: list[str] = []
        bare = True
        while i < len(source):
            char = source[i]
            if char == "\n" or char.isspace() or char == "#":
                break
            if any(source.startswith(item, i) for item in OPERATORS):
                break
            if source.startswith("$((", i):
                end = matching_arithmetic_expansion(source, i + 3)
                if end is None:
                    giveups.append((line, "unbalanced $(( arithmetic expansion"))
                    value.append(source[i:])
                    i = len(source)
                    bare = False
                    break
                value.append("$(())")
                bare = False
                line += source[i + 3 : end - 1].count("\n")
                i = end + 1
                continue
            if source.startswith("$(", i):
                end = matching_substitution(source, i + 2)
                if end is None:
                    giveups.append((line, "unbalanced $( command substitution"))
                    value.append(source[i:])
                    i = len(source)
                    bare = False
                    break
                inner = source[i + 2 : end]
                streams.extend(tokenize(inner, line, giveups))
                line += inner.count("\n")
                value.append("$()")
                bare = False
                i = end + 1
                continue
            if source.startswith("${", i):
                end = matching_parameter_expansion(source, i + 2)
                if end is None:
                    giveups.append((line, "unbalanced ${ parameter expansion"))
                    value.append(source[i:])
                    i = len(source)
                    bare = False
                    break
                value.append("${}")
                bare = False
                line += source[i + 2 : end].count("\n")
                i = end + 1
                continue
            if char in "'\"":
                bare = False
                quote = char
                quote_line = line
                terminated = False
                value.append(char)
                i += 1
                while i < len(source):
                    current = source[i]
                    value.append(current)
                    if current == "\n":
                        line += 1
                    if current == "\\" and quote == '"' and i + 1 < len(source):
                        i += 1
                        value.append(source[i])
                    elif current == quote:
                        terminated = True
                        i += 1
                        break
                    elif quote == '"' and source.startswith("$((", i):
                        value.pop()
                        end = matching_arithmetic_expansion(source, i + 3)
                        if end is None:
                            giveups.append((line, "unbalanced $(( arithmetic expansion"))
                            terminated = True
                            value.append(source[i:])
                            i = len(source)
                            break
                        value.append("$(())")
                        line += source[i + 3 : end - 1].count("\n")
                        i = end + 1
                        continue
                    elif quote == '"' and source.startswith("$(", i):
                        value.pop()
                        end = matching_substitution(source, i + 2)
                        if end is None:
                            giveups.append((line, "unbalanced $( command substitution"))
                            terminated = True
                            value.append(source[i:])
                            i = len(source)
                            break
                        inner = source[i + 2 : end]
                        streams.extend(tokenize(inner, line, giveups))
                        line += inner.count("\n")
                        value.append("$()")
                        i = end + 1
                        continue
                    elif quote == '"' and source.startswith("${", i):
                        value.pop()
                        end = matching_parameter_expansion(source, i + 2)
                        if end is None:
                            giveups.append((line, "unbalanced ${ parameter expansion"))
                            terminated = True
                            value.append(source[i:])
                            i = len(source)
                            break
                        value.append("${}")
                        line += source[i + 2 : end].count("\n")
                        i = end + 1
                        continue
                    i += 1
                if not terminated:
                    giveups.append((quote_line, f"unterminated {quote} quote"))
                continue
            if char == "\\" and i + 1 < len(source):
                bare = False
                value.extend((char, source[i + 1]))
                if source[i + 1] == "\n":
                    line += 1
                i += 2
                continue
            if char in "$`":
                bare = False
            value.append(char)
            i += 1
        if value:
            tokens.append(Token("".join(value), start_line, bare))
        elif i < len(source) and source[i] == "#":
            continue
        else:
            i += 1
    streams.insert(0, tokens)
    return streams


def scan_simple_command(tokens: list[Token], start: int) -> tuple[list[Token], int]:
    arguments: list[Token] = []
    i = start
    while i < len(tokens):
        value = tokens[i].value
        if value in COMMAND_TERMINATORS:
            break
        if value.isdigit() and i + 1 < len(tokens) and tokens[i + 1].value in REDIRECTIONS:
            i += 2
            if i < len(tokens):
                i += 1
            continue
        if value in REDIRECTIONS:
            i += 2
            continue
        arguments.append(tokens[i])
        i += 1
    return arguments, i


def literal_dispatch_target(token: Token) -> Token | None:
    if token.bare and (COMMAND_NAME.match(token.value) or token.value == "["):
        return token
    if (
        len(token.value) >= 2
        and token.value[0] == token.value[-1]
        and token.value[0] in "'\""
    ):
        value = token.value[1:-1]
        if COMMAND_NAME.match(value) or value == "[":
            return Token(value, token.line)
    return None


def dispatched_command_calls(command: str, arguments: list[Token]) -> list[Token]:
    calls: list[Token] = []
    for position in DISPATCH_TARGET_POSITIONS.get(command, ()):
        if position > len(arguments):
            continue
        target = literal_dispatch_target(arguments[position - 1])
        if target is not None:
            calls.append(target)

    forwarded_position = DISPATCH_FORWARDED_POSITION.get(command)
    if forwarded_position is None or forwarded_position > len(arguments):
        return calls
    forwarded = literal_dispatch_target(arguments[forwarded_position - 1])
    if forwarded is not None and forwarded.value in DISPATCH_TARGET_POSITIONS:
        calls.extend(
            dispatched_command_calls(
                forwarded.value,
                arguments[forwarded_position:],
            )
        )
    return calls


@dataclass
class ConventionFindings:
    unchecked_prompts: list[Token] = field(default_factory=list)
    argv_payloads: list[Token] = field(default_factory=list)


def prompt_status_is_checked(
    tokens: list[Token], index: int, end: int, lines: list[str] | None = None
) -> bool:
    if index > 0 and tokens[index - 1].value in PROMPT_GUARD_PREFIXES:
        return True
    # `{ prompt ...; } || return 1`：命令与 && / || 之间隔着 `;` 和 `}`
    cursor = end
    for _ in range(2):
        if cursor < len(tokens) and tokens[cursor].value in {";", "}"}:
            cursor += 1
    if cursor < len(tokens) and tokens[cursor].value in PROMPT_GUARD_TERMINATORS:
        return True
    # `prompt ...` 紧跟一行 `rc=$?`：DEVELOPMENT.md 推崇的显式取状态写法
    if lines is not None:
        following = tokens[index].line
        while following < len(lines) and not lines[following].strip():
            following += 1
        if following < len(lines) and STATUS_CAPTURE.match(lines[following].strip()):
            return True
    return False


def command_calls(
    tokens: list[Token],
    findings: ConventionFindings | None = None,
    lines: list[str] | None = None,
) -> list[Token]:
    calls: list[Token] = []
    expect_command = True
    case_patterns: list[bool] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        value = token.value

        if case_patterns and case_patterns[-1]:
            if value == "esac":
                case_patterns.pop()
                expect_command = False
            elif value == ")":
                case_patterns[-1] = False
                expect_command = True
            i += 1
            continue
        if value in {";;", ";&", ";;&"}:
            if case_patterns:
                case_patterns[-1] = True
            expect_command = False
            i += 1
            continue
        if value == "esac":
            if case_patterns:
                case_patterns.pop()
            expect_command = False
            i += 1
            continue
        if value in SEPARATORS:
            expect_command = True
            i += 1
            continue
        if value in REDIRECTIONS:
            i += 2
            continue
        if value == "[[":
            while i < len(tokens) and tokens[i].value != "]]":
                i += 1
            i += 1
            expect_command = False
            continue
        if value in {"((", "$(())"}:
            if value == "$(())":
                i += 1
                expect_command = False
                continue
            while i < len(tokens) and tokens[i].value != "))":
                i += 1
            i += 1
            expect_command = False
            continue
        if not expect_command:
            i += 1
            continue
        if value in {"!", "if", "then", "do", "else", "elif", "while", "until", "time"}:
            expect_command = True
            i += 1
            continue
        if value in {"fi", "done", "}"}:
            expect_command = False
            i += 1
            continue
        if value in {"for", "select"}:
            i += 1
            while i < len(tokens) and tokens[i].value not in {";", "\n", "do"}:
                i += 1
            if i < len(tokens) and tokens[i].value == "do":
                i += 1
                expect_command = True
            else:
                expect_command = False
            continue
        if value == "case":
            while i < len(tokens) and tokens[i].value != "in":
                i += 1
            case_patterns.append(True)
            i += 1
            expect_command = False
            continue
        if ASSIGNMENT.match(value):
            if value.endswith("+=") and i + 1 < len(tokens) and tokens[i + 1].value == "(":
                depth = 0
                i += 1
                while i < len(tokens):
                    if tokens[i].value == "(":
                        depth += 1
                    elif tokens[i].value == ")":
                        depth -= 1
                        if depth == 0:
                            i += 1
                            break
                    i += 1
                expect_command = False
                continue
            i += 1
            continue
        if (
            token.bare
            and IDENTIFIER.match(value)
            and i + 2 < len(tokens)
            and tokens[i + 1].value == "("
            and tokens[i + 2].value == ")"
        ):
            i += 3
            expect_command = True
            continue
        if token.bare and (COMMAND_NAME.match(value) or value == "["):
            calls.append(token)
            arguments, end = scan_simple_command(tokens, i + 1)
            calls.extend(dispatched_command_calls(value, arguments))
            if findings is not None:
                if value in CANCELLABLE_PROMPTS and not prompt_status_is_checked(
                    tokens, i, end, lines
                ):
                    findings.unchecked_prompts.append(token)
                # 要守的性质是「涉密内容必须走标准输入」，因此判定依据是命令是否由管道喂入，
                # 而不是参数里有没有 $ —— 选项值（例如 -l "$level"）本来就允许出现变量
                fed_by_pipe = i > 0 and tokens[i - 1].value == "|"
                if value in STDIN_ONLY_PAYLOAD_TARGETS and not fed_by_pipe:
                    findings.argv_payloads.append(token)
        expect_command = False
        i += 1
    return calls


STATUS_CAPTURE = re.compile(r"^(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=\"?\$\?\"?$")
CLOSING_IF = re.compile(r"(?:^|[;\s])fi$")
INLINE_ELSE = re.compile(r"(?:^|[;\s])(?:else|elif)(?:[;\s]|$)")
FUNCTION_BODY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\) \{$")
PROMPT_READ = re.compile(
    r"\bread\s+-r\s+-p\s+(?:'[^']*'|\"(?:[^\"\\]|\\.)*\"|\S+)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
ARITHMETIC_SPAN = re.compile(r"\(\((.*?)\)\)")


def indent_width(line: str) -> int:
    return len(line) - len(line.lstrip())


def status_captured_after_if(lines: list[str]) -> list[tuple[str, int]]:
    """`if ... fi` 没有 else 分支时退出码恒为 0，之后取 $? 拿不到失败码。"""
    findings: list[tuple[str, int]] = []
    for index, raw in enumerate(lines):
        capture = STATUS_CAPTURE.match(raw.strip())
        if capture is None:
            continue
        name = capture.group(1)
        previous = index - 1
        while previous >= 0 and not lines[previous].strip():
            previous -= 1
        if previous < 0:
            continue
        closing = lines[previous].strip()
        if not CLOSING_IF.search(closing):
            continue
        if closing != "fi":
            if INLINE_ELSE.search(closing) is None:
                findings.append((name, index + 1))
            continue
        indent = indent_width(lines[previous])
        depth = 0
        has_else = False
        scan = previous - 1
        while scan >= 0:
            candidate = lines[scan]
            text = candidate.strip()
            if text and indent_width(candidate) == indent:
                if text == "fi":
                    depth += 1
                elif text.startswith("if ") or text.startswith("if["):
                    if depth == 0:
                        break
                    depth -= 1
                elif depth == 0 and (text == "else" or text.startswith("elif ")):
                    has_else = True
            scan -= 1
        if not has_else:
            findings.append((name, index + 1))
    return findings


def unnormalised_prompt_arithmetic(lines: list[str]) -> list[tuple[str, int]]:
    """用户在提示里输入的十进制数字必须先经 10# 归一，否则 08 会被当成八进制。"""
    findings: list[tuple[str, int]] = []
    start = 0
    while start < len(lines):
        if FUNCTION_BODY.match(lines[start]) is None:
            start += 1
            continue
        end = start + 1
        while end < len(lines) and lines[end] != "}":
            end += 1
        body = lines[start + 1 : end]
        prompted = {match for line in body for match in PROMPT_READ.findall(line)}
        tracked = {
            name
            for name in prompted
            if any(f'"${name}" =~ ^[0-9]+$' in line for line in body)
        }
        normalised: set[str] = set()
        reported: set[str] = set()
        for offset, line in enumerate(body):
            for name in sorted(tracked - reported):
                literal = rf"10#\$\{{?{name}\}}?"
                if re.search(
                    rf'(?<![A-Za-z0-9_]){name}="?\$\(\(\s*{literal}\s*\)\)"?', line
                ):
                    normalised.add(name)
                    continue
                if name in normalised:
                    continue
                bare = re.compile(rf"(?<![A-Za-z0-9_#]){name}(?![A-Za-z0-9_])")
                for span in ARITHMETIC_SPAN.findall(line):
                    if bare.search(re.sub(literal, "", span)):
                        findings.append((name, start + 1 + offset + 1))
                        reported.add(name)
                        break
        start = end + 1
    return findings


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} MANAGER", file=sys.stderr)
        return 2
    manager = Path(sys.argv[1])
    source = manager.read_text(encoding="utf-8")
    source_lines = source.splitlines()
    defined = set(FUNCTION_DEFINITION.findall(source))
    allowed = defined | SHELL_TARGETS | EXTERNAL_TARGETS
    unknown: dict[tuple[str, int], None] = {}
    findings = ConventionFindings()
    giveups: list[tuple[int, str]] = []
    for stream in tokenize(mask_heredoc_bodies(source), 1, giveups):
        for call in command_calls(stream, findings, source_lines):
            if call.value not in allowed:
                unknown[(call.value, call.line)] = None
    failed = False
    for line, reason in sorted(dict.fromkeys(giveups)):
        print(
            f"tokenizer gave up at line {line} ({reason}); "
            "everything after it went unchecked",
            file=sys.stderr,
        )
        failed = True
    if unknown:
        for name, line in sorted(unknown, key=lambda item: (item[1], item[0])):
            print(f"undefined bare command target {name} at line {line}", file=sys.stderr)
        failed = True
    for call in sorted(findings.unchecked_prompts, key=lambda token: token.line):
        print(
            f"unchecked cancellable prompt {call.value} at line {call.line}",
            file=sys.stderr,
        )
        failed = True
    for call in sorted(findings.argv_payloads, key=lambda token: token.line):
        print(
            f"payload passed to {call.value} as an argument at line {call.line}",
            file=sys.stderr,
        )
        failed = True
    lines = source.splitlines()
    for name, line in status_captured_after_if(lines):
        print(
            f"exit status read into {name} after an if without else at line {line}",
            file=sys.stderr,
        )
        failed = True
    for name, line in unnormalised_prompt_arithmetic(lines):
        print(f"prompt value {name} used without 10# at line {line}", file=sys.stderr)
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
