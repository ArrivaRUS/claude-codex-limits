"""Full-suite CI entry point. Refuse an environment lacking the promised isolation."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import sys
import unittest


def preflight():
    assert sys.platform == 'linux', 'Linux CI only'
    account = pwd.getpwuid(os.getuid())
    assert os.getuid() == 10001 and account.pw_name == 'ccltest', 'dedicated non-root account required'
    assert Path.home() == Path(account.pw_dir) == Path('/home/ccltest'), 'login must use synthetic account home'
    for name in ('DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS', 'DISPLAY', 'WAYLAND_DISPLAY', 'SSH_AUTH_SOCK'):
        assert not os.environ.get(name), 'unexpected inherited session: ' + name
    for name in ('GITHUB_TOKEN', 'GH_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'AWS_ACCESS_KEY_ID', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY'):
        assert not os.environ.get(name), 'unexpected inherited credential environment'
    for path in ('/run/dbus/system_bus_socket', '/run/user/10001/bus', '/var/run/docker.sock'):
        assert not Path(path).exists(), 'host service socket visible'
    for leaf in ('.claude', '.codex', '.local/share/keyrings', '.local/share/kwalletd'):
        assert not (Path.home() / leaf).exists(), 'home is not a clean synthetic fixture'
    assert {p.name for p in Path('/sys/class/net').iterdir()} == {'lo'}, 'network namespace must contain only loopback'
    # Prove local TCP fixtures can work without contacting any external address.
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0)); server.listen(1)
        with socket.create_connection(server.getsockname(), timeout=2) as client:
            peer, _ = server.accept()
            with peer:
                client.sendall(b'fixture')
                assert peer.recv(7) == b'fixture', 'loopback is unavailable'
    assert os.environ.get('QT_QPA_PLATFORM') == 'offscreen'
    assert importlib.util.find_spec('PyQt5') and importlib.util.find_spec('dbus'), 'full-suite dependencies absent'
    assert shutil.which('dpkg-deb'), 'package tests must not skip'
    return {'uid': os.getuid(), 'home': str(Path.home()), 'interfaces': ['lo'],
            'external_network': 'no external interface', 'loopback_tcp': 'passed',
            'session_bus': 'no address or socket', 'credential_env': 'absent'}


def main():
    report = preflight()  # Before importing any ccl module or test.
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root / 'linux/tests'))
    suite = unittest.defaultTestLoader.discover(str(root / 'linux/tests'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report.update(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors), skips=len(result.skipped))
    Path('/artifacts/ci-isolation.json').write_text(json.dumps(report, indent=2) + '\n')
    # Do not silently turn missing Qt/dpkg into a passing full-suite report.
    if not result.wasSuccessful() or result.skipped:
        return 1
    subprocess.run(['sh', str(root / 'linux/packaging/build-deb.sh'), '/artifacts/deb'], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
