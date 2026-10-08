"""Greedy consistency check: one prompt answered alone, then by N concurrent requests.

usage: python3 bench/consistency.py BASE_URL N

Reports, per prompt, how many concurrent answers equal the solo answer at
temperature 0 and the shortest prefix they share with it. llama.cpp is not
batch-invariant, so some drift is expected; garbage is not.
"""
import json
import os.path
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE, N = sys.argv[1], int(sys.argv[2])
PROMPTS = [
    "Write a Python function that returns the n-th prime number, with a docstring.",
    "Explain in three short paragraphs why the sky is blue.",
]


def ask(prompt):
    body = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 256,
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)["choices"][0]["message"]["content"]


for p in PROMPTS:
    solo = ask(p)
    with ThreadPoolExecutor(N) as ex:
        many = list(ex.map(ask, [p] * N))
    same = sum(m == solo for m in many)
    shared = min(len(os.path.commonprefix([solo, m])) for m in many)
    print(f"  {same}/{N} identical, all share the first {shared}/{len(solo)} chars: {p[:40]}...")
