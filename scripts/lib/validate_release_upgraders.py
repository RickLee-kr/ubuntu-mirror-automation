#!/usr/bin/env python3
"""CLI wrapper: validate local meta-release / release upgraders (P0-3).

Delegates to sync_release_upgraders.validate. Exit non-zero on FAIL.
"""
from __future__ import print_function

import os
import sys

_LIB = os.path.dirname(os.path.abspath(__file__))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from sync_release_upgraders import main as sync_main  # noqa: E402


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in ("-h", "--help"):
        return sync_main(["validate", "--help"])
    if not argv or argv[0] != "validate":
        argv = ["validate"] + argv
    return sync_main(argv)


if __name__ == "__main__":
    sys.exit(main())
