"""
utils.py — Shared utilities for the multi-agent demo.

Contains the LLM streaming logic, metrics writer, and shared constants
used by both the orchestrator and specialist agents.
"""

import json
import os
import sys
import time

from openai import OpenAI

# ─── Shared Paths ───────────────────────────────────────────

COMMS_DIR = os.path.join(os.path.dirname(__file__), ".agent_comms")
BUILD_DIR = os.path.join(os.path.dirname(__file__), "website_build")

# ─── ANSI Colors ────────────────────────────────────────────

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
WHITE = "\033[1;37m"
RED = "\033[31m"


# ─── Metrics ────────────────────────────────────────────────

def write_metrics(name: str, status: str, tokens: int, elapsed: float, tps: float = None):
    """Write metrics to .agent_comms/metrics_{name}.json atomically."""
    if tps is None:
        tps = tokens / elapsed if elapsed > 0 else 0.0
    metrics = {
        "name": name,
        "status": status,
        "tokens": tokens,
        "elapsed_s": round(elapsed, 2),
        "tps": round(tps, 1),
    }
    path = os.path.join(COMMS_DIR, f"metrics_{name}.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(metrics, f)
    os.replace(tmp, path)


# ─── LLM Streaming ─────────────────────────────────────────

def repeated_suffix_length(text: str, min_unit: int = 8, max_unit: int = 80, repeats: int = 4) -> int:
    """Return the length of a repeated suffix loop, or 0 when none is found."""
    compact = text[-(max_unit * repeats + max_unit):]
    for unit_len in range(min_unit, min(max_unit, len(compact) // repeats) + 1):
        suffix = compact[-unit_len:]
        if not suffix.strip():
            continue
        if compact.endswith(suffix * repeats):
            return unit_len * (repeats - 1)
    return 0


def repeated_line_loop(text: str, repeats: int = 4) -> bool:
    """Detect exact repeated non-empty lines near the end of the output."""
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if len(lines) < repeats:
        return False
    last = lines[-1]
    return bool(last) and all(line == last for line in lines[-repeats:])


def _usage_to_dict(usage: object) -> dict:
    """Return SDK usage objects, Pydantic extras, or plain dicts as one dict."""
    if isinstance(usage, dict):
        return usage

    data = {}
    model_dump = getattr(usage, "model_dump", None)
    if callable(model_dump):
        try:
            dumped = model_dump()
            if isinstance(dumped, dict):
                data.update(dumped)
        except Exception:
            pass

    extra = getattr(usage, "model_extra", None)
    if isinstance(extra, dict):
        data.update(extra)

    for field in (
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
        "input_tokens",
        "output_tokens",
        "predicted_n",
        "n_predicted",
        "tokens_predicted",
        "predicted_tokens",
        "generation_tokens_per_second",
        "completion_tokens_per_second",
        "output_tokens_per_second",
        "tokens_per_second",
        "predicted_per_second",
        "predicted_tokens_per_second",
        "tokens_predicted_per_second",
        "generation_duration",
        "completion_duration",
        "output_duration",
        "generation_ms",
        "completion_ms",
        "output_ms",
        "predicted_ms",
        "t_predicted_ms",
        "t_token_generation",
        "usage",
        "timings",
    ):
        value = getattr(usage, field, None)
        if value is not None:
            data[field] = value

    return data


def _metric_sources(data: dict):
    """Yield a metrics dict plus common nested server timing containers."""
    yield data

    for field in ("usage", "timings"):
        value = data.get(field)
        if value is None:
            continue
        nested = value if isinstance(value, dict) else _usage_to_dict(value)
        if not nested:
            continue
        yield nested

        timings = nested.get("timings")
        if isinstance(timings, dict):
            yield timings


def _first_number(data: dict, *fields: str) -> float | None:
    for field in fields:
        for source in _metric_sources(data):
            value = source.get(field)
            if value is None:
                continue
            try:
                return float(value)
            except (TypeError, ValueError):
                continue
    return None


def _extract_completion_tokens(usage: object) -> int | None:
    """Extract generated token count from an OpenAI-compatible usage object."""
    data = _usage_to_dict(usage)
    tokens = _first_number(
        data,
        "completion_tokens",
        "output_tokens",
        "predicted_n",
        "n_predicted",
        "tokens_predicted",
        "predicted_tokens",
    )
    return int(tokens) if tokens is not None else None


def _extract_generation_tps(usage: object) -> float | None:
    """Extract server-reported generation throughput when a backend provides it."""
    data = _usage_to_dict(usage)
    tps = _first_number(
        data,
        "generation_tokens_per_second",
        "completion_tokens_per_second",
        "output_tokens_per_second",
        "tokens_per_second",
        "predicted_per_second",
        "predicted_tokens_per_second",
        "tokens_predicted_per_second",
    )
    if tps is not None:
        return tps

    tokens = _first_number(
        data,
        "completion_tokens",
        "output_tokens",
        "predicted_n",
        "n_predicted",
        "tokens_predicted",
        "predicted_tokens",
    )
    duration = _first_number(
        data,
        "generation_duration",
        "completion_duration",
        "output_duration",
    )
    if tokens is not None and duration and duration > 0:
        return tokens / duration

    duration_ms = _first_number(
        data,
        "generation_ms",
        "completion_ms",
        "output_ms",
        "predicted_ms",
        "t_predicted_ms",
        "t_token_generation",
    )
    if tokens is not None and duration_ms and duration_ms > 0:
        return tokens / (duration_ms / 1000)

    return None


def _estimate_generated_tokens(text: str) -> int:
    """Estimate generated tokens from streamed text for live metrics only."""
    if not text:
        return 0
    return max(1, round(len(text.encode("utf-8")) / 4))


def _estimate_live_tokens(text: str, delta_count: int) -> int:
    """Estimate live tokens without depending on a server's chunking style."""
    return max(delta_count, _estimate_generated_tokens(text))


def stream_llm(
    api_url: str,
    messages: list[dict],
    agent_name: str,
    color: str = "1;37",
    max_tokens: int = 2048,
    model: str = "default",
    api_key: str | None = None,
    loop_guard: bool = True,
) -> str:
    """Stream an LLM response, update metrics, and print tokens in color.

    Args:
        api_url:    Full chat completions URL (e.g. http://…/v1/chat/completions).
        messages:   OpenAI-style messages list.
        agent_name: Name used for metrics files.
        color:      ANSI color code for terminal output.
        max_tokens: Maximum tokens to generate.
        model:      Model name to pass to the OpenAI-compatible server.
        api_key:    Optional API key. Defaults to OPENAI_API_KEY or sk-no-key.
        loop_guard: Stop early when the stream repeats the same text.

    Returns:
        The full response text (content only, excluding reasoning tokens).
    """
    base_url = api_url.rsplit("/chat/completions", 1)[0]
    client = OpenAI(
        base_url=base_url,
        api_key=api_key or os.environ.get("OPENAI_API_KEY") or "sk-no-key",
    )

    full = ""
    generated_text = ""
    stream_delta_count = 0
    empty_chunk_count = 0
    server_tokens = None  # Will be set from usage if available
    server_generation_tps = None  # Will be set from usage if available
    stopped_reason = None
    start_t = time.time()
    generation_start_t = None

    try:
        write_metrics(agent_name, "running", 0, 0.0, 0.0)

        last_poll_t = None
        poll_interval = 0.3
        tokens_at_last_poll = 0

        request = dict(
            model=model,
            messages=messages,
            max_tokens=max_tokens,
            stream=True,
        )
        try:
            response = client.chat.completions.create(
                **request,
                stream_options={"include_usage": True},
            )
        except Exception:
            # Some OpenAI-compatible servers do not accept stream_options.
            response = client.chat.completions.create(**request)

        for chunk in response:
            # Some servers attach final usage/timing fields to the usage object;
            # llama.cpp versions may put generation timings on the chunk itself.
            chunk_tokens = _extract_completion_tokens(chunk)
            if chunk_tokens is not None:
                server_tokens = chunk_tokens
            chunk_tps = _extract_generation_tps(chunk)
            if chunk_tps is not None:
                server_generation_tps = chunk_tps

            # Final chunk with usage stats (no choices)
            if hasattr(chunk, "usage") and chunk.usage:
                continue

            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta

            # Handle reasoning tokens (thinking models)
            rc = getattr(delta, "reasoning_content", None)
            c = delta.content or ""

            if not rc and not c:
                empty_chunk_count += 1
                if loop_guard and empty_chunk_count >= 50:
                    stopped_reason = "empty stream"
                    break
                continue

            empty_chunk_count = 0
            if rc:
                generated_text += rc
                sys.stdout.write(f"\033[2;37m{rc}\033[0m")
                sys.stdout.flush()

            if c:
                full += c
                generated_text += c
                sys.stdout.write(f"\033[{color}m{c}\033[0m")
                sys.stdout.flush()
                if loop_guard:
                    trim_len = repeated_suffix_length(full)
                    if trim_len:
                        full = full[:-trim_len]
                        generated_text = generated_text[:-trim_len]
                        stopped_reason = "repeated output"
                        break
                    if repeated_line_loop(full):
                        stopped_reason = "repeated line"
                        break

            if rc or c:
                stream_delta_count += 1
                now = time.time()
                if generation_start_t is None:
                    generation_start_t = now
                    last_poll_t = now
                    tokens_at_last_poll = 0
                    continue

                if (now - last_poll_t) >= poll_interval:
                    tokens = (
                        server_tokens
                        if server_tokens is not None
                        else _estimate_live_tokens(generated_text, stream_delta_count)
                    )
                    token_delta = max(0, tokens - tokens_at_last_poll)
                    tps = token_delta / (now - last_poll_t)
                    write_metrics(agent_name, "running", tokens, now - start_t, tps)
                    tokens_at_last_poll = tokens
                    last_poll_t = now

    except Exception as e:
        sys.stdout.write(f"\n{RED}[ERROR] {e}{RESET}\n")

    if stopped_reason:
        sys.stdout.write(f"\n{RED}[stopped: {stopped_reason}]{RESET}\n")

    total_elapsed = time.time() - start_t
    # Use server-reported token count if available, otherwise fall back to text estimate.
    final_tokens = (
        server_tokens
        if server_tokens is not None
        else _estimate_live_tokens(generated_text, stream_delta_count)
    )
    generation_elapsed = (
        time.time() - generation_start_t
        if generation_start_t is not None
        else total_elapsed
    )
    if server_generation_tps is not None:
        final_tps = server_generation_tps
    else:
        final_tps = final_tokens / generation_elapsed if generation_elapsed > 0 else 0.0
    write_metrics(agent_name, "done", final_tokens, total_elapsed, final_tps)

    return full
