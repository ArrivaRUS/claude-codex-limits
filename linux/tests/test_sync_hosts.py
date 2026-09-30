"""Token boundary, raw_url failures and secret-gist discovery (docs/sync-protocol.md → Transport,
Read and merge). No request leaves the process except to a loopback server started by the test."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import http.server
import importlib.util
import json
import os
import threading
import time
import unittest

from ccl import common, sync

T = env.resp


def tearDownModule():
    env.assert_real_files_untouched()


REJECTED = [
    "https://evil.example/user",
    "https://api.github.com@evil.example/user",
    "https://evil.example@api.github.com/user",
    "https://user:pw@api.github.com/user",
    "https://api.github.com:8443/user",
    "https://api.github.com:80/user",
    "https://api.github.com%2eevil.example/user",
    "https://api%2egithub.com/user",
    "https://api.github.com./user",
    "https://api.github.com.evil.example/user",
    "https://аpi.github.com/user",           # Cyrillic «а»
    "https://api.github.com。evil/user",      # ideographic full stop
    "http://api.github.com/user",
    "//evil.example/user",
    "https://api.github.com /user",
    "https://api.github.com\\@evil.example/",
    "ftp://api.github.com/user",
]
ACCEPTED = ["/user", "https://api.github.com/user", "https://api.github.com:443/user", "/gists?per_page=100"]


class TestTokenBoundary(env.SyncEnv):
    # Scenario 11
    def test_bearer_only_to_api_origin(self):
        for url in REJECTED:
            with self.subTest(url):
                r = sync.gh(url, self.token)
                self.assertEqual(r.status, 0)
                self.assertEqual(self.gh.calls, [], "request must not be sent")
        for path in ACCEPTED:
            with self.subTest(path):
                full = sync.API + path if path.startswith("/") else path
                self.gh.on("GET", full, T(200, {}))
                sync.gh(path, self.token)
                self.assertEqual(self.gh.calls[-1].url, full)
                self.assertEqual(self.gh.calls[-1].auth, "Bearer " + self.token)

    def test_link_next_to_foreign_host_rejected(self):
        page1 = [env.gist_json({sync.MANIFEST: "{}"}, gid="first")]
        for link in ('<https://evil.example/gists?page=2>; rel="next"',
                     '<https://api.github.com@evil.example/gists?page=2>; rel="next"',
                     '<http://api.github.com/gists?page=2>; rel="next"',
                     '<https://api.github.com:8443/gists?page=2>; rel="next"'):
            with self.subTest(link):
                self.gh.calls.clear()
                self.gh.on("GET", "/gists?per_page=100", T(200, page1, headers={"Link": link}))
                gid, bad = sync._find_gist(self.token)
                self.assertEqual((gid, bad), ("first", None))
                self.assertEqual(len(self.gh.calls), 1)

    def test_link_next_on_api_origin_followed(self):
        nxt = "https://api.github.com/gists?per_page=100&page=2"
        old = env.gist_json({sync.MANIFEST: "{}"}, gid="older", created="2026-01-01T00:00:00Z")
        self.gh.on("GET", "/gists?per_page=100",
                   T(200, [env.gist_json({sync.MANIFEST: "{}"}, gid="newer")], headers={"Link": '<%s>; rel="next"' % nxt}))
        self.gh.on("GET", nxt, T(200, [old]))
        self.assertEqual(sync._find_gist(self.token), ("older", None))

    def test_raw_url_fetched_without_authorization(self):
        self.sign_in()
        self.mark_pushed()
        raw = "https://gist.githubusercontent.com/u/g1/raw/abc/machine-aa.json"
        self.gh.on("GET", "/gists/g1", self.ok_gist({"machine-aa.json": {"truncated": True, "raw_url": raw, "content": ""}}))
        self.gh.on("GET", raw, T(200, raw=env.machine_json("aa").encode()))
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        raw_call = self.gh.calls[-1]
        self.assertEqual(raw_call.url, raw)
        self.assertIsNone(raw_call.auth)
        self.assertEqual([m["id"] for m in res.remote["machines"]], ["aa"])

    def test_transport_disables_redirects_for_authorized_requests(self):
        seen = []

        def spy(url, method="GET", headers=None, body=None, timeout=15, follow_redirects=True):
            seen.append((dict(headers or {}), follow_redirects))
            return common.Resp(200, b"{}")
        saved = common.http
        common.http = spy
        try:
            sync._transport("https://api.github.com/user", "GET", {"Authorization": "Bearer x"}, None, 5)
            sync._transport("https://gist.githubusercontent.com/x", "GET", {"User-Agent": "u"}, None, 5)
        finally:
            common.http = saved
        self.assertEqual([f for _h, f in seen], [False, True])

    def test_302_on_authorized_gist_request_fails_cycle(self):
        self.sign_in()
        self.gh.on("GET", "/gists/g1", T(302, headers={"Location": "https://evil.example/"}))
        res = self.cycle()
        self.assertFalse(res.ok)
        self.assertEqual(len(self.gh.calls), 1, "no PATCH, no /user check after a redirect")
        self.assertIn("302", self.st().get("lastError"))


class _Redirector(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.seen.append((self.path, self.headers.get("Authorization")))
        if self.path.startswith("/start"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/landed" % self.server.server_port)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


class TestNoRedirectOpener(unittest.TestCase):
    """common.http itself (a private copy — _isolate replaced the module's http with a guard)
    against a loopback server: with follow_redirects=False a 302 is returned, not followed."""

    def setUp(self):
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ccl", "common.py")
        spec = importlib.util.spec_from_file_location("ccl_common_http_copy", path)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), _Redirector)
        self.srv.seen = []
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()
        self.env = {k: os.environ.get(k) for k in ("no_proxy", "NO_PROXY", "http_proxy", "HTTP_PROXY")}
        os.environ["no_proxy"] = os.environ["NO_PROXY"] = "*"
        os.environ.pop("http_proxy", None)
        os.environ.pop("HTTP_PROXY", None)

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_redirect_not_followed_with_token(self):
        url = "http://127.0.0.1:%d/start" % self.srv.server_port
        r = self.mod.http(url, "GET", {"Authorization": "Bearer x"}, None, 5, follow_redirects=False)
        self.assertEqual(r.status, 302)
        self.assertEqual([p for p, _a in self.srv.seen], ["/start"])

    def test_redirect_followed_without_token(self):
        url = "http://127.0.0.1:%d/start" % self.srv.server_port
        r = self.mod.http(url, "GET", {"User-Agent": "t"}, None, 5, follow_redirects=True)
        self.assertEqual(r.status, 200)
        self.assertEqual([p for p, _a in self.srv.seen], ["/start", "/landed"])


class TestRawUrlFailures(env.SyncEnv):
    # Scenario 12
    RAW = "https://gist.githubusercontent.com/u/g1/raw/abc/machine-aa.json"

    def setUp(self):
        super().setUp()
        self.sign_in()
        self.mark_pushed()
        self.ok_at = time.time() - 3600
        self.st().update(lastOkAt=self.ok_at)
        common.write_json(common.SYNC_REMOTE_PATH, {"machines": [{"id": "sentinel"}], "days": {}})
        with open(common.SYNC_REMOTE_PATH, "rb") as f:
            self.remote_before = f.read()

    def run_raw(self, raw_resp):
        self.gh.calls.clear()
        self.gh.on("GET", "/gists/g1", self.ok_gist({"machine-aa.json": {"truncated": True, "raw_url": self.RAW}}))
        self.gh.on("GET", self.RAW, raw_resp)
        return self.cycle()

    def test_raw_errors(self):
        cases = [("403 plain", T(403), False), ("403 limited", T(403, headers={"x-ratelimit-remaining": "0"}), True),
                 ("429", T(429, headers={"retry-after": "30"}), True), ("200 empty", T(200, raw=b""), False),
                 ("200 no body", T(200), False), ("500", T(500), False), ("0", T(0), False),
                 ("401", T(401), False)]
        for label, r, backoff in cases:
            with self.subTest(label):
                self.st().update(backoffUntil=None, lastError=None)
                res = self.run_raw(r)
                self.assertFalse(res.ok)
                st = self.st()
                self.assertEqual(float(st.get("lastOkAt")), self.ok_at, "last success not advanced")
                self.assertIn("raw_url", st.get("lastError"))
                with open(common.SYNC_REMOTE_PATH, "rb") as f:
                    self.assertEqual(f.read(), self.remote_before, "remote cache not overwritten")
                self.assertEqual([m.get("id") for m in res.remote["machines"]], ["sentinel"])
                self.assertEqual(len(self.gh.calls), 2, "raw 401 never starts a /user check")
                self.assertFalse(st.get("revoked"))
                if backoff:
                    self.assertGreater(float(st.get("backoffUntil")), time.time())
                else:
                    self.assertIsNone(st.get("backoffUntil"))


class TestDiscovery(env.SyncEnv):
    # Scenario 14
    def test_public_gist_not_selected(self):
        gists = [env.gist_json({sync.MANIFEST: "{}"}, gid="pub", public=True, created="2020-01-01T00:00:00Z"),
                 env.gist_json({sync.MANIFEST: "{}"}, gid="nofield", public=None, created="2020-01-02T00:00:00Z"),
                 dict(env.gist_json({sync.MANIFEST: "{}"}, gid="zero", created="2020-01-03T00:00:00Z"), public=0),
                 env.gist_json({sync.MANIFEST: "{}"}, gid="sec", created="2026-01-01T00:00:00Z")]
        self.gh.on("GET", "/gists?per_page=100", T(200, gists))
        self.assertEqual(sync._find_gist(self.token), ("sec", None))

    def test_cached_public_gist_is_never_written(self):
        self.sign_in(gist="pub")
        self.st().update(pushHash="stale")
        pub = env.gist_json({sync.MANIFEST: "{}"}, gid="pub", public=True, created="2020-01-01T00:00:00Z")
        sec = env.gist_json({sync.MANIFEST: "{}"}, gid="sec", created="2026-01-01T00:00:00Z")
        self.gh.on("GET", "/gists/pub", T(200, pub))
        self.gh.on("GET", "/gists?per_page=100", T(200, [pub, sec]))
        self.gh.on("GET", "/gists/sec", T(200, sec))
        self.gh.on("PATCH", "/gists/sec", T(200, sec))
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        writes = [c for c in self.gh.calls if c.method != "GET"]
        self.assertEqual([(c.method, c.url) for c in writes], [("PATCH", sync.API + "/gists/sec")])
        self.assertEqual(self.st().get("gistId"), "sec")
        body = json.loads(json.dumps(writes[0].body))
        self.assertEqual(list(body["files"]), [sync.my_file_name()])

    def test_only_public_gists_creates_a_secret_one(self):
        self.sign_in(gist=None)
        pub = env.gist_json({sync.MANIFEST: "{}"}, gid="pub", public=True)
        new = env.gist_json({sync.MANIFEST: "{}", sync.my_file_name(): "{}"}, gid="new")
        self.gh.on("GET", "/gists?per_page=100", T(200, [pub]), T(200, [pub, new]))
        self.gh.on("POST", "/gists", T(201, new))
        self.gh.on("GET", "/gists/new", T(200, new))
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        post = next(c for c in self.gh.calls if c.method == "POST")
        self.assertIs(post.body["public"], False)
        self.assertFalse(any("/gists/pub" in c.url for c in self.gh.calls))


if __name__ == "__main__":
    unittest.main()
