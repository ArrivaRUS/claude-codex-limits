"""Process-wide safety defaults; import before ccl in every test entry point (lesson 006)."""

import atexit
import os
import shutil
import sys
import tempfile

ROOT = tempfile.mkdtemp(prefix="ccl-tests-")
atexit.register(shutil.rmtree, ROOT, ignore_errors=True)
for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
    os.environ["XDG_" + kind + "_HOME"] = os.path.join(ROOT, kind.lower())

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ccl import common, vault  # noqa: E402

vault._ss = lambda: None

from ccl import sync  # noqa: E402


def no_network(*args, **kwargs):
    raise AssertionError("сеть в тестах запрещена")


sync.transport = no_network
# Also protect helpers outside sync (updates, limits); tests may install their own fakes.
common.http = no_network
# XDG does not isolate the CLI credential and transcript paths.
for name in ("CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH"):
    setattr(common, name, os.path.join(ROOT, "cli", name.lower()))
