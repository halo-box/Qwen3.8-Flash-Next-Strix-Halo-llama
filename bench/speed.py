#!/usr/bin/env python3
"""Prefill and decode speed of the running server, measured the way Mia's AI Lab reports it.

Methodology follows MiaAI-Lab's Qwen3.8-Flash-Next recipes (tools/bench.py and the README tables there):

- Prefill: fresh synthetic prose of a given length (a new seed each run, so nothing is
  prefix-cached), ending with "Summarize the text above in one sentence.", 16 tokens out.
  Reported: prompt tokens, prefill tok/s and time to first token, median of the runs.
- Decode, per task: "code" asks for a Python quicksort at temperature 0, "prose" asks why the
  sky is blue with the server's default sampling; 256 tokens, median of 5 runs at one request.
- With --clients: the same decode tasks barrier-started N at a time. Reported: aggregate tok/s
  (all generated tokens over the wall time), median per-request tok/s, median TTFT.

Speeds come from llama-server's own per-request timings (prompt_ms, predicted_per_second), as
Mia's come from TensorFold's. Prompt lengths are exact: they are sized with /tokenize.

usage: bench/speed.py [--url URL] [--label NAME] [--jsonl FILE] [--clients 1,2,4,8]
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import threading
import time
import urllib.request

WORDS = ("river engine winter market signal garden bridge letter theory method paper field window voice "
         "harbor lantern orchard ledger quarry canyon meadow compass anchor beacon cellar chimney "
         "harvest island journey kettle ladder mirror needle oyster pebble quilt ribbon saddle timber "
         "tunnel valley wagon yarn atlas barrel candle desert ember feather glacier hammer ivory jacket "
         "kernel lever magnet nectar orbit pillar quartz rocket shelter thread umbrella velvet whistle "
         "time year people way day man thing woman life child world school state family student group "
         "country problem hand part place case week company system program question work number night").split()
TASKS = {
    "code": ("Write a Python quicksort with docstring and tests.", 0.0),
    "prose": ("Explain why the sky is blue in a few paragraphs.", None),
}


def post(url, body, timeout=3600):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def n_tokens(base, text):
    with post(base + "/tokenize", {"content": text}) as r:
        return len(json.load(r)["tokens"])


def synthetic(base, tokens, seed):
    """Random prose that tokenizes to `tokens` tokens (+/- one sentence) with the suffix."""
    rng = random.Random(seed)
    suffix = "\n\nSummarize the text above in one sentence."
    words = []

    def grow(n):
        while n > 0:
            s = [rng.choice(WORDS) for _ in range(rng.randint(6, 16))]
            s[0] = s[0].capitalize()
            words.extend(s[:-1] + [s[-1] + "."])
            n -= len(s)

    grow(int(tokens * 0.75))
    for _ in range(6):  # converge on the target with the real tokenizer
        have = n_tokens(base, " ".join(words) + suffix)
        if abs(have - tokens) <= 32:
            break
        if have < tokens:
            grow(int((tokens - have) * 0.8))
        else:
            del words[-max(1, int((have - tokens) * 0.8)):]
    return " ".join(words) + suffix


def complete(base, prompt, max_tokens, temperature=None, seed=None):
    body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens, "stream": True,
            "cache_prompt": False}
    if temperature is not None:
        body["temperature"] = temperature
    if seed is not None:
        body["seed"] = seed
    t0 = time.perf_counter()
    first, timings = None, {}
    with post(base + "/v1/chat/completions", body) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line.endswith("[DONE]"):
                continue
            chunk = json.loads(line[5:])
            delta = (chunk.get("choices") or [{}])[0].get("delta") or {}
            if first is None and (delta.get("content") or delta.get("reasoning_content")):
                first = time.perf_counter()
            if chunk.get("timings"):
                timings = chunk["timings"]
    end = time.perf_counter()
    return {"t0": t0, "end": end, "ttft": (first or end) - t0, **timings}


def concurrent(base, jobs):
    barrier, out = threading.Barrier(len(jobs)), [None] * len(jobs)

    def worker(i, kw):
        barrier.wait()
        out[i] = complete(base, **kw)

    ts = [threading.Thread(target=worker, args=(i, kw)) for i, kw in enumerate(jobs)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return out


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--label", default="run")
    p.add_argument("--jsonl", help="append every request's record here")
    p.add_argument("--prefill", default="8192,16384,32768,65536,131072")
    p.add_argument("--prefill-runs", type=int, default=3, help="runs per size; 64k and up use 1")
    p.add_argument("--decode-runs", type=int, default=5)
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--clients", default="1", help="decode concurrency levels, e.g. 1,2,4,8")
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    base = a.url.rstrip("/")
    rows = []

    def keep(kind, **rec):
        rows.append({"label": a.label, "kind": kind, **rec})
        return rec

    complete(base, "Say hi.", 8)  # warm-up
    print(f"## {a.label}\n")
    print("**Prefill**\n\n| Prompt | Tokens | Prefill speed | Time to first token |\n| ---: | ---: | ---: | ---: |")
    for size in [int(x) for x in a.prefill.split(",") if x]:
        runs = a.prefill_runs if size < 65536 else 1
        recs = []
        for i in range(runs):
            prompt = synthetic(base, size, a.seed * 100_003 + size + i)
            recs.append(keep("prefill", size=size, **complete(base, prompt, 16, temperature=0)))
        n = med([r["prompt_n"] for r in recs])
        tps = med([r["prompt_per_second"] for r in recs])
        ttft = med([r["ttft"] for r in recs])
        print(f"| {size // 1024}k | {n:,.0f} | {tps:,.0f} tok/s | {ttft:.2f} s |", flush=True)

    for task, (prompt, temp) in TASKS.items():
        print(f"\n**Decode, {task}**\n\n| Concurrent requests | Aggregate | Per request | Time to first token "
              "| Draft acceptance |\n| ---: | ---: | ---: | ---: | ---: |")
        for c in [int(x) for x in a.clients.split(",") if x]:
            recs = []
            for i in range(a.decode_runs if c == 1 else max(1, a.decode_runs // 2)):
                jobs = [{"prompt": prompt, "max_tokens": a.max_tokens, "temperature": temp,
                         "seed": None if temp == 0 else a.seed + 1000 * i + j} for j in range(c)]
                batch = concurrent(base, jobs) if c > 1 else [complete(base, **jobs[0])]
                wall = max(r["end"] for r in batch) - min(r["t0"] for r in batch)
                agg = sum(r.get("predicted_n", 0) for r in batch) / wall
                for r in batch:
                    keep("decode", task=task, clients=c, aggregate=agg, **r)
                recs.append((agg, batch))
            agg = med([x[0] for x in recs])
            per = med([r["predicted_per_second"] for _, b in recs for r in b])
            ttft = med([r["ttft"] for _, b in recs for r in b])
            dn = sum(r.get("draft_n", 0) for _, b in recs for r in b)
            da = sum(r.get("draft_n_accepted", 0) for _, b in recs for r in b)
            acc = f"{da / dn:.2f}" if dn else "-"
            print(f"| {c} | {agg:.1f} tok/s | {per:.1f} tok/s | {ttft * 1000:.0f} ms | {acc} |", flush=True)

    if a.jsonl:
        with open(a.jsonl, "a") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
