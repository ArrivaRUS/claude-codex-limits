"""Build only whitelisted Swift declarations + fixtures, never the full application.
Run from a temporary source snapshot: python3 linux/tests/_freshness_swift_runner.py
"""
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/LimitsMonitor.swift'
DECLARATIONS = ('enum AuthState', 'struct ScopedLimit', 'struct LimitData', 'struct UsageSample',
                'final class UsageHistory', 'struct WindowPace', 'func windowPace',
                'struct PacedLimit', 'func pacedLimits', 'func snapshotWindowPace',
                'func metricIsStale', 'func isStale', 'struct AutoReading', 'struct AutoPollState',
                'func fetchCodex', 'func withPollStatus', 'func ld2dict')


def declaration(text, name):
    match = re.search(r'^' + re.escape(name) + r'\b[^\n]*', text, flags=re.M)
    if not match:
        raise AssertionError('missing whitelist declaration: ' + name)
    if match.group(0).split('//', 1)[0].rstrip().endswith('}'):
        return match.group(0) + '\n'
    end = re.search(r'^}\s*$', text[match.end():], flags=re.M)
    if not end:
        raise AssertionError('unterminated whitelist declaration: ' + name)
    return text[match.start():match.end() + end.end()] + '\n'


def owner_method(text, name):
    match = re.search(r'^    (?:@objc )?func ' + re.escape(name) + r'\b[^\n]*', text, flags=re.M)
    if not match:
        raise AssertionError('missing owner method: ' + name)
    end = re.search(r'^    }\s*$', text[match.end():], flags=re.M)
    if not end: raise AssertionError('unterminated owner method: ' + name)
    return text[match.start():match.end() + end.end()].replace('@objc ', '') + '\n'


def main():
    text = SOURCE.read_text()
    blocks = '\n'.join(declaration(text, name) for name in DECLARATIONS)
    # Fail closed if a new production dependency escapes this harness' reviewed boundary.
    banned = r'\b(URLSession|URLRequest|Process|UserDefaults|NSApplication|AppDelegate|Security|Keychain|UsageLogs|fetchClaude)\b'
    if re.search(banned, blocks):
        raise AssertionError('whitelist acquired an unreviewed runtime boundary')
    scratch = Path(tempfile.mkdtemp(prefix='ccl-fresh4h-swift-', dir='/private/tmp'))
    prologue = ('import Foundation\n'
                'let SNAPSHOT_MAX_AGE: TimeInterval = 14400\n'
                'let AUTO_STEPS: [TimeInterval] = [900,1800,3600,14400]\n'
                'let HISTORY_KEEP_DAYS: Double = 35\n'
                'let HISTORY_PATH = ' + json.dumps(str(scratch / 'history.jsonl')) + '\n'
                'func productEnabled(_ product: String) -> Bool { true }\n'
                'func tr(_ ru: String, _ en: String) -> String { en }\n'
                'var fakeRollout = LimitData(), fakeCache: LimitData? = nil, fakeLive: LimitData? = nil\n'
                'var liveCalls = 0\n'
                'func codexFromRollout() -> LimitData { fakeRollout }\n'
                'func loadCodexCache() -> LimitData? { fakeCache }\n'
                'func codexUsageLive() -> LimitData? { liveCalls += 1; return fakeLive }\n')
    program = scratch / 'main.swift'
    owner_names = ('startTimer', 'limitsWithPollStatus', 'publishAutoIntervals', 'setInterval', 'statusClicked', 'render')
    # render is constrained to the actual AppDelegate section, not preview/UI methods.
    owner_text = text[text.index('final class AppDelegate:'):text.index('if !CommandLine.arguments.contains', text.index('final class AppDelegate:'))]
    methods = '\n'.join(owner_method(owner_text, name) for name in owner_names)
    if re.search(r'\b(Process|URLSession|URLRequest|Keychain|DispatchQueue|NSApplication)\b', methods):
        raise AssertionError('owner handler acquired an unreviewed I/O boundary')
    fixture = (ROOT / 'linux/tests/fixtures/freshness_4h.swift').read_text()
    trailer = fixture.index('print("FRESH-4H Swift whitelist harness:')
    declarations = (ROOT / 'linux/tests/fixtures/freshness_interval_env.swift').read_text() + methods + '}\n'
    program.write_text(prologue + blocks + declarations + fixture[:trailer] +
                       (ROOT / 'linux/tests/fixtures/freshness_interval_checks.swift').read_text() + fixture[trailer:])
    print('source SHA256:', hashlib.sha256(SOURCE.read_bytes()).hexdigest(), flush=True)
    print('generated audited whitelist:', program, flush=True)
    executable = scratch / 'freshness-tests'
    subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(scratch / 'module-cache'),
                    str(program), '-o', str(executable)], check=True)
    return subprocess.run([str(executable)], check=False).returncode


if __name__ == '__main__':
    raise SystemExit(main())
