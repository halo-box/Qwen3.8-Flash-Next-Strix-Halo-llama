"""Greedy consistency check: one prompt answered alone, then by N concurrent requests.

usage: python3 bench/consistency.py BASE_URL N

Every concurrent answer must equal the solo answer at temperature 0. Prints one
summary line and exits non-zero on a mismatch.
"""
import json
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


bad = 0
for p in PROMPTS:
    solo = ask(p)
    with ThreadPoolExecutor(N) as ex:
        many = list(ex.map(ask, [p] * N))
    same = sum(m == solo for m in many)
    bad += N - same
    print(f"  {same}/{N} identical to solo ({len(solo)} chars): {p[:40]}...")
print("  PASS" if bad == 0 else f"  FAIL: {bad} mismatches")
sys.exit(1 if bad else 0)
