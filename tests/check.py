#!/usr/bin/env python3
"""Functional checks against the running server. Stdlib only.

  tests/check.py                   chat, streaming, tool call, image, oversized request
  tests/check.py --window          also one ~250k-token request: the full window works (slow, ~20 min)
  tests/check.py --long N          also N concurrent ~200k-token requests (every slot its own window; slow)

Exits non-zero if any check fails.
"""
import argparse
import base64
import json
import random
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib
import functools

print = functools.partial(print, flush=True)  # noqa: A001 - progress shows under nohup too

p = argparse.ArgumentParser()
p.add_argument("--url", default="http://127.0.0.1:8080")
p.add_argument("--window", action="store_true", help="one request near the full 262k window")
p.add_argument("--long", type=int, default=0, help="concurrent ~200k-token requests to run")
a = p.parse_args()
BASE = a.url.rstrip("/")
failed = []


def post(path, body, timeout=3600):
    req = urllib.request.Request(BASE + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def chat(messages, **kw):
    body = {"messages": messages, "max_tokens": 512, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}, **kw}
    with post("/v1/chat/completions", body) as r:
        return json.load(r)["choices"][0]


def check(name, fn):
    t0 = time.time()
    try:
        detail = fn()
        print(f"  ok    {name} ({time.time() - t0:.1f}s){': ' + detail if detail else ''}")
    except Exception as e:  # noqa: BLE001 - report every failure the same way
        print(f"  FAIL  {name}: {e}")
        failed.append(name)


def t_chat():
    out = chat([{"role": "user", "content": "What is 17 * 23? Reply with the number only."}])
    assert "391" in out["message"]["content"], out["message"]["content"]


def t_stream():
    body = {"messages": [{"role": "user", "content": "Count from 1 to 5."}], "max_tokens": 64, "stream": True,
            "chat_template_kwargs": {"enable_thinking": False}}
    chunks = 0
    with post("/v1/chat/completions", body) as r:
        for raw in r:
            if raw.startswith(b"data:") and b"[DONE]" not in raw:
                chunks += 1
    assert chunks > 3, f"{chunks} chunks"
    return f"{chunks} chunks"


def t_tool():
    tools = [{"type": "function", "function": {
        "name": "get_weather", "description": "Current weather for a city",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    out = chat([{"role": "user", "content": "What's the weather in Lisbon?"}], tools=tools, tool_choice="required")
    calls = out["message"].get("tool_calls") or []
    assert calls and calls[0]["function"]["name"] == "get_weather", out["message"]
    assert "lisbon" in json.loads(calls[0]["function"]["arguments"])["city"].lower()


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def t_image():
    url = "data:image/png;base64," + base64.b64encode(png(64, 64, (220, 20, 20))).decode()
    try:
        out = chat([{"role": "user", "content": [{"type": "image_url", "image_url": {"url": url}},
                                                  {"type": "text", "text": "What color is this image? One word."}]}])
    except urllib.error.HTTPError as e:
        if e.code in (400, 500) and b"image" in e.read().lower():
            return "skipped: server has no vision projector (MMPROJ_FILE)"
        raise
    assert "red" in out["message"]["content"].lower(), out["message"]["content"]


def n_tokens(text):
    with post("/tokenize", {"content": text}) as r:
        return len(json.load(r)["tokens"])


def synthetic(tokens, seed):
    """Random words that tokenize to within ~0.5% of `tokens`, sized with the server's tokenizer."""
    rng = random.Random(seed)
    vocab = "river engine winter market signal garden bridge letter theory method paper field window".split()
    words = [rng.choice(vocab) for _ in range(tokens)]
    for _ in range(8):
        have = n_tokens(" ".join(words))
        if abs(have - tokens) <= tokens // 200:
            break
        n = int(len(words) * tokens / have)
        words = words[:n] if n < len(words) else words + [rng.choice(vocab) for _ in range(n - len(words))]
    return " ".join(words)


def t_oversized():
    prompt = synthetic(270_000, 1)
    assert n_tokens(prompt) > 262_144, "test prompt is not over the window"
    try:
        chat([{"role": "user", "content": prompt}], max_tokens=8)
    except urllib.error.HTTPError as e:
        assert e.code == 400, f"HTTP {e.code}"
        return f"refused with HTTP 400: {e.read().decode()[:80]}"
    raise AssertionError("a 270k-token prompt was accepted")


def t_window():
    # ~250k tokens, deliberately not a multiple of 16: the last prompt chunk is then a partial
    # tile, the case that faulted the GPU in flash_attn_mask_to_KV_max before the patch.
    prompt = synthetic(250_003, 7) + "\n\nWhat is the first word above? One word."
    n = n_tokens(prompt)
    out = chat([{"role": "user", "content": prompt}], max_tokens=16)
    return f"{n} prompt tokens, answered {out['message']['content'].strip()[:20]!r}"


def t_long(n):
    prompts = [synthetic(200_000, 100 + i) + "\n\nWhat is the first word above? One word." for i in range(n)]
    out, errs = [None] * n, []

    def run(i):
        try:
            out[i] = chat([{"role": "user", "content": prompts[i]}], max_tokens=16)
        except Exception as e:  # noqa: BLE001
            errs.append(f"request {i}: {e}")

    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert not errs, "; ".join(errs)
    return f"{n} x ~200k tokens completed together"


print(f"checking {BASE}")
check("chat", t_chat)
check("streaming", t_stream)
check("tool call", t_tool)
check("image input", t_image)
check("request over 262k refused", t_oversized)
if a.window:
    check("one request near the full 262k window", t_window)
if a.long:
    check(f"{a.long} concurrent long-context requests", lambda: t_long(a.long))
print("all checks passed" if not failed else f"{len(failed)} failed: {', '.join(failed)}")
sys.exit(1 if failed else 0)
