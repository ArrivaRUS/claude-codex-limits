"""Process-wide safety defaults; import before ccl in every test entry point (lesson 006)."""

import atexit
import os
import shutil
import sys
import tempfile

_HOME = os.path.expanduser("~")
# The user's real files (lesson 006). Tests compare presence + mtime only; contents are never read.
REAL_FILES = tuple(os.path.join(_HOME, p) for p in (
    ".config/claude-codex-limits/github-token",
    ".config/claude-codex-limits/machine-id",
    ".local/state/claude-codex-limits/sync-state.json",
    ".local/state/claude-codex-limits/sync-remote.json",
    ".config/claude-codex-limits/github-credentials",
    ".local/state/claude-codex-limits/github-credential-writers",
))


def real_files_state():
    out = {}
    for p in REAL_FILES:
        try:
            out[p] = os.stat(p).st_mtime_ns
        except FileNotFoundError:
            out[p] = None
    return out


REAL_BEFORE = real_files_state()

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
for name in ("CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH"):
    setattr(common, name, os.path.join(ROOT, "cli", name.lower()))
