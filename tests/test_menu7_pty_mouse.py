#!/usr/bin/env python3
"""PTY regression: Menu 7 dialog argv includes --no-mouse; mouse CSI must not close viewer."""
from __future__ import annotations

import os
import pty
import select
import subprocess
import sys
import tempfile
import time


def main() -> int:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    installer = os.path.join(root, "scripts", "install-dp-upgrade-mirror.sh")
    tmp = tempfile.mkdtemp(prefix="menu7-pty-")
    argv_log = os.path.join(tmp, "dialog.argv")
    sample = os.path.join(tmp, "cmds.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("cd /home/aella && echo sample\n")

    stub = os.path.join(tmp, "dialog")
    # Stub dialog: record argv, ignore mouse CSI, exit only on 'q' / ESC / Exit.
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >'{argv_log}'
# Drain stdin until explicit keyboard close (q / ESC).
while IFS= read -r -n1 -t 30 ch || true; do
  # ESC
  if [[ "$ch" == $'\\x1b' ]]; then
    # If this is a mouse CSI (ESC [ M ...), consume and continue.
    rest=""
    read -r -n1 -t 0.05 n1 || true
    if [[ "$n1" == "[" ]]; then
      read -r -n1 -t 0.05 n2 || true
      if [[ "$n2" == "M" ]]; then
        # X10 mouse: 3 more bytes
        read -r -n3 -t 0.05 _ || true
        continue
      fi
    fi
    exit 0
  fi
  if [[ "$ch" == "q" || "$ch" == "Q" ]]; then
    exit 0
  fi
done
exit 0
"""
        )
    os.chmod(stub, 0o755)

    lib = os.path.join(tmp, "lib.sh")
    with open(installer, encoding="utf-8") as src, open(lib, "w", encoding="utf-8") as dst:
        for line in src:
            if line.startswith("SCRIPT_DIR="):
                dst.write(f'SCRIPT_DIR="{root}/scripts"\n')
            elif line.strip() == 'main "$@"':
                continue
            else:
                dst.write(line)

    driver = os.path.join(tmp, "driver.sh")
    with open(driver, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
set -euo pipefail
export PATH='{tmp}:/usr/bin:/bin'
export HEIGHT=40 WIDTH=100
# shellcheck disable=SC1090
source '{lib}'
mm_menu7_textbox "DP Client Upgrade Commands" '{sample}'
echo VIEWER_CLOSED
"""
        )
    os.chmod(driver, 0o755)

    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)

    # Give dialog stub time to start
    time.sleep(0.2)
    # Representative X10 mouse button-press CSI: ESC [ M btn x y
    mouse = b"\x1b[M !! "  # button/space + coords
    os.write(master, mouse)
    time.sleep(0.2)
    # Drag / motion-ish second event
    os.write(master, b"\x1b[M@!!")
    time.sleep(0.3)

    # Process must still be running (mouse must not close viewer)
    if proc.poll() is not None:
        os.close(master)
        print("FAIL: viewer exited after mouse CSI", file=sys.stderr)
        return 1

    # Explicit keyboard close
    os.write(master, b"q")
    deadline = time.time() + 5
    while proc.poll() is None and time.time() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                os.read(master, 4096)
            except OSError:
                break
        time.sleep(0.05)
    os.close(master)
    rc = proc.wait(timeout=5)

    if not os.path.isfile(argv_log):
        print("FAIL: dialog argv log missing", file=sys.stderr)
        return 1
    argv = open(argv_log, encoding="utf-8").read()
    if "--no-mouse" not in argv or "--textbox" not in argv:
        print(f"FAIL: argv missing flags: {argv!r}", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"FAIL: driver rc={rc}", file=sys.stderr)
        return 1

    print("PASS: Menu 7 PTY mouse CSI ignored until keyboard close")
    print("TEST_MENU7_PTY_MOUSE=PASS")
    print(f"DIALOG_ARGV={argv.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
