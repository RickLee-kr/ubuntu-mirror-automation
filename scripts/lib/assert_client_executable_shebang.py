#!/usr/bin/env python3
"""Assert kernel-executable shell heredocs start with a shebang.

Invariant: any body written via install/cat heredoc that becomes a chmod 0755
systemd ExecStart target must begin at byte 0 with '#!'.
"""
from __future__ import print_function

import re
import sys


class ShebangError(ValueError):
    pass


# Quoted heredoc openers used by offline-upgrade clients for executables.
_HEREDOC_RE = re.compile(
    r"""(?:install\s+-m\s+0755\s+/dev/stdin[^\n]*|\{)\s*<<['\"]?(POSTBOOT|POSTBOOT_HDR|RUNNER)['\"]?\s*\n""",
    re.MULTILINE,
)


def extract_heredoc_body(script_body, marker):
    """Return text between <<'MARKER' and the closing MARKER line."""
    open_re = re.compile(
        r"<<['\"]?{marker}['\"]?\s*\n".format(marker=re.escape(marker))
    )
    match = open_re.search(script_body)
    if not match:
        return None
    start = match.end()
    close_re = re.compile(r"(?m)^{marker}\s*$".format(marker=re.escape(marker)))
    close = close_re.search(script_body, start)
    if not close:
        raise ShebangError("unclosed heredoc marker {!r}".format(marker))
    return script_body[start : close.start()]


def assert_body_shebang_first(label, body):
    if body is None:
        return
    if not body.startswith("#!"):
        first = body.splitlines()[0] if body else ""
        raise ShebangError(
            "{} executable body must start with '#!' (first line={!r})".format(
                label, first[:120]
            )
        )
    first_line = body.splitlines()[0]
    if not first_line.startswith("#!"):
        raise ShebangError(
            "{} shebang line invalid: {!r}".format(label, first_line[:120])
        )


def assert_client_executable_shebangs(script_body, hop_label="client"):
    """Validate POSTBOOT / POSTBOOT_HDR / RUNNER heredoc bodies in a rendered client."""
    checked = []
    for marker in ("POSTBOOT_HDR", "POSTBOOT", "RUNNER"):
        body = extract_heredoc_body(script_body, marker)
        if body is None:
            continue
        assert_body_shebang_first("{}/{}".format(hop_label, marker), body)
        checked.append(marker)
    if "POSTBOOT" not in checked and "POSTBOOT_HDR" not in checked:
        raise ShebangError(
            "{} missing POSTBOOT or POSTBOOT_HDR executable heredoc".format(hop_label)
        )
    if "RUNNER" not in checked:
        raise ShebangError("{} missing RUNNER executable heredoc".format(hop_label))
    return checked


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 1:
        print(
            "usage: assert_client_executable_shebang.py SCRIPT [HOP_LABEL]",
            file=sys.stderr,
        )
        return 2
    path = argv[0]
    label = argv[1] if len(argv) > 1 else path
    with open(path, "r", encoding="utf-8") as fh:
        body = fh.read()
    checked = assert_client_executable_shebangs(body, label)
    print("SHEBANG_OK={} markers={}".format(label, ",".join(checked)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ShebangError as exc:
        print("SHEBANG_FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
