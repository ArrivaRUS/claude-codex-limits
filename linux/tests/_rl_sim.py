"""TwoMachineSim — two (or more) publishers in one process over virtual time (test plan §0, A3-20).

Every machine is a separate sandbox: its own XDG config/state, HOME with CLI login files, machine id, fake Secret
Service, AuthOwner, sync state and O1 journal. A timer tick = a NEW process: module caches are dropped and
`ccl.publisher` / `ccl.coordination` are re-imported before `publisher.run_pass("auto")` (that is how systemd runs it).
Shared: one FakeGist (true clock; Date = true time; per-reader visibility delay; scripted outages), one provider
(answers depend on TRUE time; asOf = the polling machine's clock). Machine clocks = true time + skew.

Contract relied upon (beyond test_rl_publisher): run_pass reads every path from ccl.common at call time (no module-level
path constants), and keeps no state between processes except files.
"""

import importlib
import math
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

if __package__:
    from . import _rl_env as rl
    from . import _sync_env
else:
    import _rl_env as rl
    import _sync_env

from ccl import auth, common, limits, sync, vault

T0 = rl.NOW
DAY = 86400
TICK = 300
WINDOW = 18000          # provider session window in the simulation (5 h)


class Machine(object):
    def __init__(self, sim, idx, phase, skew=0.0):
        self.sim, self.idx = sim, idx
        self.name = "m%d" % idx
        self.id = "00000000-0000-4000-8000-%012d" % idx
        self.phase, self.skew = float(phase), float(skew)
        root = os.path.join(sim.env.tmp, "sim%d-%s" % (sim.seq, self.name))
        self.paths = {n: v.replace(sim.env.tmp, root, 1) for n, v in sim.base_paths.items()}
        self.home = sim.env.home.replace(sim.env.tmp, root, 1)
        self.ss = _sync_env.FakeSecretService()
        self.pending = {}
        self.first_attempt = None
        self.owner = None
        self.errors = []


class Sim(object):
    _count = 0

    def __init__(self, env, mode="active", delay=0.0):
        Sim._count += 1
        self.seq = Sim._count            # every Sim gets fresh machine roots
        self.env = env
        self.true = T0
        self.ledger = rl.Ledger(lambda: self.true)
        self.gist = rl.FakeGist(lambda: self.true, self.ledger)
        self.gist.delay = float(delay)
        self.providers = rl.FakeProviders(lambda: time.time(), self.ledger)
        self.providers.default = self.reading
        self.providers.who = lambda: self.current.name if self.current else None
        self.mode = mode if callable(mode) else (lambda t, m=mode: m)
        self.machines = []
        self.current = None
        self.hostile = None
        self.scheduled = []          # (true time, callable(sim))
        self.base_paths = {n: v for n, v in vars(common).items()
                           if n.isupper() and isinstance(v, str) and v.startswith(env.tmp + os.sep)}
        self.base_paths["HOME"] = common.HOME
        for owner, name, value in ((time, "time", self.machine_now), (time, "sleep", self.sleep),
                                   (limits, "fetch_claude", self.providers.fetch_claude),
                                   (limits, "fetch_codex", self.providers.fetch_codex),
                                   (os, "fsync", lambda fd: None)):
            p = mock.patch.object(owner, name, value)
            p.start()
            env.addCleanup(p.stop)
        sync.transport = self.gist                       # SyncEnv.tearDown restores

    # ---- clocks ----
    def machine_now(self):
        return self.true + (self.current.skew if self.current else 0.0)

    def sleep(self, seconds):
        seconds = max(0.0, float(seconds))
        if seconds > 120:
            raise AssertionError("sleep %.1f s внутри прохода" % seconds)
        self.true += seconds

    # ---- provider (truth = true time) ----
    def reading(self, product, now):
        t = self.true - T0
        if self.mode(self.true) == "active":
            k = int(t // WINDOW)
            d = rl.reading(now, session=round((t % WINDOW) / 900.0 * 1.5, 3), weekly=10.0)
            d.session_reset = T0 + (k + 1) * WINDOW
        else:
            d = rl.reading(now, session=40.0, weekly=20.0)
            d.session_reset = T0 + 3 * DAY
        d.weekly_reset = T0 + 6 * DAY
        return d

    # ---- machines ----
    def add(self, phase, skew=0.0, claude=rl.U_A, codex=rl.CODEX_ID):
        m = Machine(self, len(self.machines) + 1, phase, skew)
        self.machines.append(m)
        self.activate(m)
        os.makedirs(os.path.dirname(common.MACHINE_ID_PATH), exist_ok=True)
        with open(common.MACHINE_ID_PATH, "w", encoding="utf-8") as f:
            f.write(m.id + "\n")
        common.ensure_dirs()
        if claude:
            self.env.write_claude_json(claude)
        if codex:
            self.env.write_codex_auth(codex)
        self.env.write_settings(publisher=True, autoPoll=True, credential_write="never", machineName=m.name)
        self.env.sign_in()
        self.deactivate()
        return m

    def _owner(self):
        def no_v2(*args, **kwargs):
            raise AssertionError("unexpected V2 credential boundary in the simulator")
        store = SimpleNamespace(read=no_v2, stage_refresh=no_v2, delete=no_v2, write_settled=no_v2, login_backend=no_v2)

        def identity(token):
            reply = sync.gh("/user", token)
            return reply.status, reply.json(), reply.headers
        return auth.AuthOwner(auth.LinuxManifest(), store, sync._form_result, identity,
                              lambda: common.file_lock("sync", timeout=0.3), lambda: time.time(),
                              legacy=sync._legacy_credential, defer=vault._sigint_deferred,
                              publication_lock=lambda: sync._login_lock)

    def activate(self, m):
        for n, v in m.paths.items():
            setattr(common, n, v)
        os.environ["HOME"] = m.home
        common._state = common._settings = None
        sync._first_attempt_at = m.first_attempt
        vault._ss = m.ss.factory
        if m.owner is None:
            m.owner = self._owner()
        sync.auth_owner = lambda: m.owner
        limits._PENDING = m.pending
        self.gist.reader = m.name
        self.current = m
        for name in ("ccl.publisher", "ccl.coordination"):      # a timer tick is a new process
            if name in sys.modules:
                importlib.reload(sys.modules[name])

    def deactivate(self):
        if self.current is not None:
            self.current.first_attempt = sync._first_attempt_at
        self.current = None

    def on_machine(self, m, fn):
        self.activate(m)
        try:
            return fn()
        finally:
            self.deactivate()

    # ---- running ----
    def at(self, true_offset, fn):
        self.scheduled.append((T0 + true_offset, fn))

    def run(self, hours=24.0, extra=0.0):
        pub = importlib.import_module("ccl.publisher")   # ImportError = the contract is missing (red)
        end = T0 + hours * 3600 + extra
        ticks = []
        for m in self.machines:
            t = T0 + m.phase
            while t < end:
                ticks.append((t, m.idx, m))
                t += TICK
        ticks.sort(key=lambda x: (x[0], x[1]))
        pending = sorted(self.scheduled, key=lambda x: x[0])
        for t, _idx, m in ticks:
            while pending and pending[0][0] <= t:
                self.true = pending[0][0]
                pending.pop(0)[1](self)
            self.true = t
            self.activate(m)
            pub = sys.modules["ccl.publisher"]
            if self.hostile:
                self.hostile(self, m)
            try:
                pub.run_pass("auto")
            except Exception as e:  # noqa: BLE001 — run_pass must never raise (A3-21)
                m.errors.append("%s at +%d" % (type(e).__name__, t - T0))
            finally:
                self.deactivate()
        return self

    # ---- results ----
    def requests(self, product=None, machine=None):
        return [e for e in self.ledger.events if e.kind == "provider" and (product is None or e.product == product)
                and (machine is None or e.machine == machine)]

    def pairs(self, product, since=0.0, until=math.inf):
        """Consecutive requests for one account (product, local id) closer than 900 s (true time), any machines."""
        out = []
        by_account = {}
        for e in self.requests(product):
            by_account.setdefault(e.account, []).append(e)
        for reqs in by_account.values():
            reqs.sort(key=lambda e: e.t)
            for a, b in zip(reqs, reqs[1:]):
                if b.t - a.t < 900 and T0 + since <= b.t < T0 + until:
                    out.append((a.t - T0, b.t - T0, a.machine, b.machine))
        return out

    def count(self, kind, machine):
        return len([e for e in self.ledger.events if e.kind == kind and e.reader == machine])

    def journal(self, m):
        return rl.read_o1(m.paths["STATE_DIR"])

    def errors(self):
        return [(m.name, err) for m in self.machines for err in m.errors]
