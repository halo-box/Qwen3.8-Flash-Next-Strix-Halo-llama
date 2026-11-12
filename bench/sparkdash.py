#!/usr/bin/env python3
"""Decode and prefill speed of the running server, measured with sparkDash, as Mia's AI Lab recipes report it.

Runs MiaAI-Lab/sparkDash (its own prompts and protocol) in a container on the host network, registers this
machine as a local unit pointing at the server's port, and drives its Decode and Prefill benchmarks through
the REST API, with the settings of Mia's Qwen3.8-Flash-Next README:

- Decode, prose: temperature 0.7, thinking on. Decode, code: temperature 0, thinking off, a different
  Python task per stream. 400 tokens a stream. Per request is sparkDash's mean per-stream decode speed,
  (completion_tokens - 1) / (last token - first token); aggregate is all decode tokens over the window
  from the first stream's first token to the last stream's last token.
- Prefill: cold prompts with a unique prefix per run; speed from llama-server's own prompt timings.

Decode runs --repeat times (default 3) and the tables show the median of each level, since a single
prose run varies by 10-25% with sampling on.

usage: bench/sparkdash.py [--label NAME] [--port 8080] [--clients 1,2,4] [--repeat 3] [--prefill 4096,...,131072]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMAGE = "sparkdash:da20ac5"
CONTAINER = "sparkdash-bench-recipe"
API = "http://127.0.0.1:5555/api"


def call(method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data, {"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"sparkDash {method} {path}: HTTP {e.code} {e.read().decode()[:300]}")


def start_sparkdash():
    running = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER],
                             capture_output=True, text=True).stdout.strip()
    if running != "true":
        subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)
        cfg = ROOT / "bench" / "data" / "sparkdash"
        cfg.mkdir(parents=True, exist_ok=True)
        subprocess.run(["docker", "run", "-d", "--name", CONTAINER, "--network", "host",
                        "-v", f"{cfg}:/app/config", IMAGE], check=True, capture_output=True)
    for _ in range(60):
        try:
            return call("GET", "/sparks")
        except SystemExit:
            raise
        except Exception:  # noqa: BLE001 - not listening yet
            time.sleep(1)
    sys.exit("sparkDash did not come up on :5555")


def unit_id(port):
    listing = start_sparkdash()
    sparks = listing.get("sparks", listing) if isinstance(listing, dict) else listing
    for s in sparks:
        if s.get("isLocal") and port in (s.get("llmPorts") or []):
            return s["id"]
    return call("POST", "/sparks", {"id": f"strix-halo-{port}", "name": f"strix-halo:{port}", "isLocal": True,
                                    "llmPorts": [port]})["spark"]["id"]


def run(sid, kind, body):
    job = call("POST", f"/sparks/{sid}/llm/{kind}", body)
    bench_id = job.get("benchId") or job.get("id")
    while True:
        time.sleep(5)
        st = call("GET", f"/sparks/{sid}/llm/{kind}/{bench_id}")
        st = st.get("job", st)
        if st.get("status") in ("completed", "failed", "cancelled"):
            if st["status"] != "completed":
                sys.exit(f"{kind} {st['status']}: {st.get('error')}")
            return st


def decode_table(jobs):
    """Median over the repeated runs of each concurrency level."""
    rows = ["| Concurrent requests | Aggregate | Per request | TTFT |", "| ---: | ---: | ---: | ---: |"]
    for waves in zip(*(j["results"] for j in jobs)):
        ok = [w for w in waves if not w.get("error")]
        if not ok:
            rows.append(f"| {waves[0]['concurrency']} | {waves[0]['error']} | | |")
            continue
        med = {k: statistics.median(w[k] for w in ok) for k in ("aggregateDecodeTps", "meanDecodeTps", "meanTtftMs")}
        rows.append(f"| {ok[0]['concurrency']} | {med['aggregateDecodeTps']:.1f} tok/s | {med['meanDecodeTps']:.1f} tok/s "
                    f"| {med['meanTtftMs']:.0f} ms |")
    return "\n".join(rows)


def prefill_table(job):
    rows = ["| Prompt tokens | Prefill | TTFT |", "| ---: | ---: | ---: |"]
    for r in job["results"]:
        if r.get("error"):
            rows.append(f"| {r['targetTokens']:,} | {r['error']} | |")
            continue
        rows.append(f"| {r['promptTokens']:,} | {r['prefillTps']:,.0f} tok/s | {r['ttftMs'] / 1000:.2f} s |")
    return "\n".join(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--label", default="run")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--clients", default="1,2,4", help="decode concurrency levels; empty skips decode")
    p.add_argument("--max-tokens", type=int, default=400)
    p.add_argument("--repeat", type=int, default=3, help="decode runs per type; the tables show the median")
    p.add_argument("--prefill", default="4096,8192,16384,32768,65536,131072", help="empty skips prefill")
    p.add_argument("--stop", action="store_true", help="remove the sparkDash container afterwards")
    a = p.parse_args()

    sid = unit_id(a.port)
    out = {"label": a.label}
    md = [f"## {a.label}"]
    clients = [int(x) for x in a.clients.split(",") if x]
    if clients:
        for task, temp, thinking in (("prose", 0.7, True), ("code", 0.0, False)):
            jobs = [run(sid, "bench", {"concurrencies": clients, "maxTokens": a.max_tokens, "promptType": task,
                                       "temperature": temp, "thinking": thinking}) for _ in range(a.repeat)]
            out[task] = jobs
            md += [f"\n**Decode, {task}** (median of {a.repeat} runs)\n", decode_table(jobs)]
            print(md[-2] + "\n" + md[-1], flush=True)
    sizes = [int(x) for x in a.prefill.split(",") if x]
    if sizes:
        job = run(sid, "prefill-bench", {"contextSizes": sizes})
        out["prefill"] = job
        md += ["\n**Prefill** (cold prompts)\n", prefill_table(job)]
        print(md[-2] + "\n" + md[-1], flush=True)

    res = ROOT / "results" / "sparkdash"
    res.mkdir(parents=True, exist_ok=True)
    (res / f"{a.label}.json").write_text(json.dumps(out, indent=1))
    (res / f"{a.label}.md").write_text("\n".join(md) + "\n")
    if a.stop:
        subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)


if __name__ == "__main__":
    main()
