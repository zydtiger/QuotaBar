"""QuotaBar Claude activity collector.

Reads Claude Code transcripts (``~/.claude/projects/**/*.jsonl``) on the machine
it runs on and prints usage counts as one JSON document in the
``quotabar.activity`` schema, version 1. It never emits prompt or response
text, file paths, or credentials. Python 3.8+ standard library only, so it can
be piped to a remote ``python3 -`` without installing anything.

usage: python3 claude_activity_collector.py [--since ISO8601] [--root DIR]
"""

import argparse
import datetime as dt
import json
import os
import pathlib
import socket
import sys

SCHEMA = "quotabar.activity"
VERSION = 1

# Harness-generated entries stored with role "user" that a person did not type.
NOISE_PREFIXES = (
    "<command-name>",
    "<command-message>",
    "<local-command",
    "<task-notification",
    "<system-reminder>",
    "<bash-input>",
    "<bash-stdout>",
    "<user-prompt-submit-hook>",
    "<side-sessions-event>",
    "<ci-monitor-event>",
    "[Request interrupted",
    "Caveat:",
)

TOKEN_COMPONENTS = (
    ("input_tokens", "input"),
    ("output_tokens", "output"),
    ("cache_read_input_tokens", "cache_read"),
    ("cache_creation_input_tokens", "cache_creation"),
)


def parse_instant(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(dt.timezone.utc)


def hour_bucket(instant):
    return instant.replace(minute=0, second=0, microsecond=0)


def iso(instant):
    return instant.strftime("%Y-%m-%dT%H:%M:%SZ")


def typed_text(content):
    """Return typed text, or None when the entry is a tool result or has no text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        blocks = [block for block in content if isinstance(block, dict)]
        if any(block.get("type") == "tool_result" for block in blocks):
            return None
        return "\n".join(block.get("text", "") for block in blocks if block.get("type") == "text")
    return None


def is_user_message(entry):
    if entry.get("type") != "user":
        return False
    for flag in ("isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"):
        if entry.get(flag):
            return False
    text = typed_text((entry.get("message") or {}).get("content"))
    if text is None:
        return False
    stripped = text.strip()
    return bool(stripped) and not stripped.startswith(NOISE_PREFIXES)


def is_mirror(path):
    """Desktop-app SSH sessions are mirrored locally as ssh-<id>/<id>.jsonl."""
    parent = path.parent.name
    return parent.startswith("ssh-") and parent[4:] == path.stem


def collect(root, since):
    messages = {}  # (bucket, session, mirror) -> count
    seen_messages = set()
    api_messages = {}  # (message id, request id) -> [first instant, session, mirror, model, usage]
    since_ts = since.timestamp()

    for path in sorted(root.rglob("*.jsonl")):
        try:
            if path.stat().st_mtime < since_ts:
                continue
            handle = path.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        mirror = is_mirror(path)
        with handle:
            for line in handle:
                if '"type":"user"' not in line and '"type":"assistant"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                instant = parse_instant(entry.get("timestamp"))
                session = entry.get("sessionId")
                if instant is None or not isinstance(session, str) or not session:
                    continue
                kind = entry.get("type")
                if kind == "user":
                    if instant < since:
                        continue
                    bucket = hour_bucket(instant)
                    uid = entry.get("uuid")
                    if uid in seen_messages or not is_user_message(entry):
                        continue
                    seen_messages.add(uid)
                    key = (bucket, session, mirror)
                    messages[key] = messages.get(key, 0) + 1
                elif kind == "assistant":
                    message = entry.get("message")
                    if not isinstance(message, dict):
                        continue
                    usage = message.get("usage")
                    model = message.get("model")
                    if not isinstance(usage, dict) or not isinstance(model, str) or model.startswith("<"):
                        continue
                    key = (message.get("id") or entry.get("uuid"), entry.get("requestId"))
                    values = {}
                    for field, component in TOKEN_COMPONENTS:
                        raw = usage.get(field)
                        if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw > 0:
                            values[component] = raw
                    previous = api_messages.get(key)
                    if previous is None:
                        api_messages[key] = [instant, session, mirror, model, values]
                    else:
                        # Streaming writes one line per content block; keep the largest count seen.
                        # The message belongs to the hour of its first line, so a message that
                        # started before --since was already counted by the previous run.
                        previous[0] = min(previous[0], instant)
                        merged = previous[4]
                        for component, raw in values.items():
                            merged[component] = max(merged.get(component, 0), raw)

    rows = []
    for (bucket, session, mirror), count in messages.items():
        rows.append({"metric": "user_messages", "bucket": iso(bucket), "session": session,
                     "mirror": mirror, "labels": {}, "value": count})
    tokens = {}
    for first, session, mirror, model, values in api_messages.values():
        if first < since:
            continue
        bucket = hour_bucket(first)
        for component, raw in values.items():
            key = (bucket, session, mirror, model, component)
            tokens[key] = tokens.get(key, 0) + raw
    for (bucket, session, mirror, model, component), value in tokens.items():
        rows.append({"metric": "tokens", "bucket": iso(bucket), "session": session, "mirror": mirror,
                     "labels": {"model": model, "component": component}, "value": value})
    rows.sort(key=lambda row: (row["bucket"], row["metric"], row["session"], sorted(row["labels"].items())))
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description="Print Claude Code usage counts for QuotaBar.")
    parser.add_argument("--since", help="UTC instant; rows start at its hour (default: 30 days ago)")
    parser.add_argument("--root", help="transcript root (default: $CLAUDE_CONFIG_DIR/projects or ~/.claude/projects)")
    args = parser.parse_args(argv)

    now = dt.datetime.now(dt.timezone.utc)
    if args.since:
        since = parse_instant(args.since)
        if since is None:
            parser.error("--since must be an ISO 8601 instant with a timezone")
    else:
        since = now - dt.timedelta(days=30)
    since = hour_bucket(since)

    if args.root:
        root = pathlib.Path(args.root).expanduser()
    else:
        config = os.environ.get("CLAUDE_CONFIG_DIR")
        root = (pathlib.Path(config).expanduser() if config else pathlib.Path.home() / ".claude") / "projects"

    document = {
        "schema": SCHEMA,
        "version": VERSION,
        "device": {"name": socket.gethostname().split(".")[0] or "unknown"},
        "generated_at": iso(now),
        "since": iso(since),
        "metrics": {
            "tokens": {"label": "Tokens", "unit": "tokens"},
            "user_messages": {"label": "User messages", "unit": "messages"},
        },
        "rows": collect(root, since) if root.is_dir() else [],
    }
    json.dump(document, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
