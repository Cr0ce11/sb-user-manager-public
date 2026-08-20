#!/usr/bin/env python3
"""Reject kernel adapter functions that implement only one proxy kernel.

The adapter in ``src/05-kernel.sh`` is the single place that knows how each
proxy kernel is invoked.  A function there that names one kernel but not the
other silently makes every deployment behave like that kernel: a mihomo machine
would be handed sing-box shaped commands and would produce bad data instead of
an error.  Operations that a kernel does not support yet must still spell out
that kernel's branch and fail loudly inside it.

Functions that reach the kernel only through the accessor helpers do not name a
kernel at all and are therefore not required to dispatch -- writing the same
``case`` twice is how the two copies drift apart.

Usage: check-kernel-dispatch.py <adapter.sh>...
Prints the offending function names and exits non-zero when any are found.
"""

from __future__ import annotations

import re
import sys

FUNCTION = re.compile(r"^([a-z_][a-z0-9_]*)\(\) \{\n(.*?)^\}$", re.S | re.M)
SINGBOX = re.compile(r"sing-box|SINGBOX_|singbox\)")
MIHOMO = re.compile(r"mihomo|MIHOMO_")


def offending_functions(source: str) -> list[str]:
    """Functions naming exactly one kernel.

    The rule is symmetric: a function that names either kernel must name both.
    That covers dispatching functions (a missing ``mihomo)`` arm leaves no
    mihomo token behind) and the few functions that legitimately list both
    kernels without branching, such as the union of deployment paths.
    """
    offenders = []
    for match in FUNCTION.finditer(source):
        name, body = match.group(1), match.group(2)
        names_singbox = bool(SINGBOX.search(body))
        names_mihomo = bool(MIHOMO.search(body))
        if names_singbox == names_mihomo:
            continue
        offenders.append(name)
    return offenders


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: check-kernel-dispatch.py <adapter.sh>...", file=sys.stderr)
        return 2
    found = False
    for path in argv[1:]:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for name in offending_functions(source):
            print(f"{path}: {name} names one proxy kernel but not the other")
            found = True
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
