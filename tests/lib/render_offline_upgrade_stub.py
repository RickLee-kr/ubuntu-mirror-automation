#!/usr/bin/env python3
"""Render offline-upgrade .sh.in templates for fixture tests.

Injects client/lib/dp-offline-destructive-confirmation.sh at
@@DESTRUCTIVE_CONFIRMATION_HELPER@@ before leftover pin stubbing so stubs
remain valid single-file bash scripts.
"""
from __future__ import print_function

import argparse
import json
import re
import sys
from pathlib import Path

HELPER_TOKEN = "@@DESTRUCTIVE_CONFIRMATION_HELPER@@"
HELPER_NAME = "dp-offline-destructive-confirmation.sh"


def load_helper(template_path):
    helper_path = template_path.resolve().parent / "lib" / HELPER_NAME
    if not helper_path.is_file():
        raise SystemExit("missing confirmation helper: {}".format(helper_path))
    return helper_path.read_text(encoding="utf-8").rstrip("\n") + "\n"


def render_template(template_path, pins, leftover="stub"):
    text = template_path.read_text(encoding="utf-8")
    if HELPER_TOKEN not in text:
        raise SystemExit(
            "template missing {}: {}".format(HELPER_TOKEN, template_path)
        )
    text = text.replace(HELPER_TOKEN, load_helper(template_path))
    for key, val in pins.items():
        token = "@@{}@@".format(key)
        text = text.replace(token, val)
    text = re.sub(r"@@[A-Z0-9_]+@@", leftover, text)
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("template")
    ap.add_argument("output")
    ap.add_argument(
        "--pins-json",
        default="",
        help="JSON object of pin replacements (@@KEY@@)",
    )
    ap.add_argument(
        "--leftover",
        default="stub",
        help="replacement for any remaining @@TOKEN@@ (default: stub)",
    )
    args = ap.parse_args(argv)

    template_path = Path(args.template)
    pins = {}
    if args.pins_json:
        pins = json.loads(args.pins_json)
        if not isinstance(pins, dict):
            raise SystemExit("--pins-json must be a JSON object")

    body = render_template(template_path, pins, leftover=args.leftover)
    out = Path(args.output)
    out.write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
