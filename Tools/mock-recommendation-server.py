#!/usr/bin/env python3
"""Local mock recommendation server for the YTKACE recommendations patch.

Speaks the docs/recommendations.md §5 envelope: accepts a POST with the
original protobuf payload (base64 in JSON) and replies either with a
passthrough or with a replacement that echoes the payload plus a small
length-delimited marker field that YouTube's protobuf parser preserves and
ignores. Designed for Stage B verification on a LAN (see
docs/RECOMMENDATIONS_SERVER.md).

Example:
    python3 Tools/mock-recommendation-server.py --action replace --port 8046

Payloads are never logged in content; sizes and sha256 prefixes only, unless
--dump-dir is given for local debugging.
"""

import argparse
import base64
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER_TEXT = b"RECSRV"


def encode_varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def marker_field_bytes(field_number: int) -> bytes:
    """Length-delimited field: tag varint (field<<3|2), length, marker text."""
    return encode_varint((field_number << 3) | 2) + bytes([len(MARKER_TEXT)]) + MARKER_TEXT


class RecommendationServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, options):
        super().__init__(address, Handler)
        self.options = options
        self.last_auth = None
        self.last_path = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockRecommendations/1"

    def log_message(self, fmt, *args):  # default stderr logging is enough
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # ---------- helpers ----------

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _dump(self, request_id: str, payload: bytes) -> None:
        directory = self.server.options.dump_dir
        if not directory:
            return
        import pathlib
        path = pathlib.Path(directory)
        path.mkdir(parents=True, exist_ok=True)
        (path / f"{request_id}.bin").write_bytes(payload)

    # ---------- routes ----------

    def do_GET(self):
        if self.path == "/yt-settings":
            self._send_json(200, {
                "protocolVersion": 1,
                "aiPrompts": [
                    "Summarize the core ideas in this video",
                    "List 5 similar videos and summarize their content",
                    "Summarize the core 5 ideas in this video",
                ],
            })
            return
        self._send_json(200, {
            "protocolVersion": 1,
            "service": "mock-recommendation-server",
            "defaultAction": self.server.options.action,
            "markerField": self.server.options.marker_field,
            "lastAuth": self.server.last_auth,
            "lastPath": self.server.last_path,
        })

    def do_POST(self):
        options = self.server.options
        started = time.monotonic()
        self.server.last_path = self.path
        self.server.last_auth = self.headers.get("Authorization")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            envelope = json.loads(raw.decode() or "{}")
            if not isinstance(envelope, dict):
                raise ValueError("envelope is not a JSON object")
            if envelope.get("protocolVersion") != 1:
                raise ValueError("unsupported protocolVersion")
            if envelope.get("mode") != "transform":
                raise ValueError("unsupported mode")
            request_id = envelope.get("requestId")
            if not isinstance(request_id, str) or not request_id:
                raise ValueError("missing requestId")
            if envelope.get("encoding") != "protobuf-base64":
                raise ValueError("unsupported encoding")
            payload = base64.b64decode(envelope.get("payload") or "", validate=True)
            if not payload:
                raise ValueError("empty payload")
        except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError) as error:
            self._send_json(400, {"error": str(error)})
            return

        if options.delay_ms:
            time.sleep(options.delay_ms / 1000.0)
        self._dump(request_id, payload)
        action = options.action
        fingerprint = hashlib.sha256(payload).hexdigest()[:16]

        if action == "not-modified":
            self.send_response(304, "Not Modified")
            self.end_headers()
            return

        if action == "http-error":
            self.send_error(503, "mock transform failure")
            return

        if action == "passthrough":
            reply = {"protocolVersion": 1, "requestId": request_id, "action": "passthrough"}
            out_bytes = 0
        else:
            reply = {
                "protocolVersion": 1,
                "requestId": request_id,
                "action": "replace",
                "encoding": "protobuf-base64",
            }
            if action == "replace":
                transformed = payload + marker_field_bytes(options.marker_field)
            elif action == "invalid-base64":
                transformed = payload
                reply["payload"] = "!!!not-base64!!!"
            elif action == "request-id-mismatch":
                transformed = payload
                reply["requestId"] = "mismatched-request-id"
            elif action == "version-mismatch":
                reply["protocolVersion"] = 2
                transformed = payload + marker_field_bytes(options.marker_field)
            elif action == "unknown-action":
                reply["action"] = "scramble"
                transformed = payload
            elif action == "oversized":
                transformed = payload + b"\x00" * (17 * 1024 * 1024)
            else:
                raise SystemExit(f"unknown action {action}")
            if "payload" not in reply or action != "invalid-base64":
                reply["payload"] = base64.b64encode(transformed).decode()
            out_bytes = len(transformed)

        self._send_json(200, reply)
        duration_ms = (time.monotonic() - started) * 1000.0
        surface = envelope.get("surface")
        phase = envelope.get("phase")
        response_type = envelope.get("responseType")
        youtube = envelope.get("youtubeVersion")
        context = envelope.get("context") or {}
        video_note = "video" if surface == "watch" and context.get("videoId") else "-"
        print(
            f"{time.strftime('%H:%M:%S')} {request_id} path={self.path} auth={'yes' if self.server.last_auth else 'no'} "
            f"surface={surface} phase={phase} "
            f"type={response_type} yt={youtube} {video_note} in={len(payload)}B({fingerprint}) "
            f"out={out_bytes}B action={reply.get('action', 'http-error')} {duration_ms:.1f}ms",
            flush=True,
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8046)
    parser.add_argument("--action", default="replace", choices=[
        "replace", "passthrough", "not-modified", "invalid-base64", "request-id-mismatch",
        "version-mismatch", "unknown-action", "oversized", "http-error"],
        help="replace echoes the payload plus a marker field (default); "
             "the other modes exercise the patch's fallback paths")
    parser.add_argument("--delay-ms", type=int, default=0,
                        help="sleep before replying; above the client timeout it exercises fallback")
    parser.add_argument("--marker-field", type=int, default=90001,
                        help="field number of the appended marker (0 disables the marker)")
    parser.add_argument("--dump-dir", default=None,
                        help="optionally save received payloads for offline debugging")
    options = parser.parse_args(argv)

    server = RecommendationServer((options.host, options.port), options)
    marker = marker_field_bytes(options.marker_field) if options.marker_field else b"(disabled)"
    print(f"mock-recommendation-server on {options.host}:{options.port} action={options.action} "
          f"marker_field={options.marker_field} marker_bytes={marker.hex()}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
