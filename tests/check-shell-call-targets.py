#!/usr/bin/env python3
"""Reject bare shell command calls that have no declared target.

This is deliberately a conservative, dependency-free Bash scanner rather than a
full parser.  It follows simple-command boundaries, nested command
substitutions, loops and case arms closely enough to audit the generated
manager.  Quoted or dynamically expanded command names are outside this gate.
"""

from __future__ import annotations

from dataclasses import dataclass
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
            elif quote == '"' and source.startswith("$(", i):
                depth += 1
                i += 1
            elif quote == '"' and char == ")":
                depth -= 1
                if depth == 0:
                    return i
        elif char in "'\"":
            quote = char
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


def tokenize(source: str, first_line: int = 1) -> list[list[Token]]:
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
                    value.append(source[i:])
                    i = len(source)
                    bare = False
                    break
                inner = source[i + 2 : end]
                streams.extend(tokenize(inner, line))
                line += inner.count("\n")
                value.append("$()")
                bare = False
                i = end + 1
                continue
            if source.startswith("${", i):
                end = matching_parameter_expansion(source, i + 2)
                if end is None:
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
                        i += 1
                        break
                    elif quote == '"' and source.startswith("$((", i):
                        value.pop()
                        end = matching_arithmetic_expansion(source, i + 3)
                        if end is None:
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
                            value.append(source[i:])
                            i = len(source)
                            break
                        inner = source[i + 2 : end]
                        streams.extend(tokenize(inner, line))
                        line += inner.count("\n")
                        value.append("$()")
                        i = end + 1
                        continue
                    elif quote == '"' and source.startswith("${", i):
                        value.pop()
                        end = matching_parameter_expansion(source, i + 2)
                        if end is None:
                            value.append(source[i:])
                            i = len(source)
                            break
                        value.append("${}")
                        line += source[i + 2 : end].count("\n")
                        i = end + 1
                        continue
                    i += 1
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


def simple_command_arguments(tokens: list[Token], start: int) -> list[Token]:
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
    return arguments


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


def command_calls(tokens: list[Token]) -> list[Token]:
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
            calls.extend(dispatched_command_calls(value, simple_command_arguments(tokens, i + 1)))
        expect_command = False
        i += 1
    return calls


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} MANAGER", file=sys.stderr)
        return 2
    manager = Path(sys.argv[1])
    source = manager.read_text(encoding="utf-8")
    defined = set(FUNCTION_DEFINITION.findall(source))
    allowed = defined | SHELL_TARGETS | EXTERNAL_TARGETS
    unknown: dict[tuple[str, int], None] = {}
    for stream in tokenize(mask_heredoc_bodies(source)):
        for call in command_calls(stream):
            if call.value not in allowed:
                unknown[(call.value, call.line)] = None
    if unknown:
        for name, line in sorted(unknown, key=lambda item: (item[1], item[0])):
            print(f"undefined bare command target {name} at line {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
