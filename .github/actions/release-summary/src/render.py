#!/usr/bin/env python3
"""Turn the AI step's structured release summary into a Slack
chat.postMessage payload (a thread reply under the release banner).

Citations are trusted only when they come from the collector's PRS_FILE:
a PR number the AI cites but the collector never saw is dropped, and
Linear ids are read from the kept PRs, never from AI text. An item left
with no kept PR is dropped whole.

The action is advisory-only and must never fail the release: every error
path prints a ::warning::, writes rendered=false and exits 0.

Env in:
  AI_RESULT         JSON from the AI step: {"headline": str, "features": [item],
                    "bug_fixes": [item], "tech_debt": [item], "tests": [item]},
                    item = {"summary": str, "prs": [int]}, most impactful first
  PRS_FILE          collector JSON: repository, version, previous_tag,
                    server_url, pull_requests [{number, url, title, linear}]
  LINEAR_WORKSPACE  Linear workspace slug (default: loft)
  CHANNEL_ID        Slack channel, copied into the payload
  THREAD_TS         Slack thread timestamp, copied into the payload
  PAYLOAD_FILE      path the payload JSON is written to
Env out ($GITHUB_OUTPUT, skipped when unset):
  rendered          true | false
  item_count        items that survived validation
  dropped_refs      PR numbers dropped (unknown to the collector or not ints)
"""
from __future__ import annotations

import json
import os
import re
import sys

# Output order and Slack titles of the AI result's groups.
GROUPS = (
    ("features", "Features"),
    ("bug_fixes", "Bug fixes"),
    ("tech_debt", "Tech debt"),
    ("tests", "Tests"),
)
DEFAULT_WORKSPACE = "loft"
SECTION_LIMIT = 3000  # Slack cap on the text of one section block
BLOCK_LIMIT = 50  # Slack cap on blocks in one message
LINEAR_ID = re.compile(r"[A-Za-z][A-Za-z0-9]*-[0-9]+")


def warn(msg: str) -> None:
    # Collapse whitespace so a newline in msg can never start a second
    # workflow command.
    print(f"::warning::release-summary: {' '.join(str(msg).split())}")


def emit_kv(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")
    except OSError as e:
        warn(f"could not write output {key}: {e}")


def fail_soft(msg: str) -> None:
    warn(msg)
    emit_kv("rendered", "false")
    sys.exit(0)


def escape(text: str) -> str:
    """Escape the three characters Slack mrkdwn treats as control."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def read_json(path: str, name: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        fail_soft(f"{name} could not be read: {e}")


def index_prs(collector: dict) -> dict[int, dict]:
    """PR number to entry, for every well-formed pull request the collector
    reported."""
    prs: dict[int, dict] = {}
    entries = collector.get("pull_requests")
    for pr in entries if isinstance(entries, list) else []:
        if not isinstance(pr, dict):
            continue
        number, url = pr.get("number"), pr.get("url")
        if is_int(number) and isinstance(url, str) and url:
            prs[number] = pr
    return prs


def cite(refs, prs: dict[int, dict]) -> tuple[list[int], int]:
    """Split an item's PR refs into the kept numbers (deduped, first-seen
    order) and the count of dropped ones. A repeated number counts once."""
    kept: list[int] = []
    seen: set[int] = set()
    dropped = 0
    for ref in refs if isinstance(refs, list) else []:
        if not is_int(ref):
            dropped += 1
        elif ref not in seen:
            seen.add(ref)
            if ref in prs:
                kept.append(ref)
            else:
                dropped += 1
    return kept, dropped


def linear_ids(kept: list[int], prs: dict[int, dict]) -> list[str]:
    """Linear ids of the kept PRs, deduped, first-seen order."""
    ids: list[str] = []
    for number in kept:
        found = prs[number].get("linear")
        for ident in found if isinstance(found, list) else []:
            if (isinstance(ident, str) and LINEAR_ID.fullmatch(ident)
                    and ident not in ids):
                ids.append(ident)
    return ids


def render_items(items: list, prs: dict[int, dict],
                 workspace: str) -> tuple[list[str], int]:
    """One mrkdwn bullet per item that cites at least one known PR, plus the
    number of PR refs dropped along the way."""
    bullets: list[str] = []
    dropped = 0
    for item in items:
        if not isinstance(item, dict):
            warn("skipped an item that is not an object")
            continue
        kept, lost = cite(item.get("prs"), prs)
        dropped += lost
        summary = item.get("summary")
        if not isinstance(summary, str) or not summary.strip():
            warn("skipped an item without a summary")
            continue
        if not kept:
            warn("dropped an item that cites no known PR")
            continue
        refs = [f"<{prs[n]['url']}|#{n}>" for n in kept]
        refs += [f"<https://linear.app/{workspace}/issue/{i}|{i}>"
                 for i in linear_ids(kept, prs)]
        text = escape(" ".join(summary.split()))
        bullets.append(f"• {text} ({', '.join(refs)})")
    return bullets, dropped


def truncate(text: str, limit: int) -> str:
    """Cut text to at most limit chars with a trailing ellipsis, without
    leaving half a link or entity behind."""
    if len(text) <= limit:
        return text
    cut = re.sub(r"(<[^>]*|&[a-z]*)$", "", text[: limit - 1])
    return cut.rstrip() + "…"


def pack_group(title: str, bullets: list[str]) -> list[tuple[str, int]]:
    """Pack a group's bullets into section texts of at most SECTION_LIMIT
    chars, as (text, bullet_count). Only the first carries the title."""
    chunks: list[tuple[str, int]] = []
    cur, count = f"*{title}*", 0
    for bullet in bullets:
        if count and len(cur) + 1 + len(bullet) > SECTION_LIMIT:
            chunks.append((cur, count))
            cur, count = "", 0
        sep = "\n" if cur else ""
        cur += sep + truncate(bullet, SECTION_LIMIT - len(cur) - len(sep))
        count += 1
    if count:
        chunks.append((cur, count))
    return chunks


def section(text: str) -> dict:
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def build_blocks(title: str, headline: str, groups: list[tuple[str, list[str]]],
                 footer: str) -> list[dict]:
    """Header, one or more sections per group, optional overflow line, footer.
    The footer is always the last of at most BLOCK_LIMIT blocks."""
    head = f"*{title}*\n{headline}" if headline else f"*{title}*"
    chunks = [c for name, bullets in groups for c in pack_group(name, bullets)]
    room = BLOCK_LIMIT - 2  # header and footer
    overflow: list[dict] = []
    if len(chunks) > room:
        room -= 1  # the "more items" line
        hidden = sum(count for _, count in chunks[room:])
        chunks = chunks[:room]
        overflow = [section(f"…and {hidden} more items, see the compare link.")]
    return [
        section(truncate(head, SECTION_LIMIT)),
        *(section(text) for text, _ in chunks),
        *overflow,
        {"type": "context", "elements": [{"type": "mrkdwn", "text": footer}]},
    ]


def build_payload(channel: str, thread_ts: str, collector: dict,
                  headline: str, groups: list[tuple[str, list[str]]]) -> dict:
    version, previous = collector["version"], collector["previous_tag"]
    title = f"What changed in {version} since {previous}"
    compare = f"{previous}...{version}"
    url = (f"{collector['server_url'].rstrip('/')}/"
           f"{collector['repository']}/compare/{compare}")
    footer = (f"<{url}|Compare {compare}> · AI-generated from PR "
              "descriptions, may contain mistakes")
    return {
        "channel": channel,
        "thread_ts": thread_ts,
        "text": title,
        "blocks": build_blocks(title, headline, groups, footer),
        "unfurl_links": False,
        "unfurl_media": False,
    }


def group_items(result: dict, key: str) -> list:
    value = result.get(key)
    if value is None:
        return []
    if not isinstance(value, list):
        warn(f"{key} is not a list, ignoring it")
        return []
    return value


def run() -> None:
    payload_path = os.environ.get("PAYLOAD_FILE", "")
    if not payload_path:
        fail_soft("PAYLOAD_FILE is not set")
    collector = read_json(os.environ.get("PRS_FILE", ""), "PRS_FILE")
    if not isinstance(collector, dict):
        fail_soft("PRS_FILE is not a JSON object")
    for key in ("repository", "version", "previous_tag", "server_url"):
        if not isinstance(collector.get(key), str) or not collector[key]:
            fail_soft(f"PRS_FILE has no {key}")

    try:
        result = json.loads(os.environ.get("AI_RESULT", ""))
    except json.JSONDecodeError as e:
        fail_soft(f"AI_RESULT is not valid JSON: {e.msg}")
    if not isinstance(result, dict):
        fail_soft("AI_RESULT is not a JSON object")

    prs = index_prs(collector)
    workspace = os.environ.get("LINEAR_WORKSPACE", "").strip() or DEFAULT_WORKSPACE
    groups: list[tuple[str, list[str]]] = []
    count = dropped = 0
    for key, title in GROUPS:
        bullets, lost = render_items(group_items(result, key), prs, workspace)
        count += len(bullets)
        dropped += lost
        if bullets:
            groups.append((title, bullets))
    emit_kv("item_count", str(count))
    emit_kv("dropped_refs", str(dropped))
    if not groups:
        fail_soft("no items left to render")

    headline = result.get("headline")
    payload = build_payload(
        os.environ.get("CHANNEL_ID", ""),
        os.environ.get("THREAD_TS", ""),
        collector,
        escape(headline.strip()) if isinstance(headline, str) else "",
        groups,
    )
    try:
        with open(payload_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
    except OSError as e:
        fail_soft(f"payload file could not be written: {e}")
    emit_kv("rendered", "true")
    print(f"release-summary: rendered {count} items in "
          f"{len(payload['blocks'])} blocks, {dropped} refs dropped")


def main() -> None:
    try:
        run()
    except Exception as e:  # advisory-only: nothing may fail the release
        fail_soft(f"unexpected {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
