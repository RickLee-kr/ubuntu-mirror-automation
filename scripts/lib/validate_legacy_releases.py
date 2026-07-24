#!/usr/bin/env python3
"""Thin CLI wrapper: validate legacy (Xenial) offline release snapshots."""
from __future__ import print_function

import sys

import sync_legacy_releases as slr


def main(argv=None):
    argv = list(argv if argv is not None else sys.argv[1:])
    if not argv or argv[0] in ("-h", "--help"):
        return slr.main(["validate", "--help"])
    if argv[0] != "validate":
        argv = ["validate"] + argv
    return slr.main(argv)


if __name__ == "__main__":
    sys.exit(main())
