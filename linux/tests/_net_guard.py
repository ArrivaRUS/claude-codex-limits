"""Shared network guard for tests that run a fresh copy of ccl/common.py (REMOTE-LIMITS A4-10, debt N8).

Why: `_isolate` replaces the imported `common.http` with a hard failure, so tests of the real HTTP client load a
private copy of `ccl/common.py`. Such a copy can open real sockets. The old per-test watchdogs raised
`AssertionError` from `connect`; `common.http` catches `Exception` and turns it into `Resp(0)` — the test then sees
"network down" and may pass on an empty path (T2-r3 N8). This guard:
  * allows loopback only (127.0.0.0/8, ::1, "localhost") and AF_UNIX paths;
  * raises `ForeignConnect`, a BaseException (not Exception), so `except Exception` cannot swallow it;
  * also records every refused attempt and fails the test in cleanup, even if some code catches BaseException;
  * guards name resolution too (`getaddrinfo`), so a non-loopback host name never reaches DNS.

Use:  probe = _net_guard.fresh_common(self)      # private copy of ccl/common.py + guard + no proxies
      guard = _net_guard.install(self)            # guard only (e.g. around in-process code that uses sockets)
"""

import _socket
import importlib.util
import ipaddress
import os
import socket
from unittest import mock

COMMON_PY = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ccl", "common.py")
_REAL_CONNECT = _socket.socket.connect
_REAL_CONNECT_EX = _socket.socket.connect_ex
_REAL_GETADDRINFO = socket.getaddrinfo
_REAL_CREATE_CONNECTION = socket.create_connection
PROXY_VARS = ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")


class ForeignConnect(BaseException):
    """A non-loopback connect/resolve in a test. Deliberately not an Exception subclass."""


def is_loopback_host(host):
    if isinstance(host, bytes):
        host = host.decode("ascii", "replace")
    if not isinstance(host, str):
        return False
    if host.lower() in ("localhost", "localhost.", "ip6-localhost"):
        return True
    try:
        return ipaddress.ip_address(host.split("%", 1)[0].strip("[]")).is_loopback
    except ValueError:
        return False


def is_loopback_address(address):
    if isinstance(address, (str, bytes)):          # AF_UNIX socket path (D-Bus etc.) — not network
        return True
    return isinstance(address, tuple) and bool(address) and is_loopback_host(address[0])


class Guard(object):
    def __init__(self, exc=ForeignConnect):
        self.exc = exc
        self.attempts = []

    def check(self, what, ok, target):
        if not ok:
            self.attempts.append((what, repr(target)))
            raise self.exc("сеть в тестах запрещена (не loopback): %s %r" % (what, target))

    def take(self):
        """Return and clear recorded attempts (for tests that provoke one on purpose)."""
        out, self.attempts[:] = list(self.attempts), []
        return out


def install(testcase, exc=ForeignConnect):
    """Loopback-only sockets for the duration of `testcase`. `exc` exists only for the mutation meta-test."""
    guard = Guard(exc)

    def connect(sock, address):
        guard.check("connect", is_loopback_address(address), address)
        return _REAL_CONNECT(sock, address)

    def connect_ex(sock, address):
        guard.check("connect_ex", is_loopback_address(address), address)
        return _REAL_CONNECT_EX(sock, address)

    def getaddrinfo(host, *args, **kwargs):
        guard.check("getaddrinfo", host is None or is_loopback_host(host), host)
        return _REAL_GETADDRINFO(host, *args, **kwargs)

    def create_connection(address, *args, **kwargs):
        # Replaces any older blanket ban on create_connection (RLEnv): resolution and connect go through the guard.
        guard.check("create_connection", isinstance(address, tuple) and is_loopback_host(address[0]), address)
        return _REAL_CREATE_CONNECTION(address, *args, **kwargs)

    for target, value in (("socket.socket.connect", connect), ("socket.socket.connect_ex", connect_ex),
                          ("socket.getaddrinfo", getaddrinfo), ("socket.create_connection", create_connection)):
        p = mock.patch(target, value)
        p.start()
        testcase.addCleanup(p.stop)
    # Registered after the patches: runs first in cleanup (LIFO), while the record is still the test's own.
    testcase.addCleanup(lambda: testcase.assertEqual(
        guard.attempts, [], "тест пытался выйти в сеть (не loopback), даже если исключение было поглощено"))
    return guard


def no_proxies(testcase):
    p = mock.patch.dict(os.environ, {"no_proxy": "*", "NO_PROXY": "*"})   # restores proxy variables too
    p.start()
    testcase.addCleanup(p.stop)
    for k in PROXY_VARS:
        os.environ.pop(k, None)


def fresh_common(testcase, name="ccl_common_fresh_a4", exc=ForeignConnect):
    """A private copy of ccl/common.py with the real `http`, under the loopback-only guard, without proxies."""
    no_proxies(testcase)
    testcase.net_guard = install(testcase, exc)
    spec = importlib.util.spec_from_file_location(name, COMMON_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
