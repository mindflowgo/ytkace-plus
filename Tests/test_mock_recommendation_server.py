#!/usr/bin/env python3
"""Tests for the mock recommendation server (Tools/mock-recommendation-server.py)."""

import base64
import json
import sys
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))

import importlib.util

spec = importlib.util.spec_from_file_location("mock_server", ROOT / "Tools" / "mock-recommendation-server.py")
mock_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock_server)


def start_server(action="replace", marker_field=90001):
    options = type("Options", (), {"action": action, "marker_field": marker_field, "delay_ms": 0,
                                   "dump_dir": None})()
    server = mock_server.RecommendationServer(("127.0.0.1", 0), options)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/v1/recommendations/transform"


def post(url, body, timeout=5):
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, json.loads(response.read().decode())


def envelope(payload_b64, request_id="req-1", surface="watch", phase="initial"):
    return {"protocolVersion": 1, "mode": "transform", "requestId": request_id, "surface": surface,
            "phase": phase, "youtubeVersion": "21.33.6", "responseType": "YTIWatchNextResponse",
            "context": {"videoId": "dQw4w9WgXcQ"}, "encoding": "protobuf-base64", "payload": payload_b64}


class MockRecommendationServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.url = start_server(action="replace")
        cls.passthrough_server, cls.passthrough_url = start_server(action="passthrough")

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.passthrough_server.shutdown()
        cls.passthrough_server.server_close()

    def test_health_advertises_protocol_version(self):
        with urllib.request.urlopen(self.url, timeout=5) as response:
            health = json.loads(response.read().decode())
        self.assertEqual(health["protocolVersion"], 1)
        self.assertEqual(health["service"], "mock-recommendation-server")

    def test_replace_echoes_payload_with_marker(self):
        payload = bytes([0x08, 0x01])  # field 1 varint 1
        status, reply = post(self.url, envelope(base64.b64encode(payload).decode()))
        self.assertEqual(status, 200)
        self.assertEqual(reply["protocolVersion"], 1)
        self.assertEqual(reply["requestId"], "req-1")
        self.assertEqual(reply["action"], "replace")
        self.assertEqual(reply["encoding"], "protobuf-base64")
        transformed = base64.b64decode(reply["payload"])
        self.assertTrue(transformed.startswith(payload), "replacement must start with the original bytes")
        marker = mock_server.marker_field_bytes(90001)
        self.assertTrue(transformed.endswith(marker), "replacement must end with the marker field")
        self.assertIn(b"RECSRV", transformed)

    def test_marker_field_bytes_encoding(self):
        # field 90001, wire type 2 -> varint tag (90001<<3)|2 = 720010, len 6, RECSRV
        marker = mock_server.marker_field_bytes(90001)
        tag = mock_server.encode_varint((90001 << 3) | 2)
        self.assertEqual(marker, tag + bytes([6]) + b"RECSRV")
        self.assertEqual(len(tag), 3)
        self.assertEqual(mock_server.encode_varint(720010), b"\x8a\xf9\x2b")

    def test_passthrough_has_no_payload(self):
        status, reply = post(self.passthrough_url, envelope(base64.b64encode(b"\x08\x01").decode()))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "passthrough")
        self.assertNotIn("payload", reply)

    def test_bad_envelopes_are_rejected_with_400(self):
        payload = base64.b64encode(b"\x08\x01").decode()
        cases = [
            {"protocolVersion": 2, "mode": "transform", "requestId": "x", "encoding": "protobuf-base64", "payload": payload},
            {"protocolVersion": 1, "mode": "direct", "requestId": "x", "encoding": "protobuf-base64", "payload": payload},
            {"protocolVersion": 1, "mode": "transform", "encoding": "protobuf-base64", "payload": payload},
            {"protocolVersion": 1, "mode": "transform", "requestId": "x", "encoding": "json", "payload": payload},
            {"protocolVersion": 1, "mode": "transform", "requestId": "x", "encoding": "protobuf-base64", "payload": "!!!"},
            {"protocolVersion": 1, "mode": "transform", "requestId": "x", "encoding": "protobuf-base64", "payload": ""},
            "not-a-dict",
        ]
        for body in cases:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                post(self.url, body)
            self.assertEqual(caught.exception.code, 400, body)

    def test_http_error_action(self):
        server, url = start_server(action="http-error")
        try:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                post(url, envelope(base64.b64encode(b"\x08\x01").decode()))
            self.assertEqual(caught.exception.code, 503)
        finally:
            server.shutdown()

    def test_other_fallback_modes_still_answer_200(self):
        payload_b64 = base64.b64encode(b"\x08\x01").decode()
        for action in ["invalid-base64", "request-id-mismatch", "version-mismatch", "unknown-action", "oversized"]:
            server, url = start_server(action=action)
            try:
                status, reply = post(url, envelope(payload_b64))
                self.assertEqual(status, 200, action)
                # version-mismatch deliberately advertises 2; the client must reject it.
                self.assertEqual(reply["protocolVersion"], 2 if action == "version-mismatch" else 1, action)
                if action == "invalid-base64":
                    self.assertEqual(reply["payload"], "!!!not-base64!!!")
            finally:
                server.shutdown()
        server, url = start_server(action="request-id-mismatch")
        try:
            _, reply = post(url, envelope(payload_b64))
            self.assertEqual(reply["requestId"], "mismatched-request-id")
        finally:
            server.shutdown()

    def test_delay_adds_latency(self):
        options = type("Options", (), {"action": "passthrough", "marker_field": 90001, "delay_ms": 250,
                                       "dump_dir": None})()
        server = mock_server.RecommendationServer(("127.0.0.1", 0), options)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_address[1]}/x"
        try:
            import time
            started = time.monotonic()
            post(url, envelope(base64.b64encode(b"\x08\x01").decode()))
            self.assertGreaterEqual(time.monotonic() - started, 0.2)
        finally:
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
