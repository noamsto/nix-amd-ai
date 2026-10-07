#!/usr/bin/env python3
"""Offline tests for halogen.py: container hygiene flags, teardown on signal, and the checks group against a fake server."""
import json
import os
import random
import stat
import sys
import tempfile
import threading
import types
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
FAKE_PODMAN = '#!/bin/sh\necho "$@" >> "$FAKE_PODMAN_LOG"\ncase "$1" in ps) printf "%s" "${FAKE_PS_OUT:-}" ;; esac\ncase "$1$2" in networkinspect) echo "${FAKE_INTERNAL:-true}" ;; esac\n'
os.environ["PODMAN"] = os.path.join(tempfile.mkdtemp(), "podman")
with open(os.environ["PODMAN"], "w") as f:
    f.write(FAKE_PODMAN)
os.chmod(os.environ["PODMAN"], os.stat(os.environ["PODMAN"]).st_mode | stat.S_IEXEC)
import halogen  # noqa: E402

REAL_PODMAN = halogen.podman


def args(**kw):
    base = dict(image="img@sha256:abc", models="/m", checkpoint="v2.hgn", port=18140, env=["HALOGEN_PROMPT_CACHE=0"])
    return types.SimpleNamespace(**{**base, **kw})


class Hygiene(unittest.TestCase):
    def test_flags(self):
        argv = halogen.run_args(args(), "n")
        joined = " ".join(argv)
        self.assertIn("127.0.0.1:18140:8731", joined)
        self.assertIn("/m:/models:ro", joined)
        for banned in ("--privileged", "--network", "--net", "--cap-add", "--security-opt", "0.0.0.0", "--pid"):
            self.assertNotIn(banned, joined)
        self.assertEqual([x for x in argv if x == "--device"].__len__(), 2)
        self.assertIn("--rm", argv)
        self.assertEqual(argv[-1], "img@sha256:abc")

    def test_offline_network_only_when_asked(self):
        self.assertNotIn("--network", halogen.run_args(args(), "n"))
        argv = halogen.run_args(args(offline=True), "n")
        self.assertEqual(argv[argv.index("--network") + 1], halogen.OFFLINE_NETWORK)

    def test_loopback_filter(self):
        for addr in ("127.0.0.1:5000", "[::1]:80", "*:*", "0.0.0.0:*"):
            self.assertTrue(halogen.is_loopback(addr))
        for addr in ("140.82.112.3:443", "[2606:4700::1]:443", "192.168.3.217:51666"):
            self.assertFalse(halogen.is_loopback(addr))

    def test_ppl_has_no_port(self):
        argv = halogen.mode_args(args(), "n", "ppl", ["/models/x.gguf", "--json"])
        self.assertNotIn("-p", argv)
        self.assertEqual(argv[-3:], ["ppl", "/models/x.gguf", "--json"])


class Teardown(unittest.TestCase):
    def test_signal_kills_every_container(self):
        log = os.path.join(tempfile.mkdtemp(), "calls")
        os.environ["FAKE_PODMAN_LOG"] = log
        halogen.containers[:] = ["halogen258-a", "halogen258-b"]
        with self.assertRaises(SystemExit) as cm:
            halogen._on_signal(15, None)
        self.assertEqual(cm.exception.code, 143)
        calls = open(log).read()
        for n in ("a", "b"):
            self.assertIn(f"kill halogen258-{n}", calls)
            self.assertIn(f"rm -f halogen258-{n}", calls)
        self.assertEqual(halogen.containers, [])


class Guards(unittest.TestCase):
    def setUp(self):
        os.environ["FAKE_PODMAN_LOG"] = os.path.join(tempfile.mkdtemp(), "calls")

    def test_env_must_be_halogen_name_value(self):
        halogen.check_env(["HALOGEN_CTX=1", "HALOGEN_X="])
        for bad in ("HF_TOKEN", "HALOGEN_CTX", "PATH=/x", "halogen_ctx=1"):
            with self.assertRaises(halogen.grid.RowError):
                halogen.check_env([bad])

    def test_teardown_raises_when_the_container_stays(self):
        os.environ["FAKE_PS_OUT"] = "abc123"
        halogen.TEARDOWN_S = 1
        halogen.containers[:] = ["halogen258-x"]
        try:
            with self.assertRaises(halogen.grid.RowError):
                halogen.teardown("halogen258-x")
        finally:
            del os.environ["FAKE_PS_OUT"]
            halogen.TEARDOWN_S = 60
            halogen.containers[:] = []

    def test_offline_network_must_be_internal(self):
        os.environ["FAKE_INTERNAL"] = "false"
        try:
            with self.assertRaises(halogen.grid.RowError):
                halogen.ensure_offline_network()
        finally:
            del os.environ["FAKE_INTERNAL"]
        halogen.ensure_offline_network()

    def test_offline_probe_fails_on_any_success_or_no_output(self):
        for out, ok in (('{"a": "failed: OSError"}', True), ('{"a": "SUCCEEDED"}', False), ("", False)):
            halogen.podman = lambda *a, out=out, **k: types.SimpleNamespace(stdout=out, stderr="", returncode=0)
            try:
                if ok:
                    self.assertEqual(halogen.offline_probe("n"), {"a": "failed: OSError"})
                else:
                    with self.assertRaises(halogen.grid.RowError):
                        halogen.offline_probe("n")
            finally:
                halogen.podman = REAL_PODMAN

    def test_wait_held_polls_and_stops_on_breach(self):
        loader = halogen.subprocess.Popen(
            [sys.executable, "-c", "import time;print('held',flush=True);time.sleep(30)"],
            stdout=halogen.subprocess.PIPE, text=True)
        try:
            self.assertTrue(halogen.wait_held(loader, {"breach": False}, 10))
        finally:
            loader.kill()
            loader.wait()
        silent = halogen.subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"],
                                          stdout=halogen.subprocess.PIPE, text=True)
        try:
            self.assertFalse(halogen.wait_held(silent, {"breach": True}, 10))
        finally:
            silent.kill()
            silent.wait()


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = json.dumps({"version": "0.16.2", "server_defaults": {}, "modes": ["ppl"]}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        t = req.get("temperature")
        sampled = t not in (None, 0) and req.get("top_k") != 1 and "seed" not in req
        content = "alpha" + (str(random.random()) if sampled else "")
        if req.get("top_logprobs", 0) > 20 or req.get("repetition_penalty", 1) != 1 and t == 0:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"bad"}')
            return
        if "BEGIN" in req["messages"][0]["content"]:
            content = "text DONE get_weather"
        message = {"content": content}
        choice = {"message": message, "finish_reason": "stop"}
        if req.get("top_logprobs"):
            choice["logprobs"] = {"content": [{"top_logprobs": [{}] * req["top_logprobs"]}]}
        if req.get("stream"):
            chunks = [{"choices": [{"delta": {"content": content}}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}],
                      "usage": {"prompt_tokens": 5, "completion_tokens": 3}}]
            self.send_response(200)
            self.end_headers()
            for c in chunks:
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        body = json.dumps({"choices": [choice], "usage": {"completion_tokens": 3}, "timings": {"draft_n": 2}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


class Checks(unittest.TestCase):
    def test_checks_group(self):
        srv = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        port = srv.server_address[1]
        e = types.SimpleNamespace(port=port, engine="halogen", model="m")
        out = halogen.g_checks(e, port)
        srv.shutdown()
        self.assertEqual(out["health"]["version"], "0.16.2")
        s = out["sampling"]
        self.assertEqual(s["omitted_temperature_distinct_of_3"], 1)  # the fake decodes greedy when temperature is omitted
        self.assertEqual(s["temp1_top_k1_distinct_of_3"], 1)
        self.assertEqual(s["temp1_seed7_distinct_of_3"], 1)
        self.assertEqual(out["logprobs"]["top20_first_token"]["top_returned"], 20)
        self.assertTrue(str(out["logprobs"]["top21_status"]).startswith("400"))
        self.assertTrue(out["tool_token_text"]["no_tools_plain"]["reached_DONE"])
        self.assertEqual(out["spec_identity"]["identical"], out["spec_identity"]["of"])


if __name__ == "__main__":
    unittest.main()
