"""Process-wide safety defaults; import before ccl in every test entry point (lesson 006).

The owner's real files are protected by `_real_guard` (imported first, before XDG_* move): every write-like
operation of the test process on them is refused and recorded, children with real app directories are refused.
No mtime comparison: an installed publisher on this machine (A5) rewrites its state files every 5 minutes.
"""

import atexit
import os
import shutil
import sys
import tempfile

if __package__:
    from . import _real_guard  # noqa: E402  (before anything moves XDG_* or HOME)
else:
    import _real_guard  # noqa: E402

ROOT = tempfile.mkdtemp(prefix="ccl-tests-", dir="/tmp")
atexit.register(shutil.rmtree, ROOT, ignore_errors=True)
for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
    os.environ["XDG_" + kind + "_HOME"] = os.path.join(ROOT, kind.lower())

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ccl import common, vault  # noqa: E402


def no_network(*args, **kwargs):
    raise AssertionError("сеть в тестах запрещена")


vault._ss = no_network
if hasattr(vault, "_ss_v2"):
    vault._ss_v2 = no_network
# Default construction is never a test dependency: explicit fake adapters only.
if hasattr(vault, "CredentialStore"):
    vault.CredentialStore.__init__ = no_network

from ccl import sync  # noqa: E402

if hasattr(sync, "auth_owner"):
    sync.auth_owner = no_network
sync.transport = no_network
# Also protect helpers outside sync (updates, limits); tests may install their own fakes.
common.http = no_network
# XDG does not isolate the CLI credential and transcript paths.
# CLAUDE_JSON (~/.claude.json, REMOTE-LIMITS identity source) is redirected before it even exists.
for name in ("CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH", "CLAUDE_JSON"):
    setattr(common, name, os.path.join(ROOT, "cli", name.lower()))
