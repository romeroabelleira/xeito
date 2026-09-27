#!/usr/bin/env python3
"""Bench 1: CPU typed decisions while a large model generates on the GPU.

Measures, in both directions:
  * decision latency (System One encoder and grammar-constrained small LLM, both on CPU)
    with the GPU idle vs. with the large model generating, at concurrency 1 and 4;
  * large-model generation throughput alone vs. while CPU decisions run.

Standard library only. Endpoints and key files come from the environment:

  XEITO_LAYA_URL        default http://127.0.0.1:8082
  XEITO_LAYA_KEY_FILE   file with the laya-serve bearer key
  XEITO_LLAMA_URL       default http://127.0.0.1:8081
  XEITO_LLAMA_KEY_FILE  file with the llama-server bearer key
  XEITO_OLLAMA_URL      default http://127.0.0.1:11434
  XEITO_LARGE_MODEL     default qwen3.6:27b
  XEITO_BENCH_N         requests per worker per cell, default 30

Writes a JSON result file (argv[1], default bench1.json) and prints a summary table.
No host identifiers are recorded. The large model's GPU/CPU split is taken from Ollama's
/api/ps, because partial CPU offload of the large model changes the result.
"""

import json
import os
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ENV = os.environ
LAYA_URL = ENV.get("XEITO_LAYA_URL", "http://127.0.0.1:8082")
LLAMA_URL = ENV.get("XEITO_LLAMA_URL", "http://127.0.0.1:8081")
OLLAMA_URL = ENV.get("XEITO_OLLAMA_URL", "http://127.0.0.1:11434")
LARGE_MODEL = ENV.get("XEITO_LARGE_MODEL", "qwen3.6:27b")
N = int(ENV.get("XEITO_BENCH_N", "30"))


def key(var):
    path = ENV.get(var)
    return open(os.path.expanduser(path)).read().strip() if path else ""


LAYA_KEY = key("XEITO_LAYA_KEY_FILE")
LLAMA_KEY = key("XEITO_LLAMA_KEY_FILE")

TRIAGE_STATE = {
    "test": "CheckoutTest total includes tax",
    "output": "Assertion with == failed. left: 107.0 right: 108.0",
    "diff_stat": "lib/pricing.ex | 4 ++--",
}
TRIAGE_OPTIONS = {
    "flaky": "timing, randomness, intermittent failure with no code cause",
    "code_bug": "the code under test computes a wrong result",
    "test_bug": "the test expectation itself is wrong",
    "env_problem": "missing dependency, configuration or infrastructure",
}

LAYA_BODY = {
    "model": "multilingual",
    "state": TRIAGE_STATE,
    "questions": {
        "triage": {
            "type": "choice",
            "instructions": "Why is this test failing?",
            "criteria": TRIAGE_OPTIONS,
        }
    },
}

LLAMA_BODY = {
    "messages": [
        {"role": "system", "content": "Classify why the test failed. Answer with JSON only."},
        {"role": "user", "content": "\n".join(f"{k}: {v}" for k, v in TRIAGE_STATE.items())},
    ],
    "response_format": {
        "type": "json_schema",
        "json_schema": {
            "name": "triage",
            "strict": True,
            "schema": {
                "type": "object",
                "properties": {"value": {"type": "string", "enum": list(TRIAGE_OPTIONS)}},
                "required": ["value"],
                "additionalProperties": False,
            },
        },
    },
    "temperature": 0,
    "max_tokens": 20,
    "chat_template_kwargs": {"enable_thinking": False},
}

LOAD_PROMPT = (
    "Write a detailed, multi-section technical essay about the history of state machines "
    "in software engineering, from Mealy and Moore machines to Harel statecharts and modern "
    "workflow engines. Be thorough."
)


def post(url, body, token="", timeout=600):
    headers = {"content-type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def laya_decide():
    return post(LAYA_URL + "/v1/systemone", LAYA_BODY, LAYA_KEY)["answers"]["triage"]["choice"]


def llama_decide():
    out = post(LLAMA_URL + "/v1/chat/completions", LLAMA_BODY, LLAMA_KEY)
    return json.loads(out["choices"][0]["message"]["content"])["value"]


DECIDERS = {"laya": laya_decide, "llama": llama_decide}


# --- CPU utilisation sampler (Linux /proc/stat) -----------------------------------------

def cpu_times():
    with open("/proc/stat") as f:
        parts = [int(x) for x in f.readline().split()[1:]]
    idle = parts[3] + parts[4]
    return sum(parts), idle


class CpuSampler:
    def __init__(self):
        self.samples, self._stop = [], threading.Event()

    def __enter__(self):
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()
        return self

    def _run(self):
        prev = cpu_times()
        while not self._stop.wait(0.5):
            cur = cpu_times()
            total, idle = cur[0] - prev[0], cur[1] - prev[1]
            if total:
                self.samples.append(100.0 * (1 - idle / total))
            prev = cur

    def __exit__(self, *exc):
        self._stop.set()
        self._t.join()

    def mean(self):
        return round(statistics.fmean(self.samples), 1) if self.samples else None


# --- Large-model load generator ----------------------------------------------------------

class LargeLoad:
    """Keeps the large model generating continuously; records tokens/s per request."""

    def __init__(self):
        self.rates, self._stop = [], threading.Event()

    def one(self):
        out = post(
            OLLAMA_URL + "/api/generate",
            {
                "model": LARGE_MODEL,
                "prompt": LOAD_PROMPT,
                "stream": False,
                "options": {"num_predict": 256, "temperature": 0.7},
                "think": False,
            },
        )
        if out.get("eval_duration"):
            return out["eval_count"] / (out["eval_duration"] / 1e9)
        return None

    def __enter__(self):
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()
        return self

    def _run(self):
        while not self._stop.is_set():
            rate = self.one()
            if rate:
                self.rates.append(rate)

    def __exit__(self, *exc):
        self._stop.set()
        self._t.join()


# --- Measurement -------------------------------------------------------------------------

def pct(values, p):
    values = sorted(values)
    k = max(0, min(len(values) - 1, round(p / 100 * (len(values) - 1))))
    return values[k]


def run_cell(decider, concurrency):
    fn = DECIDERS[decider]
    lat, answers = [], []

    def worker(_):
        for _ in range(N):
            t = time.perf_counter()
            answers.append(fn())
            lat.append((time.perf_counter() - t) * 1000)

    t0 = time.perf_counter()
    with CpuSampler() as cpu:
        with ThreadPoolExecutor(concurrency) as pool:
            list(pool.map(worker, range(concurrency)))
    wall = time.perf_counter() - t0
    return {
        "decider": decider,
        "concurrency": concurrency,
        "n": len(lat),
        "p50_ms": round(pct(lat, 50), 1),
        "p95_ms": round(pct(lat, 95), 1),
        "mean_ms": round(statistics.fmean(lat), 1),
        "throughput_per_s": round(len(lat) / wall, 2),
        "cpu_busy_pct": cpu.mean(),
        "answers": {a: answers.count(a) for a in set(answers)},
    }


def large_alone(seconds=60):
    load = LargeLoad()
    rates, t_end = [], time.time() + seconds
    with CpuSampler() as cpu:
        while time.time() < t_end:
            r = load.one()
            if r:
                rates.append(r)
    return {"tok_s_mean": round(statistics.fmean(rates), 1), "requests": len(rates), "cpu_busy_pct": cpu.mean()}


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "bench1.json"
    result = {"date": time.strftime("%Y-%m-%d"), "n_per_worker": N, "large_model": LARGE_MODEL, "cells": []}

    print("warm-up …", flush=True)
    for fn in DECIDERS.values():
        for _ in range(3):
            fn()
    LargeLoad().one()  # loads the large model into VRAM
    with urllib.request.urlopen(OLLAMA_URL + "/api/ps") as resp:
        for m in json.load(resp).get("models", []):
            if m.get("name") == LARGE_MODEL or m.get("model") == LARGE_MODEL:
                result["large_offload"] = {
                    "size_gb": round(m["size"] / 1e9, 1),
                    "vram_gb": round(m["size_vram"] / 1e9, 1),
                    "gpu_share": round(m["size_vram"] / m["size"], 3),
                    "context_length": m.get("context_length"),
                }
    print("large model offload:", result.get("large_offload"), flush=True)

    print("large model alone …", flush=True)
    result["large_alone"] = large_alone()

    for gpu_state in ("gpu_idle", "gpu_busy"):
        for decider in DECIDERS:
            for conc in (1, 4):
                label = f"{gpu_state} {decider} c={conc}"
                print(label, "…", flush=True)
                if gpu_state == "gpu_busy":
                    with LargeLoad() as load:
                        time.sleep(5)  # let the first generation start
                        cell = run_cell(decider, conc)
                    cell["large_tok_s_during"] = (
                        round(statistics.fmean(load.rates), 1) if load.rates else None
                    )
                else:
                    cell = run_cell(decider, conc)
                cell["gpu"] = gpu_state
                result["cells"].append(cell)

    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    print(f"\nlarge model alone: {result['large_alone']}")
    print(f"{'gpu':9} {'decider':6} {'c':>2} {'p50':>8} {'p95':>8} {'req/s':>7} {'cpu%':>6} {'large tok/s':>11}")
    for c in result["cells"]:
        print(
            f"{c['gpu']:9} {c['decider']:6} {c['concurrency']:>2} {c['p50_ms']:>8} {c['p95_ms']:>8} "
            f"{c['throughput_per_s']:>7} {c['cpu_busy_pct']!s:>6} {c.get('large_tok_s_during') or '-':>11}"
        )


if __name__ == "__main__":
    main()
