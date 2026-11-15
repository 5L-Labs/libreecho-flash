#!/usr/bin/env python3
"""Hermes Gadget device client for a LibreEcho Echo Dot.

Connects to the Hermes gateway's gadget platform (protocol v1, see
https://github.com/Adolanium/hermes-gadget-sdk/blob/main/docs/protocol.md) as a
speaker-only device, so Hermes can push spoken messages with send_message, cron
delivery or the gadget home channel. Speaker audio arrives as mono PCM16 at
48 kHz and is written to LibreEcho's announcement bus, a FIFO of S16LE 48 kHz
stereo that ducks music while it plays.

Needs Python 3.10+ and websockets. Runs as root under libreecho-local.
"""

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import queue
import secrets
import struct
import threading
import time
from pathlib import Path

from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

VERSION = "0.1.0"
SUBPROTOCOL = "hermes-gadget.v1"
AUTH_CONTEXT = b"hermes-gadget/v1|"
CHANNEL_AUDIO = 0x01
RATE = 48000  # LibreEcho's bus rate: Hermes resamples to the rate we declare.
GAP = bytes(2048 * 4)  # ttsd's underrun filler: 2048 stereo frames of silence
GAP_WAIT_S = 0.04
MAX_GAP_S = 5.0
MAX_STREAM_S = 600  # longest message kept (10 min); the rest is dropped

log = logging.getLogger("hermes-gadget-dot")


def device_identity(state_dir: Path, upstream: str):
    """Load or create this upstream's 32-byte device key; the id is derived from it."""
    path = state_dir / ("device.key" if upstream == "default" else f"{upstream}.key")
    if path.exists():
        key = base64.b64decode(path.read_text().strip())
    else:
        state_dir.mkdir(parents=True, exist_ok=True)
        key = secrets.token_bytes(32)
        tmp = path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(key).decode() + "\n")
        os.replace(tmp, path)
    if len(key) != 32:
        raise SystemExit(f"{path} does not hold a 32-byte key")
    return key, "hg-" + hashlib.sha256(key).hexdigest()[:16]


def auth_mac(key: bytes, device_id: str, nonce: str) -> str:
    msg = AUTH_CONTEXT + device_id.encode() + b"|" + nonce.encode()
    return base64.b64encode(hmac.new(key, msg, hashlib.sha256).digest()).decode()


def mono_to_stereo(pcm: bytes) -> bytes:
    pcm = pcm[: len(pcm) & ~1]
    out = bytearray(len(pcm) * 2)
    lo, hi = pcm[0::2], pcm[1::2]
    out[0::4], out[1::4], out[2::4], out[3::4] = lo, hi, lo, hi
    return bytes(out)


class Stream:
    """One spoken message: mono PCM chunks from one upstream, ended by None."""

    def __init__(self, owner: str):
        self.owner = owner
        self.chunks: "queue.Queue[bytes | None]" = queue.Queue()
        self.aborted = False
        self.queued_s = 0.0
        self.protocol_id: int | None = None
        self.ended = False  # audio.end arrived: every chunk is queued, only playback is left


class BusWriter(threading.Thread):
    """Owns the announcement FIFO and plays streams one at a time, in arrival order.

    Several upstream Hermes instances share this queue. A stream from another
    upstream waits its turn instead of cutting in. A new stream from the same
    upstream replaces an earlier one that is still arriving (the protocol's
    "a new stream replaces the one playing"), but one that has ended and is only
    playing out its queued audio is left to finish: Hermes sends each message
    faster than real time, so its next message usually starts while the last
    one's tail is still queued here, and that tail is not stale. Blocking
    writes stay off the event loop. Each stream opens the FIFO on its first
    chunk and closes it at the end, as ttsd does; while a stream is open and no
    audio is queued, short silence gaps keep the bus alive, and after MAX_GAP_S
    without audio the stream ends.
    """

    def __init__(self, bus: str, status: str):
        super().__init__(daemon=True)
        self.bus, self.status = bus, status
        self.cond = threading.Condition()
        self.pending: "list[Stream]" = []  # pending[0] is playing or about to

    def open_stream(self, owner: str) -> Stream:
        stream = Stream(owner)
        with self.cond:
            for old in self.pending:
                if old.owner == owner and not old.ended:
                    self._abort(old)
            self.pending.append(stream)
            self.cond.notify()
        return stream

    def write(self, stream: Stream, pcm: bytes) -> None:
        stream.queued_s += len(pcm) / 2 / RATE
        if stream.queued_s > MAX_STREAM_S:
            if stream.queued_s - len(pcm) / 2 / RATE <= MAX_STREAM_S:
                log.warning("[%s] message longer than %d s; dropping the rest", stream.owner, MAX_STREAM_S)
            return
        stream.chunks.put(mono_to_stereo(pcm))

    @staticmethod
    def end(stream: Stream) -> None:
        stream.ended = True
        stream.chunks.put(None)

    def abort(self, stream: Stream) -> None:
        with self.cond:
            self._abort(stream)

    def _abort(self, stream: Stream) -> None:
        stream.aborted = True
        stream.chunks.put(None)  # wakes the writer if it is waiting on this stream
        if stream in self.pending[1:]:
            self.pending.remove(stream)

    def _wait_for_idle_bus(self) -> None:
        # Two writers interleave samples, so wait (up to 10 s) for ttsd to finish.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with open(self.status) as f:
                    if not json.load(f).get("buses", {}).get("announcement"):
                        return
            except (OSError, ValueError):
                return
            time.sleep(0.1)
        log.warning("announcement bus still busy after 10 s; playing anyway")

    def run(self) -> None:
        while True:
            with self.cond:
                while not self.pending:
                    self.cond.wait()
                stream = self.pending[0]
            if not stream.aborted:
                self._play(stream)
            with self.cond:
                self.pending.remove(stream)

    def _play(self, stream: Stream) -> None:
        fd, gap_s = None, 0.0
        try:
            while not stream.aborted:
                try:
                    data = stream.chunks.get(timeout=GAP_WAIT_S if fd is not None else MAX_GAP_S)
                except queue.Empty:
                    if fd is None:  # nothing ever arrived
                        return
                    gap_s += GAP_WAIT_S + len(GAP) / 4 / RATE
                    if gap_s >= MAX_GAP_S or not self._write(fd, GAP):
                        return
                    continue
                if data is None or stream.aborted:
                    return
                if fd is None:
                    self._wait_for_idle_bus()
                    try:
                        fd = os.open(self.bus, os.O_WRONLY | os.O_CLOEXEC)
                    except OSError as exc:
                        log.error("cannot open %s: %s", self.bus, exc)
                        return
                    log.info("[%s] announcement bus opened", stream.owner)
                gap_s = 0.0
                if not self._write(fd, data):
                    return
        finally:
            if fd is not None:
                os.close(fd)
                log.info("[%s] announcement bus closed%s", stream.owner, " (aborted)" if stream.aborted else "")

    def _write(self, fd: int, data: bytes) -> bool:
        view = memoryview(data)
        while view:
            try:
                view = view[os.write(fd, view):]
            except InterruptedError:
                continue
            except OSError as exc:
                log.error("announcement bus write failed: %s", exc)
                return False
        return True


class Device:
    """One gadget connection to one upstream Hermes gateway."""

    def __init__(self, cfg: dict, key: bytes, device_id: str, writer: BusWriter):
        self.cfg, self.key, self.device_id, self.writer = cfg, key, device_id, writer
        self.upstream = cfg["upstream"]
        self.stream_id: int | None = None  # protocol stream id still receiving frames
        self.stream: Stream | None = None  # the most recent stream, which may still be playing
        self.frames = 0

    def hello(self) -> dict:
        msg = {
            "type": "hello", "proto": 1, "device_id": self.device_id,
            "name": self.cfg.get("name", "Echo Dot"), "board": "libreecho-biscuit", "firmware": VERSION,
            "caps": {"speaker": {"rate": RATE, "format": "pcm16", "formats": ["pcm16"],
                                 "buffer_ms": int(self.cfg.get("buffer_ms", 4000))}},
            "actions": [],
        }
        if self.cfg.get("token"):
            msg["token"] = self.cfg["token"]
        return msg

    async def session(self) -> None:
        async with connect(self.cfg["server"], subprotocols=[SUBPROTOCOL], max_size=2 * 1024 * 1024,
                           open_timeout=10, ping_interval=None) as ws:
            await ws.send(json.dumps(self.hello()))
            heartbeat = 20
            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3 * heartbeat)
                except asyncio.TimeoutError:
                    log.warning("[%s] no frame for %d s; reconnecting", self.upstream, 3 * heartbeat)
                    return
                if isinstance(raw, bytes):
                    self.on_binary(raw)
                    continue
                msg = json.loads(raw)
                kind = msg.get("type")
                if kind == "challenge":
                    auth = ({"type": "auth", "mac": auth_mac(self.key, self.device_id, msg["nonce"])}
                            if msg.get("enrolled") else
                            {"type": "auth", "key": base64.b64encode(self.key).decode()})
                    await ws.send(json.dumps(auth))
                elif kind == "welcome":
                    heartbeat = int(msg.get("heartbeat_s") or 20)
                    log.info("[%s] connected as %s, paired=%s", self.upstream, self.device_id, msg.get("paired"))
                elif kind == "pairing":
                    log.warning("[%s] PAIRING CODE %s: on that Hermes host run `%s` (or `hermes gadget pair`)",
                                self.upstream, msg.get("code"), msg.get("command"))
                elif kind in ("paired", "unpaired"):
                    log.info("[%s] %s %s", self.upstream, kind, msg.get("reason", ""))
                elif kind == "ping":
                    await ws.send(json.dumps({"type": "pong", "ts": msg.get("ts")}))
                elif kind == "audio.start":
                    self.on_audio_start(msg)
                elif kind == "audio.end":
                    if msg.get("stream") == self.stream_id:
                        log.info("[%s] audio.end stream %s after %.2f s", self.upstream, self.stream_id,
                                 self.frames / RATE)
                        self.writer.end(self.stream)
                        self.stream_id = None
                elif kind == "audio.abort":
                    # The server sends audio ahead of real time, so a stream that already
                    # ended can still be playing from the queue: stop that one too.
                    if self.stream is not None and msg.get("stream") in (self.stream_id, self.stream.protocol_id):
                        log.info("[%s] audio.abort stream %s", self.upstream, msg.get("stream"))
                        self.writer.abort(self.stream)
                        self.stream_id = None
                elif kind == "action":  # every action needs exactly one answer
                    await ws.send(json.dumps({"type": "action.result", "id": msg.get("id"), "ok": False,
                                              "error": "this device has no actions"}))
                elif kind in ("reply", "notice", "transcript"):
                    if not msg.get("interim"):
                        log.info("[%s] %s: %s", self.upstream, kind, msg.get("text", "")[:200])
                elif kind == "error":
                    log.error("[%s] server error %s: %s", self.upstream, msg.get("code"), msg.get("message"))

    def on_audio_start(self, msg: dict) -> None:
        if msg.get("format", "pcm16") != "pcm16" or int(msg.get("rate", 0)) != RATE:
            log.error("[%s] unsupported audio %s @ %s; ignoring stream", self.upstream,
                      msg.get("format"), msg.get("rate"))
            self.stream_id = None
            return
        # open_stream replaces this upstream's earlier streams; other upstreams keep their turn.
        self.stream = self.writer.open_stream(self.upstream)
        self.stream_id = self.stream.protocol_id = msg.get("stream")
        self.frames = 0
        log.info("[%s] audio.start stream %s", self.upstream, self.stream_id)

    def on_binary(self, data: bytes) -> None:
        if len(data) < 4:
            return
        channel, stream, _seq = struct.unpack_from("<BBH", data)
        if channel == CHANNEL_AUDIO and stream == self.stream_id and self.stream is not None:
            self.frames += (len(data) - 4) // 2
            self.writer.write(self.stream, data[4:])

    async def run_forever(self) -> None:
        backoff = 1
        while True:
            started = time.monotonic()
            try:
                await self.session()
            # KeyError, TypeError, AttributeError: a malformed frame ends only this upstream's session.
            except (OSError, WebSocketException, asyncio.TimeoutError, ValueError,
                    KeyError, TypeError, AttributeError) as exc:
                log.warning("[%s] connection to %s ended: %s", self.upstream, self.cfg["server"], exc)
            if self.stream is not None:
                self.writer.abort(self.stream)
            self.stream_id = self.stream = None
            backoff = 1 if time.monotonic() - started > 60 else min(backoff * 2, 60)
            await asyncio.sleep(backoff)


def upstreams(cfg: dict) -> "list[dict]":
    """The config's upstream Hermes gateways, each with name and server.

    {"name": "Office Echo", "upstreams": [{"name": "hermes-a", "server": "ws://..."}, ...]}
    The older single form, {"server": "ws://...", "name": ...}, is upstream "default".
    """
    items = cfg.get("upstreams") or [{"name": "default", "server": cfg["server"], "token": cfg.get("token")}]
    out, seen = [], set()
    for item in items:
        name = item.get("name", "")
        if not name or not all(c.isalnum() or c in "-_." for c in name) or name in seen:
            raise SystemExit(f"upstream names must be unique and use letters, digits, - _ or .: {name!r}")
        seen.add(name)
        out.append({**{k: v for k, v in cfg.items() if k != "upstreams"}, **item, "upstream": name,
                    "name": item.get("device_name", cfg.get("name", "Echo Dot"))})
    return out


async def run_all(devices: "list[Device]") -> None:
    await asyncio.gather(*(d.run_forever() for d in devices))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--config", type=Path, required=True, help="JSON: name and upstreams (see upstreams())")
    p.add_argument("--state", type=Path, required=True, help="directory holding the device keys")
    p.add_argument("--bus", default="/run/libreecho-audio/announcement.pcm")
    p.add_argument("--bus-status", default="/run/libreecho-audio/status.json")
    p.add_argument("--print-ids", action="store_true", help="print each upstream's device id and exit")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfgs = upstreams(json.loads(args.config.read_text()))
    # One key per upstream: a Hermes host learns the key it enrolls, so a shared key
    # would let one Hermes impersonate this Dot to another.
    identities = [device_identity(args.state, c["upstream"]) for c in cfgs]
    if args.print_ids:
        for c, (_key, device_id) in zip(cfgs, identities):
            print(c["upstream"], device_id, c["server"])
        return
    writer = BusWriter(args.bus, args.bus_status)
    writer.start()
    devices = []
    for c, (key, device_id) in zip(cfgs, identities):
        log.info("hermes-gadget-dot %s, upstream %s, device %s, server %s",
                 VERSION, c["upstream"], device_id, c["server"])
        devices.append(Device(c, key, device_id, writer))
    asyncio.run(run_all(devices))


if __name__ == "__main__":
    main()
