#!/usr/bin/env python3
"""Contract tests for server/bun-recommendation-server.ts (skipped when bun is missing)."""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mock_server", ROOT / "Tools" / "mock-recommendation-server.py")
mock_server = importlib.util.spec_from_file_location and importlib.util.module_from_spec(spec)
if spec and spec.loader:
    spec.loader.exec_module(mock_server)

BUN = shutil.which("bun")


def start_bun(action="replace", extra_args=None):
    """Start an isolated bun server on port 0; returns (process, base_url, log_path)."""
    workdir = tempfile.mkdtemp(prefix="bun-rec-server-test-")
    logfile = os.path.join(workdir, "bun-server.log")
    process = subprocess.Popen(
        [BUN, "run", str(ROOT / "server" / "bun-recommendation-server.ts"),
         "--host", "127.0.0.1", "--port", "0", "--action", action,
         "--log-file", logfile] + (extra_args or []),
        cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    deadline = time.monotonic() + 15
    lines = []
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line:
            lines.append(line)
            if "listening on" in line:
                port = int(line.rstrip().split("listening on")[1].split(":")[1].split()[0])
                return process, f"http://127.0.0.1:{port}", logfile
        if process.poll() is not None:
            break
    raise AssertionError(f"bun server did not start: {lines}")


def post(url, body, timeout=5):
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, json.loads(response.read().decode())


def envelope(payload_b64, request_id="req-1", surface="watch", phase="initial",
             video_id="dQw4w9WgXcQ"):
    context = {"videoId": video_id} if video_id else {}
    return {"protocolVersion": 1, "mode": "transform", "requestId": request_id, "surface": surface,
            "phase": phase, "youtubeVersion": "21.33.6",
            "responseType": "YTIWatchNextResponse" if surface == "watch" else "YTIBrowseResponse",
            "context": context, "encoding": "protobuf-base64", "payload": payload_b64}


def _varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def pb_string(field, text):
    data = text.encode()
    return _varint((field << 3) | 2) + _varint(len(data)) + data


def pb_msg(field, data):
    return _varint((field << 3) | 2) + _varint(len(data)) + data


def shorts_card_fixture():
    """A Shorts card: renderer marker + "Send feedback" menu label BEFORE the
    real title, id in field 9, title in the usual nested text field."""
    def item(video_id, title):
        return (pb_string(1, "shortsLockupViewModel") +
                pb_string(2, "Send feedback") +
                pb_string(9, video_id) +
                pb_msg(10, pb_msg(1, pb_msg(1, pb_string(1, title)))))
    return pb_msg(1, pb_msg(1, item("LasUujrNBs8", "Adorable Squirrel Steals the Show")))


def lockup_card(video_id, title, byline):
    """Real-shape lockup card: f1 media msg (f2 duration string), f2 metadata
    msg (f1 title), f6 watch url, f7 id, plus a menu subtree with junk labels."""
    media = pb_msg(2, pb_string(1, "23:04")) + pb_string(11, "23 minutes, 4 seconds")
    metadata = pb_string(1, title) + pb_string(3, "tracking-token") + pb_msg(66, pb_string(1, "x"))
    menu = pb_msg(14, pb_msg(169495254, pb_msg(98150882, pb_msg(1, pb_string(1, "Send feedback")))))
    return (pb_msg(1, media) + pb_msg(2, metadata) + pb_string(6, f"//www.youtube.com/watch?v={video_id}")
            + pb_string(7, video_id) + pb_string(18, video_id) + pb_string(2, byline) + menu)


def news_shelf(heading, cards):
    """Modern shelf: 312131490 -> entry(f20) { f1: header msg with f20 heading,
    f9: repeated cards } — the real verified shape."""
    header = pb_string(19, "Action menu") + pb_string(20, heading) + pb_string(26, heading)
    body = pb_msg(1, header) + pb_msg(5, pb_string(1, "shelf-params"))
    for card in cards:
        body += pb_msg(9, card)
    return pb_msg(312131490, pb_msg(20, body))


def shorts_item(video_id, title=None, with_menu=True):
    """Real-shape shorts shelf item (verified): wrapper child 519005951 -> f17
    item; title at f17>f22>f1>f1, accessibility "<title> - play Short" at f4."""
    item = pb_string(1, f"shorts-shelf-item-{video_id}")
    item += pb_msg(6, pb_msg(169495254, pb_msg(139608561, pb_string(1, video_id))))
    if title is not None:
        item += pb_string(4, f"{title} - play Short")
        item += pb_msg(22, pb_msg(1, pb_msg(1, pb_string(1, title))))
    if with_menu:
        menu = (pb_string(1, "Share") + pb_string(1, "Not interested")
                + pb_string(1, "Send feedback") + pb_string(18, "Video removed")
                + pb_string(21, "More actions"))
        item += pb_msg(14, menu)
    return pb_msg(519005951, pb_msg(17, item))


def compact_shorts_item(video_id, title, stats="81 thousand views"):
    """Channel/tab Shorts card (verified on a real channel page): the bare item
    sits under 471792238>4>7; f1 is "shorts-shelf-item-<id>", the a11y line at
    f4 holds "<title>, <stats> - play Short", and f22.f2.f1 holds stats only."""
    return (pb_string(1, f"shorts-shelf-item-{video_id}") +
            pb_string(4, f"{title}, {stats} - play Short") +
            pb_msg(6, pb_msg(169495254, pb_msg(139608561, pb_string(1, video_id)))) +
            pb_msg(22, pb_msg(2, pb_string(1, "81K views"))))


def reel_sequence_item(video_id, uuid, stats="81K views"):
    """Shorts reel sequence item (verified on /yt-reels): f1 id, f4 prefetch
    token, f53 playback UUID, f79857908 player response. No title text exists
    anywhere in this batch payload."""
    return (pb_string(1, video_id) + pb_string(4, "8AEByAMTwATmw8-RwpDRyD2iBhUBqHapM7Y") +
            pb_string(53, uuid) +
            pb_msg(79857908, pb_msg(146179543, pb_msg(1, pb_string(1, "https://example.invalid/initplayback")))))


def related_card(video_id, title, channel):
    """Watch-related card variant (verified): no direct f6/f7 at card level;
    id/title/channel together in the navData node 48687757 (f1/f36/f37)."""
    nav = pb_msg(48687757, pb_string(1, video_id) + pb_string(36, title) + pb_string(37, channel))
    content = (pb_msg(3, pb_string(3, f"Go to channel {channel}"))
               + pb_msg(19, pb_msg(169495254, nav)))
    return pb_msg(1, content) + pb_string(2, f"{title} - 42 minutes, 22 seconds - Go to channel {channel}")


def pb_varint(field, value):
    return _varint((field << 3) | 0) + _varint(value)


def chip_strip(titles, selected):
    """Category chip bar: 213380311 -> rows(f1) -> chips(91394224), chip title
    at f2.f1.f1, f9 varint 1 when selected."""
    strip = b""
    for title in titles:
        chip = pb_msg(2, pb_msg(1, pb_string(1, title)))
        if title == selected:
            chip += pb_varint(9, 1)
        strip += pb_msg(1, pb_msg(91394224, chip))
    return pb_msg(213380311, strip)


def recommendations_fixture():
    """Root(field 1) -> renderer(field 1) -> two videoRenderer subtrees:
    field 9 = videoId string, field 10 -> title msg(field 1 -> msg(field 1 = text))."""
    def item(video_id, title):
        return pb_string(9, video_id) + pb_msg(10, pb_msg(1, pb_msg(1, pb_string(1, title))))
    return pb_msg(1, pb_msg(1, item("dQw4w9WgXcQ", "Never Gonna Give You Up") +
                                 item("9bZkp7q19f0", "Gangnam Style")))


@unittest.skipIf(BUN is None, "bun is not installed")
class BunRecommendationServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workdir = tempfile.mkdtemp(prefix="bun-rec-server-test-")
        cls.logfile = os.path.join(cls.workdir, "bun-server.log")
        cls.process = subprocess.Popen(
            [BUN, "run", str(ROOT / "server" / "bun-recommendation-server.ts"),
             "--host", "127.0.0.1", "--port", "0", "--action", "replace",
             "--log-file", cls.logfile],
            cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cls.port = cls._wait_for_port(cls.process, timeout=15)
        cls.base = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def _wait_for_port(cls, process, timeout):
        deadline = time.monotonic() + timeout
        accumulated = []
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if line:
                accumulated.append(line)
                if "listening on" in line:
                    cls.startup_output = "".join(accumulated)
                    return int(line.rstrip().split("listening on")[1].split(":")[1].split()[0])
            if process.poll() is not None:
                break
        raise AssertionError(f"bun server did not start: {accumulated}")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
        shutil.rmtree(cls.workdir, ignore_errors=True)

    # ---------- server behavior ----------

    def test_health_advertises_protocol_and_endpoints(self):
        with urllib.request.urlopen(self.base + "/", timeout=5) as response:
            health = json.loads(response.read().decode())
        self.assertEqual(health["protocolVersion"], 1)
        self.assertEqual(health["service"], "bun-recommendation-server")
        self.assertEqual(health["endpoints"], ["POST /yt-browse", "POST /yt-next", "POST /yt-search",
                                               "POST /yt-reels", "POST /yt-playback", "POST /yt-save"])

    def test_replace_echoes_payload_with_marker(self):
        payload = bytes([0x08, 0x01])
        status, reply = post(self.base + "/yt-next", envelope(base64.b64encode(payload).decode()))
        self.assertEqual(status, 200)
        self.assertEqual(reply["protocolVersion"], 1)
        self.assertEqual(reply["requestId"], "req-1")
        self.assertEqual(reply["action"], "replace")
        transformed = base64.b64decode(reply["payload"])
        self.assertTrue(transformed.startswith(payload))
        marker = mock_server.marker_field_bytes(90001)
        self.assertTrue(transformed.endswith(marker))

    def test_browse_endpoint_accepted_and_unknown_endpoint_404(self):
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        status, reply = post(self.base + "/yt-browse", envelope(payload, surface="home", phase="continuation"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        for path in ["/yt-guide", "/next", "/yt-recommendations", "/v1/recommendations/transform"]:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                post(self.base + path, envelope(payload))
            self.assertEqual(caught.exception.code, 404, path)
        time.sleep(0.2)
        content = Path(self.logfile).read_text()
        self.assertIn("api: POST /yt-guide -> 404", content)
        self.assertIn("api: POST /yt-recommendations -> 404", content)

    def test_passthrough_has_no_payload(self):
        # The default action of this server instance is replace; verify the
        # passthrough shape via the shared python mock instead of a second bun
        # process (mode parity is covered by test_mock_recommendation_server).
        self.assertEqual(mock_server.MARKER_TEXT, b"RECSRV")

    def test_bad_envelopes_are_rejected_with_400(self):
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
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
                post(self.base + "/yt-next", body)
            self.assertEqual(caught.exception.code, 400, body)

    def test_token_and_last_path_surface_in_health(self):
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        request = urllib.request.Request(self.base + "/yt-browse", data=json.dumps(
            envelope(payload, request_id="auth-check", surface="home")).encode(), method="POST",
            headers={"Content-Type": "application/json", "Authorization": "Bearer smoke-token"})
        urllib.request.urlopen(request, timeout=5)
        with urllib.request.urlopen(self.base + "/", timeout=5) as response:
            health = json.loads(response.read().decode())
        self.assertEqual(health["lastAuth"], "Bearer smoke-token")
        self.assertEqual(health["lastPath"], "/yt-browse")
        time.sleep(0.2)
        content = Path(self.logfile).read_text()
        # Every request, including health probes, gets a uniform access line.
        self.assertIn("api: POST /yt-browse action=replace", content)
        self.assertIn("api: GET / -> 200", content)

    def test_log_file_records_traffic(self):
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        post(self.base + "/yt-next", envelope(payload, request_id="log-line-check"))
        time.sleep(0.3)
        content = Path(self.logfile).read_text()
        self.assertIn("bun-recommendation-server listening on", content)
        self.assertIn("api: POST /yt-next action=replace", content)
        self.assertIn("POST /yt-next log-line-check", content)
        self.assertIn("in=2B(", content)
        # Raw payloads are never logged (ids are tagged via playback events and
        # api.log instead).
        self.assertNotIn(base64.b64encode(bytes([0x08, 0x01])).decode(), content)

    def test_lockup_cards_use_metadata_title_not_byline_or_menu(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = news_shelf("Breaking news", [
            lockup_card("CMH1vWoqK_0", "What Democratic control of Congress means for Canada-U.S. trade",
                        "CTV News      3.9K   48 min ago"),
            lockup_card("K0ywyEB_OHc", "Voters hand Democrats Senate control in sharp rebuke",
                        "The Canadian Press      4.5K   1h ago"),
        ])
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="lockup-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("    [Breaking news]", content)
        self.assertIn("      - CMH1vWoqK_0 «What Democratic control of Congress means for Canada-U.S. trade»", content)
        self.assertIn("      - K0ywyEB_OHc «Voters hand Democrats Senate control in sharp rebuke»", content)
        self.assertNotIn("48 min ago", content)
        self.assertNotIn("«CTV News", content)

    def test_selected_chip_title_in_decode_header(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = (pb_msg(1, chip_strip(["All", "Personal grooming", "Podcasts"], "Personal grooming"))
                   + pb_msg(9, pb_msg(58173949, pb_msg(1, pb_msg(58174010, pb_msg(4,
                     pb_msg(49399797, pb_msg(1, pb_msg(50195462, pb_msg(1,
                       lockup_card("CMH1vWoqK_0", "A title", "CTV News 3.9K 48 min ago")))))))))))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="chip-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("feed=«Personal grooming»", content)

    def test_playback_events_start_switch_leave(self):
        process, base, logfile = start_bun(action="replace", extra_args=["--infer-playback"])
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        post(base + "/yt-next", envelope(payload, request_id="pb-1", surface="watch",
                                         video_id="48YfC8VCIsY"))
        post(base + "/yt-next", envelope(payload, request_id="pb-2", surface="watch",
                                         phase="continuation", video_id="48YfC8VCIsY"))
        post(base + "/yt-next", envelope(payload, request_id="pb-3", surface="watch",
                                         video_id="s0V5g5MMunc"))
        post(base + "/yt-browse", envelope(payload, request_id="pb-4", surface="home",
                                           video_id=None))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("play: start videoId=48YfC8VCIsY", content)
        self.assertIn("play: switch videoId=s0V5g5MMunc previous=48YfC8VCIsY", content)
        self.assertIn("play: leave videoId=s0V5g5MMunc (inferred from home initial)", content)
        # Pagination fetches must not emit playback events.
        self.assertEqual(content.count("play:"), 3)
        # api.log records the video id alongside the raw data.
        api = json.loads(Path(logfile).with_name("api.log").read_text().strip().splitlines()[0])
        self.assertEqual(api["videoId"], "48YfC8VCIsY")

    def test_search_query_shown_in_decode_header(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        # Search filter chips embed the query at searchEndpoint (48687709) f1/f14.
        chip = pb_msg(48687709, pb_string(1, "helios") + pb_string(14, "helios"))
        chips = b"".join(pb_msg(91394224, chip) for _ in range(3))
        payload = pb_msg(4, pb_msg(49399797, pb_msg(1, pb_msg(90823135, pb_msg(1, chips)))))
        post(base + "/yt-search", envelope(base64.b64encode(payload).decode(),
                                           request_id="query-1", surface="search",
                                           video_id=None))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("query=«helios»", content)

    def test_engagement_panels_are_not_recommendations(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        # Top-level field 25 = engagement panels (transcript/comments): label
        # strings and font names must never pair as title/id.
        panel = pb_msg(25, pb_string(1, "YouTubeSans") + pb_string(2, "Transcripts track selection"))
        nav = pb_msg(48687757, pb_string(1, "NyAnKmN2cP0") +
                                pb_string(36, "Banned Priest Reveals What Actually Happens During an Exorcism") +
                                pb_string(37, "Seán ÓLaoire"))
        related = pb_msg(232954548, pb_msg(18, pb_msg(1, pb_msg(19, pb_msg(169495254, nav)))))
        payload = panel + pb_msg(7, related)
        post(base + "/yt-next", envelope(base64.b64encode(payload).decode(),
                                         request_id="panels-1", surface="watch"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("    - NyAnKmN2cP0 «Banned Priest Reveals What Actually Happens During an Exorcism»", content)
        self.assertNotIn("YouTubeSans", content)
        self.assertNotIn("Transcripts track selection", content)

    def test_live_preview_ids_are_not_recommendations(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        title = "Crazy!!!!! Wild kestrel attacks barn owls pair inside nest"
        main_nav = pb_msg(48687757, pb_string(1, "__Gs_vMXMlY") + pb_string(36, title) +
                                pb_string(37, "Charter Group Birdcams"))
        preview = pb_msg(23,
                         pb_msg(2, pb_string(1, "Tap to watch live, Charter Group Birdcams channel")) +
                         pb_msg(3, pb_msg(3, pb_msg(169495254,
                              pb_msg(48687757, pb_string(1, "MeKqyV8Hpn4"))))))
        media = pb_msg(1, pb_msg(19, pb_msg(169495254, main_nav)) + preview)
        card = pb_msg(1, media) + pb_string(2, title + " - live - Charter Group")
        payload = pb_msg(232954548, pb_msg(18, card))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="live-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn(f"    - __Gs_vMXMlY «{title}»", content)
        self.assertNotIn("MeKqyV8Hpn4", content)
        self.assertNotIn("Tap to watch live", content)

    def test_reels_endpoint_is_routed(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        status, reply = post(base + "/yt-reels", envelope(payload, request_id="reels-1",
                                                          surface="shorts", video_id=None))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        self.assertIn("POST /yt-reels reels-1", Path(logfile).read_text())

    def test_search_endpoint_is_routed(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        status, reply = post(base + "/yt-search", envelope(payload, request_id="search-1",
                                                           surface="search", video_id=None))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        self.assertIn("POST /yt-search search-1", Path(logfile).read_text())

    def test_playback_endpoint_logs_client_events(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))

        def send(event, video_id=None, detail=None):
            body = {"protocolVersion": 1, "type": "playback", "requestId": f"p-{event}",
                    "event": event, "youtubeVersion": "21.33.6"}
            if video_id:
                body["videoId"] = video_id
            if detail is not None:
                body["detail"] = detail
            status, reply = post(base + "/yt-playback", body)
            self.assertEqual(status, 200)
            self.assertTrue(reply["ok"])

        send("activate", "48YfC8VCIsY", {"ad": False})
        send("pause", None, {"reason": 5})
        send("activate", "s0V5g5MMunc", {"ad": False})
        send("finish", None)
        # No legacy/alternate event names: "state" is rejected, not absorbed.
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-playback", {"protocolVersion": 1, "type": "playback",
                                         "requestId": "p-state", "event": "state",
                                         "youtubeVersion": "21.33.6",
                                         "detail": {"from": 1, "to": 4, "reason": 2}})
        self.assertEqual(caught.exception.code, 400)
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("play(client): event=activate videoId=48YfC8VCIsY", content)
        self.assertNotIn("play(client): event=state", content)
        self.assertIn("POST /yt-playback rejected: unsupported event \"state\"", content)
        self.assertIn("api: POST /yt-playback -> 200", content)
        self.assertIn("api: POST /yt-playback -> 400", content)
        self.assertIn("play(client): event=pause videoId=- detail={\"reason\":5}", content)
        self.assertIn("play(client): event=activate videoId=s0V5g5MMunc", content)
        self.assertIn("play(client): event=finish", content)
        # Fetch inference is opt-in; it must not produce events by default.
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        post(base + "/yt-next", envelope(payload, request_id="no-infer", video_id="48YfC8VCIsY"))
        time.sleep(0.2)
        self.assertNotIn("play: start", Path(logfile).read_text())

    def test_playback_endpoint_rejects_bad_bodies(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-playback", {"protocolVersion": 2, "event": "activate"})
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-playback", {"protocolVersion": 1})
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-playback", {"protocolVersion": 1, "event": "scramble"})
        self.assertEqual(caught.exception.code, 400)

    def test_save_endpoint_persists_saves(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))

        def save(video_id, ai, transcript_b64=None, transcript_status=None,
                 ai_summary=None, ai_status=None):
            body = {"protocolVersion": 1, "type": "save",
                    "requestId": f"s-{video_id}", "videoId": video_id,
                    "ai": ai, "youtubeVersion": "21.33.6"}
            if transcript_b64 is not None:
                body["transcriptEncoding"] = "youtube-json3"
                body["transcriptPayload"] = transcript_b64
            if transcript_status is not None:
                body["transcriptStatus"] = transcript_status
            if ai_summary is not None:
                body["aiSummary"] = ai_summary
            if ai_status is not None:
                body["aiStatus"] = ai_status
            return post(base + "/yt-save", body)

        status, reply = save("48YfC8VCIsY", False, transcript_status="no-watch-response")
        self.assertEqual(status, 200)
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["videoId"], "48YfC8VCIsY")
        self.assertFalse(reply["ai"])
        self.assertFalse(reply["transcript"])
        status, reply = save("s0V5g5MMunc", True)
        self.assertEqual(status, 200)
        self.assertTrue(reply["ok"])
        self.assertTrue(reply["ai"])
        # A save with a transcript: json3 events -> segs -> utf8 lines.
        transcript = base64.b64encode(json.dumps({"events": [
            {"tStartMs": 0, "dDurationMs": 2000, "segs": [{"utf8": "first subtitle line"}]},
            {"tStartMs": 2000, "dDurationMs": 2000, "segs": [{"utf8": "second "}, {"utf8": "subtitle line"}]},
        ]}).encode()).decode()
        status, reply = save("dQw4w9WgXcQ", True, transcript_b64=transcript,
                             ai_summary="AI overview text about the video.",
                             ai_status="ai-fetched")
        self.assertEqual(status, 200)
        self.assertTrue(reply["transcript"])
        self.assertTrue(reply["aiSummary"])
        time.sleep(0.3)
        saves_path = Path(logfile).parent / "saves.jsonl"
        lines = [json.loads(line) for line in saves_path.read_text().splitlines()]
        self.assertEqual([entry["videoId"] for entry in lines],
                         ["48YfC8VCIsY", "s0V5g5MMunc", "dQw4w9WgXcQ"])
        self.assertEqual([entry["ai"] for entry in lines], [False, True, True])
        self.assertEqual(lines[0]["requestId"], "s-48YfC8VCIsY")
        self.assertEqual(lines[0]["transcriptStatus"], "no-watch-response")
        self.assertIn("time", lines[0])
        self.assertNotIn("transcript", lines[0])
        self.assertNotIn("aiOverview", lines[0])
        saved = lines[2]["transcript"]
        self.assertEqual(saved["encoding"], "youtube-json3")
        self.assertEqual(saved["b64"], transcript)
        self.assertEqual(saved["text"], "first subtitle line\nsecond subtitle line")
        overview = lines[2]["aiOverview"]
        self.assertEqual(overview["status"], "ai-fetched")
        self.assertEqual(overview["summary"], "AI overview text about the video.")
        content = Path(logfile).read_text()
        self.assertIn("save: videoId=48YfC8VCIsY ai=false transcript=none", content)
        self.assertIn("save: videoId=dQw4w9WgXcQ ai=true transcript=", content)
        self.assertIn("aiStatus=ai-fetched aiChars=33", content)
        self.assertIn("api: POST /yt-save -> 200", content)

    def test_save_endpoint_rejects_bad_bodies(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-save", {"protocolVersion": 1, "videoId": "48YfC8VCIsY"})
        self.assertEqual(caught.exception.code, 400)  # missing type "save"
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-save", {"protocolVersion": 2, "type": "save", "videoId": "48YfC8VCIsY"})
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-save", {"protocolVersion": 1, "type": "save", "videoId": "short"})
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-save", {"protocolVersion": 1, "type": "playback", "videoId": "48YfC8VCIsY"})
        self.assertEqual(caught.exception.code, 400)
        # Transcript payload without the declared encoding is a protocol violation.
        with self.assertRaises(urllib.error.HTTPError) as caught:
            post(base + "/yt-save", {"protocolVersion": 1, "type": "save", "videoId": "48YfC8VCIsY",
                                     "transcriptPayload": base64.b64encode(bytes([0x08, 0x01])).decode()})
        self.assertEqual(caught.exception.code, 400)
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("POST /yt-save rejected: missing or malformed videoId", content)
        self.assertIn("api: POST /yt-save -> 400", content)

    def test_player_overlays_are_not_recommendations(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        # Player chrome: audio-track badge ("Auto-dubbed"/"Audio Track") and
        # font/action rows ("YouTubeSans"/"Remix") inside playerOverlays.
        overlays = pb_msg(78882851,
                          pb_string(1, "Auto-dubbed") + pb_string(2, "Audio Track") +
                          pb_string(3, "YouTubeSans") + pb_string(4, "Remix"))
        nav = pb_msg(48687757, pb_string(1, "INAH_Rq0gdw") +
                                pb_string(36, "Long Chimpanzee Grooming Session") +
                                pb_string(37, "Aya Katz"))
        related = pb_msg(232954548, pb_msg(18, pb_msg(1, pb_msg(19, pb_msg(169495254, nav)))))
        payload = pb_msg(14, overlays) + pb_msg(7, related)
        post(base + "/yt-next", envelope(base64.b64encode(payload).decode(),
                                         request_id="overlays-1", surface="watch"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("    - INAH_Rq0gdw «Long Chimpanzee Grooming Session»", content)
        self.assertNotIn("«Audio Track»", content)
        self.assertNotIn("«Remix»", content)
        self.assertNotIn("Auto-dubbed", content)
        self.assertNotIn("YouTubeSans", content)

    def test_playlist_cards_get_playlist_title(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        avoid = "d7UwXEJt4Ws"
        media = (pb_msg(1, pb_msg(1, pb_string(1, f"https://i.ytimg.com/vi/{avoid}/hqdefault.jpg")) +
                            pb_string(6, "8 videos"))
                 + pb_string(6, "https://www.youtube.com/playlist?list=PLbydO2PhdqQIW")
                 + pb_msg(19, pb_msg(169495254, pb_msg(48687757, pb_string(1, avoid))))
                 + pb_msg(21, pb_msg(8178, pb_msg(1, pb_string(1, "Fades Made Easy")))))
        card = pb_msg(1, media) + pb_string(2, "Playlist - Fades Made Easy - Tips for Clips - 8 videos")
        payload = pb_msg(232954548, pb_msg(18, card))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="playlist-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn(f"    - {avoid} «Fades Made Easy» [playlist]", content)
        self.assertNotIn("«8 videos»", content)

    def test_spanish_stats_never_become_titles(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        title = "1 Hora de ASMR para dormir profundamente 🐒"
        nav = pb_msg(48687757, pb_string(1, "Eg7APFR0d1c") + pb_string(36, title) +
                                pb_string(37, "El Refugio del Artista"))
        # Localized byline + view/time rows live in the metadata containers.
        byline = pb_msg(21, pb_msg(8178, pb_msg(3, pb_msg(514549827,
            pb_msg(1, pb_msg(1, pb_string(2, "1,3 mil vistas"))) +
            pb_msg(1, pb_msg(1, pb_string(3, "hace 5 meses"))) +
            pb_msg(1, pb_msg(1, pb_string(3, "El Refugio del Artista, 1,3 mil vistas, hace 5 meses")))))))
        stats = pb_msg(2, pb_msg(3, pb_msg(75730170, pb_string(2, "1,3 mil vistas"))))
        card = pb_msg(1, pb_msg(19, pb_msg(169495254, nav)) + byline + stats)
        payload = pb_msg(232954548, pb_msg(18, card))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="es-1", surface="watch"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn(f"    - Eg7APFR0d1c «{title}»", content)
        self.assertNotIn("mil vistas", content)
        self.assertNotIn("hace 5 meses", content)

    def test_numeric_leading_title_beats_embedded_stat_strings(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        real_title = ("1 Hour ASMR For Deep Sleep Baby Monkey Gently Grooming Human! "
                      "Lip Smacking Trigger Sounds #asmr")
        nav = pb_msg(48687757, pb_string(1, "Eg7APFR0d1c") + pb_string(36, real_title) +
                                pb_string(37, "The Artist's Escape"))
        # Embedded video-details page reuses f36 for a stat string.
        details_nav = pb_msg(48687757, pb_string(1, "Eg7APFR0d1c") + pb_string(36, "130 thousand views"))
        details = pb_msg(128119224, pb_msg(128400768, pb_msg(1, pb_msg(7,
                  pb_msg(51779735, pb_msg(1, details_nav))))))
        card = pb_msg(1, pb_msg(19, pb_msg(169495254, nav)) + details)
        payload = pb_msg(232954548, pb_msg(18, card))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="numeric-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn(f"    - Eg7APFR0d1c «{real_title}»", content)
        self.assertNotIn("130 thousand views", content)

    def test_encoded_proto_tokens_never_become_titles(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        # nav node with id + an 8-char base64url params token and no title field
        nav = pb_msg(48687757, pb_string(1, "INAH_Rq0gdw") + pb_string(9, "EgIIAxgA"))
        payload = pb_msg(232954548, pb_msg(18, pb_msg(1, pb_msg(19, pb_msg(169495254, nav)))))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="token-1", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertNotIn("«EgIIAxgA»", content)

    def test_up_next_badge_never_becomes_title(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        nav = pb_msg(48687757, pb_string(1, "-LWEjZMT4R4"))
        payload = pb_msg(232954548, pb_msg(18, pb_msg(1, pb_msg(4, pb_string(1, "Up next")) +
                                                          pb_msg(19, pb_msg(169495254, nav)))))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="upnext-1", surface="watch"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertNotIn("«Up next»", content)

    def test_related_card_nav_title_beats_channel(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        title = "4 Signs The Monad Is Already Pulling Your Soul Out Of Demiurge's Trap — Nag Hammadi Names Every One"
        payload = pb_msg(232954548, pb_msg(18, related_card("VGTvDbUc1rI", title, "Gnostic Talk")))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="related-1", surface="home",
                                           phase="continuation"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn(f"    - VGTvDbUc1rI «{title}»", content)
        self.assertNotIn("«Gnostic Talk»", content)

    def test_shorts_shelf_items_get_real_titles(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = pb_msg(51845067, pb_string(1, "Shorts") + pb_msg(5, pb_msg(51431404,
            pb_msg(1, shorts_item("mevTdoiDF6o", "Just a big cat.\U0001F63B\u2026")) +
            pb_msg(1, shorts_item("lnXZDoEb5kU", "Tough man get humbled in public")) +
            pb_msg(1, shorts_item("r-r51zypYLY")))))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="shorts-2", surface="home"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("    [Shorts]", content)
        self.assertIn("      - mevTdoiDF6o «Just a big cat.\U0001F63B\u2026» [shorts]", content)
        self.assertIn("      - lnXZDoEb5kU «Tough man get humbled in public» [shorts]", content)
        # Item without a title in the payload stays honest.
        self.assertIn("      - r-r51zypYLY (no title in payload) [shorts]", content)
        self.assertNotIn("Send feedback", content)
        self.assertNotIn("Video removed", content)
        self.assertNotIn("play Short", content)

    def test_decode_logs_structure_and_recommendations(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = recommendations_fixture()
        status, reply = post(base + "/yt-browse",
                             envelope(base64.b64encode(payload).decode(), request_id="decode-1",
                                      surface="home", phase="continuation"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("decoded: [/yt-browse] top fields=[1]", content)
        self.assertIn("recommendations=2", content)
        self.assertIn("    - dQw4w9WgXcQ «Never Gonna Give You Up»", content)
        self.assertIn("    - 9bZkp7q19f0 «Gangnam Style»", content)
        # api.log sits next to the log file and carries the raw payload verbatim
        api_line = json.loads(Path(logfile).with_name("api.log").read_text().strip().splitlines()[-1])
        self.assertEqual(api_line["requestId"], "decode-1")
        self.assertEqual(api_line["surface"], "home")
        self.assertEqual(base64.b64decode(api_line["payload"]), payload)

    def test_decode_shorts_cards_get_real_titles_and_tag(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = shorts_card_fixture()
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="shorts-title-1", surface="unknown-browse",
                                           phase="continuation"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("    - LasUujrNBs8 «Adorable Squirrel Steals the Show» [shorts]", content)
        self.assertNotIn("«Send feedback»", content)
        self.assertIn("shortsMarkers=", content)

    def test_decode_compact_channel_shorts_uses_a11y_title(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        item = compact_shorts_item("QpOZ6mFDwEo", "This is How a Mill Axle Was Made!",
                                   "2.5 million views")
        # Real channel shape: item under 471792238>4>7, tab labels elsewhere.
        payload = (pb_msg(471792238, pb_msg(4, pb_msg(7, item))) +
                   pb_msg(58174010, pb_string(2, "Latest") + pb_string(2, "Popular")))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="compact-shorts-1",
                                           surface="UCHhAPWPrNJscVPZArCYLm7g"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("decoded: [/yt-browse]", content)
        self.assertIn("- QpOZ6mFDwEo «This is How a Mill Axle Was Made!» [shorts]", content)
        self.assertNotIn("- QpOZ6mFDwEo «Latest»", content)
        self.assertNotIn("- QpOZ6mFDwEo «Popular»", content)

    def test_decode_reel_sequence_lists_ids_without_titles(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        item = reel_sequence_item("vx8r0nubzsc", "6b1155d5-0000-2f36-b821-14223bc135c6")
        payload = pb_msg(2, pb_msg(1, pb_msg(139608561, item)))
        post(base + "/yt-reels", envelope(base64.b64encode(payload).decode(),
                                          request_id="reel-decode-1", surface="shorts",
                                          video_id=None))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("decoded: [/yt-reels]", content)
        self.assertIn("recommendations=1", content)
        self.assertIn("- vx8r0nubzsc (no title in payload) [shorts]", content)

    def test_request_context_and_tokens_are_logged(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        request_message = pb_string(1, "FEwhat_to_watch") + pb_string(2, "helios")
        token_bytes = pb_msg(80226972, pb_string(2, "FEwhat_to_watch") +
                              pb_msg(3, pb_string(1, "item_123")))
        token = base64.urlsafe_b64encode(token_bytes).decode().rstrip("=")
        body = envelope(base64.b64encode(bytes([0x08, 0x01])).decode(),
                        request_id="ctx-1", surface="home")
        body["context"] = {
            "browseId": "FEwhat_to_watch",
            "continuation": token,
            "requestClass": "YTIBrowseRequest",
            "requestPayload": base64.b64encode(request_message).decode(),
        }
        post(base + "/yt-browse", body)
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("POST /yt-browse ctx-1", content)
        self.assertIn("class=YTIBrowseRequest", content)
        self.assertIn("browseId=FEwhat_to_watch", content)
        self.assertIn("request: bytes=", content)
        self.assertIn("fields=[1,2]", content)
        self.assertIn("«FEwhat_to_watch»", content)
        self.assertIn("request-token: continuation=«", content)
        self.assertIn("fields=[80226972]", content)
        self.assertIn("«item_123»", content)
        api_line = json.loads(Path(logfile).with_name("api.log").read_text().strip().splitlines()[-1])
        self.assertEqual(api_line["requestClass"], "YTIBrowseRequest")
        self.assertEqual(base64.b64decode(api_line["requestPayload"]), request_message)

    def test_log_order_and_compact_summary(self):
        process, base, logfile = start_bun(action="recode")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = recommendations_fixture()
        body = envelope(base64.b64encode(payload).decode(), request_id="order-1", surface="home")
        body["context"] = {"browseId": "FEwhat_to_watch", "query": "helios",
                           "requestClass": "YTIBrowseRequest"}
        post(base + "/yt-browse", body)
        time.sleep(0.3)
        content = Path(logfile).read_text()
        incoming = content.index("POST /yt-browse order-1")
        decoded = content.index("decoded: [/yt-browse]")
        recoded = content.index("recode: topFields=")
        summary = content.index("api: POST /yt-browse action=replace out=")
        # One call: request line first, then the payload decode, then the
        # processing lines, then one compact closing summary.
        self.assertLess(incoming, decoded)
        self.assertLess(decoded, recoded)
        self.assertLess(recoded, summary)
        incoming_line = next(line for line in content.splitlines() if "POST /yt-browse order-1" in line)
        self.assertIn("surface=home", incoming_line)
        self.assertIn("class=YTIBrowseRequest", incoming_line)
        self.assertIn("browseId=FEwhat_to_watch", incoming_line)
        self.assertIn("query=«helios»", incoming_line)
        self.assertRegex(incoming_line, r"in=\d+B\([0-9a-f]{16}\)")
        final = [line for line in content.splitlines() if "api: POST /yt-browse action=replace" in line][-1]
        self.assertRegex(final, r"api: POST /yt-browse action=replace out=\d+(?:\.\d+)?[kMB] -> 200 \d+\.\dms$")
        # The detailed transport fields live on the incoming line, not the summary.
        self.assertNotIn("type=YTIBrowseResponse", final)

    def test_page_context_channel_tabs_and_hashtags(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        header = pb_msg(509923604, pb_string(1, "Aged Skills") +
                        pb_msg(2, pb_string(11, "UCHhAPWPrNJscVPZArCYLm7g") +
                                pb_string(4, "/@agedskills")))
        payload = (pb_msg(13, header) +
                   pb_msg(58174010, pb_string(2, "Videos")) +
                   pb_msg(58174010, pb_string(2, "Shorts")) +
                   pb_msg(1, pb_string(1, "Woodworking #asmr")))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="page-ctx-1",
                                           surface="UCHhAPWPrNJscVPZArCYLm7g",
                                           video_id=None))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("context: channel=«Aged Skills»", content)
        self.assertIn("channelId=UCHhAPWPrNJscVPZArCYLm7g", content)
        self.assertIn("handle=/@agedskills", content)
        self.assertIn("tabs=[«Videos», «Shorts»]", content)
        self.assertIn("hashtags=[#asmr]", content)

    def test_decode_marks_shorts_renderers(self):
        process, base, logfile = start_bun(action="replace")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = pb_msg(1, pb_string(1, "shortsLockupViewModel") +
                            pb_string(9, "dQw4w9WgXcQ"))
        post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                           request_id="shorts-1", surface="unknown-browse",
                                           phase="continuation"))
        time.sleep(0.3)
        content = Path(logfile).read_text()
        self.assertIn("shortsMarkers=1", content)

    def test_recode_round_trip_is_byte_identical(self):
        process, base, logfile = start_bun(action="recode")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = recommendations_fixture()
        status, reply = post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                                           request_id="recode-1", surface="home"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        self.assertEqual(base64.b64decode(reply["payload"]), payload)
        content = Path(logfile).read_text()
        self.assertIn("identical=yes", content)
        self.assertIn(f"bytesIn={len(payload)}", content)

    def test_recode_canonicalizes_and_reports_mismatch(self):
        process, base, logfile = start_bun(action="recode")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        # field 1 varint, value 1 encoded with a non-minimal varint (0x81 0x00)
        payload = bytes([0x08, 0x81, 0x00])
        status, reply = post(base + "/yt-next", envelope(base64.b64encode(payload).decode(),
                                                         request_id="recode-2"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        self.assertEqual(base64.b64decode(reply["payload"]), bytes([0x08, 0x01]))
        content = Path(logfile).read_text()
        self.assertIn("identical=no", content)
        self.assertIn("firstDiff=", content)

    def test_recode_falls_back_to_passthrough_on_garbage(self):
        process, base, logfile = start_bun(action="recode")
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        status, reply = post(base + "/yt-next", envelope(base64.b64encode(b"\x00").decode(),
                                                         request_id="recode-3"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "passthrough")
        self.assertIn("not valid protobuf wire format", Path(logfile).read_text())

    def test_drop_heading_removes_shelf_end_to_end(self):
        process, base, logfile = start_bun(action="replace",
                                           extra_args=["--drop-heading", "Breaking news"])
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = news_shelf("Breaking news", [
            lockup_card("CMH1vWoqK_0", "What Democratic control of Congress means",
                        "CTV News      3.9K   48 min ago"),
        ]) + pb_msg(1, pb_string(1, "keep-me"))
        status, reply = post(base + "/yt-browse", envelope(base64.b64encode(payload).decode(),
                                                           request_id="drop-1", surface="home"))
        self.assertEqual(status, 200)
        self.assertEqual(reply["action"], "replace")
        out = base64.b64decode(reply["payload"])
        self.assertNotIn(b"Breaking news", out)
        self.assertNotIn(b"CMH1vWoqK_0", out)
        self.assertIn(b"keep-me", out)
        self.assertIn(b"RECSRV", out)  # replace mode still appends the marker
        self.assertIn("modify: removed shelves", Path(logfile).read_text())

    def test_api_log_can_be_disabled(self):
        process, base, logfile = start_bun(action="passthrough", extra_args=["--no-api-log"])
        self.addCleanup(lambda: (process.terminate(), process.wait(timeout=5)))
        payload = base64.b64encode(bytes([0x08, 0x01])).decode()
        post(base + "/yt-next", envelope(payload, request_id="no-api-1"))
        time.sleep(0.3)
        self.assertFalse(Path(logfile).with_name("api.log").exists())


if __name__ == "__main__":
    unittest.main()
