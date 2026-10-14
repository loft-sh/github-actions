"""render.py: AI result plus collector PRs to a Slack chat.postMessage payload.

The action is advisory-only, so the contract tested here is twofold: the
payload only ever carries citations the collector vouched for, and no input
(bad JSON, missing file, a bug) ends the step with a non-zero exit.
"""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "render.py"
BASE = "https://github.com/loft-sh/loft-enterprise"
COMPARE_URL = f"{BASE}/compare/v5.0.0-alpha.1...v5.0.0-alpha.2"


@pytest.fixture
def render(monkeypatch, tmp_path):
    out = tmp_path / "github_output"
    out.write_text("")
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    monkeypatch.delenv("LINEAR_WORKSPACE", raising=False)
    spec = importlib.util.spec_from_file_location("release_summary_render", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.github_output = out
    return mod


def pr(number, linear=()):
    return {"number": number, "url": f"{BASE}/pull/{number}",
            "title": f"PR {number}", "linear": list(linear)}


def collector(*prs):
    return {
        "repository": "loft-sh/loft-enterprise",
        "version": "v5.0.0-alpha.2",
        "previous_tag": "v5.0.0-alpha.1",
        "server_url": "https://github.com",
        "pull_requests": list(prs),
    }


def index(*prs):
    return {p["number"]: p for p in prs}


def item(summary, *prs):
    return {"summary": summary, "prs": list(prs)}


def set_env(monkeypatch, tmp_path, ai, prs_data):
    """Point every input env var at fresh files; returns the payload path."""
    prs_file = tmp_path / "prs.json"
    prs_file.write_text(json.dumps(prs_data))
    payload = tmp_path / "payload.json"
    monkeypatch.setenv("AI_RESULT", ai if isinstance(ai, str) else json.dumps(ai))
    monkeypatch.setenv("PRS_FILE", str(prs_file))
    monkeypatch.setenv("CHANNEL_ID", "C0123")
    monkeypatch.setenv("THREAD_TS", "1700000000.000100")
    monkeypatch.setenv("PRODUCT", "vCluster Platform")
    monkeypatch.setenv("PAYLOAD_FILE", str(payload))
    return payload


def output_lines(render):
    return render.github_output.read_text().splitlines()


def section_texts(blocks):
    return [b["text"]["text"] for b in blocks if b["type"] == "section"]


# render_items: citations


def test_bullet_has_pr_and_linear_links(render):
    prs = index(pr(1, ["ENGCP-10"]))
    bullets, dropped = render.render_items([item("Faster sync", 1)], prs, "loft")
    assert bullets == [
        f"• Faster sync (<{BASE}/pull/1|#1>, "
        "<https://linear.app/loft/issue/ENGCP-10|ENGCP-10>)"
    ]
    assert dropped == 0


def test_unknown_pr_is_dropped_and_counted(render):
    bullets, dropped = render.render_items(
        [item("Faster sync", 1, 999)], index(pr(1)), "loft")
    assert bullets == [f"• Faster sync (<{BASE}/pull/1|#1>)"]
    assert dropped == 1


def test_item_with_only_unknown_prs_is_removed(render):
    bullets, dropped = render.render_items(
        [item("Ghost", 998, 999), item("Real", 1)], index(pr(1)), "loft")
    assert len(bullets) == 1 and "Real" in bullets[0]
    assert dropped == 2


def test_non_int_pr_entries_are_dropped_and_counted(render):
    refs = [1, "2", 2.5, True, None, [3]]
    bullets, dropped = render.render_items(
        [{"summary": "Mixed", "prs": refs}], index(pr(1), pr(2)), "loft")
    assert bullets == [f"• Mixed (<{BASE}/pull/1|#1>)"]
    assert dropped == 5


def test_pr_numbers_are_deduped_within_an_item(render):
    bullets, dropped = render.render_items(
        [item("Twice", 1, 1, 2, 2, 999, 999)], index(pr(1), pr(2)), "loft")
    assert bullets == [f"• Twice (<{BASE}/pull/1|#1>, <{BASE}/pull/2|#2>)"]
    assert dropped == 1


def test_linear_ids_come_from_prs_file_not_ai_text(render):
    bullets, _ = render.render_items(
        [item("Fix ENG-999 and ENG-1000 leak", 1)],
        index(pr(1, ["ENGCP-1"])), "loft")
    assert "linear.app/loft/issue/ENGCP-1|ENGCP-1" in bullets[0]
    assert "linear.app/loft/issue/ENG-999" not in bullets[0]
    assert "linear.app/loft/issue/ENG-1000" not in bullets[0]
    # The id survives only as plain AI text.
    assert "Fix ENG-999 and ENG-1000 leak" in bullets[0]


def test_linear_ids_only_from_kept_prs_deduped_in_first_seen_order(render):
    prs = index(pr(1, ["B-2", "A-1"]), pr(2, ["A-1", "C-3"]))
    bullets, _ = render.render_items([item("Mix", 2, 1, 999)], prs, "loft")
    assert re.findall(r"issue/([A-Z]-[0-9])\|", bullets[0]) == ["A-1", "C-3", "B-2"]


def test_linear_ids_of_unknown_prs_are_not_used(render):
    prs = index(pr(1, ["A-1"]))
    bullets, _ = render.render_items([item("x", 1, 999)], prs, "loft")
    assert bullets[0].count("linear.app") == 1


def test_malformed_linear_ids_are_ignored(render):
    prs = index(pr(1, ["A-1", "bad id", "x|y>", 5, None]))
    bullets, _ = render.render_items([item("x", 1)], prs, "loft")
    assert bullets[0].count("linear.app") == 1


def test_workspace_slug_is_used_in_links(render):
    bullets, _ = render.render_items(
        [item("x", 1)], index(pr(1, ["A-1"])), "acme")
    assert "https://linear.app/acme/issue/A-1|A-1" in bullets[0]


def test_malformed_items_are_skipped(render, capsys):
    items = ["text", {"prs": [1]}, {"summary": "  ", "prs": [1]},
             {"summary": "ok", "prs": "1"}, item("good", 1)]
    bullets, dropped = render.render_items(items, index(pr(1)), "loft")
    assert len(bullets) == 1 and "good" in bullets[0]
    assert dropped == 0
    assert capsys.readouterr().out.count("::warning::release-summary:") == 4


def test_summary_whitespace_collapses_to_one_line(render):
    bullets, _ = render.render_items(
        [item("two\nlines   here", 1)], index(pr(1)), "loft")
    assert bullets[0].startswith("• two lines here (")
    assert "\n" not in bullets[0]


# escaping


def test_escapes_control_characters_but_not_generated_links(render):
    bullets, _ = render.render_items(
        [item("a & b <c> d", 1)], index(pr(1)), "loft")
    assert bullets[0].startswith("• a &amp; b &lt;c&gt; d (")
    assert f"<{BASE}/pull/1|#1>" in bullets[0]


def test_headline_is_escaped(render, monkeypatch, tmp_path):
    ai = {"headline": "Fast & <b>bold</b>", "features": [item("x", 1)]}
    payload = set_env(monkeypatch, tmp_path, ai, collector(pr(1)))
    render.main()
    first = json.loads(payload.read_text())["blocks"][0]["text"]["text"]
    assert first == ("*What changed in v5.0.0-alpha.2 since v5.0.0-alpha.1*\n"
                     "Fast &amp; &lt;b&gt;bold&lt;/b&gt;")


# blocks and payload


def test_happy_path_all_four_groups(render, monkeypatch, tmp_path):
    ai = {
        "headline": "A big one.",
        "features": [item("Feature one", 1), item("Feature two", 2)],
        "bug_fixes": [item("Fix one", 3)],
        "tech_debt": [item("Debt one", 4)],
        "tests": [item("Test one", 5)],
    }
    prs = collector(pr(1, ["ENGCP-1"]), pr(2), pr(3), pr(4), pr(5))
    payload = set_env(monkeypatch, tmp_path, ai, prs)
    render.main()

    data = json.loads(payload.read_text())
    assert data["channel"] == "C0123"
    assert data["thread_ts"] == "1700000000.000100"
    assert data["text"] == "What changed in v5.0.0-alpha.2 since v5.0.0-alpha.1"
    assert data["unfurl_links"] is False and data["unfurl_media"] is False

    blocks = data["blocks"]
    assert [b["type"] for b in blocks] == ["section"] * 5 + ["context"]
    texts = section_texts(blocks)
    assert texts[0] == ("*What changed in v5.0.0-alpha.2 since v5.0.0-alpha.1*\n"
                        "A big one.")
    assert texts[1] == (
        "*Features*\n"
        f"• Feature one (<{BASE}/pull/1|#1>, "
        "<https://linear.app/loft/issue/ENGCP-1|ENGCP-1>)\n"
        f"• Feature two (<{BASE}/pull/2|#2>)")
    assert texts[2] == f"*Bug fixes*\n• Fix one (<{BASE}/pull/3|#3>)"
    assert texts[3] == f"*Tech debt*\n• Debt one (<{BASE}/pull/4|#4>)"
    assert texts[4] == f"*Tests*\n• Test one (<{BASE}/pull/5|#5>)"
    assert blocks[-1] == {"type": "context", "elements": [{
        "type": "mrkdwn",
        "text": f"<{COMPARE_URL}|Compare v5.0.0-alpha.1...v5.0.0-alpha.2>"
                " · AI-generated from PR descriptions, may contain mistakes",
    }]}


def test_group_order_follows_the_spec_not_the_json(render, monkeypatch, tmp_path):
    ai = {"tests": [item("t", 1)], "features": [item("f", 1)]}
    payload = set_env(monkeypatch, tmp_path, ai, collector(pr(1)))
    render.main()
    texts = section_texts(json.loads(payload.read_text())["blocks"])
    assert [t.split("\n")[0] for t in texts[1:]] == ["*Features*", "*Tests*"]


def test_empty_group_is_omitted(render, monkeypatch, tmp_path):
    ai = {"features": [item("f", 1)], "bug_fixes": [], "tech_debt": [item("d", 999)]}
    payload = set_env(monkeypatch, tmp_path, ai, collector(pr(1)))
    render.main()
    texts = "\n".join(section_texts(json.loads(payload.read_text())["blocks"]))
    assert "*Features*" in texts
    assert "Bug fixes" not in texts
    assert "Tech debt" not in texts
    assert "*Tests*" not in texts


def test_missing_headline_leaves_only_the_title_line(render):
    blocks = render.build_blocks("T", "", [("Features", ["• x"])], "foot")
    assert blocks[0]["text"]["text"] == "*T*"


def test_non_list_group_warns_and_counts_as_empty(render, capsys):
    assert render.group_items({"features": "oops"}, "features") == []
    assert "features is not a list" in capsys.readouterr().out
    assert render.group_items({}, "features") == []


def test_long_group_splits_into_sections_of_at_most_3000(render):
    bullets = ["• " + "a" * 498 for _ in range(20)]
    chunks = render.pack_group("Features", bullets)
    texts = [t for t, _ in chunks]
    assert len(texts) > 1
    assert all(len(t) <= 3000 for t in texts)
    assert texts[0].startswith("*Features*\n")
    assert not any(t.startswith("*") for t in texts[1:])
    assert sum(n for _, n in chunks) == 20
    rebuilt = [line for t in texts for line in t.split("\n") if line.startswith("•")]
    assert rebuilt == bullets


def test_oversized_bullet_is_truncated_with_ellipsis(render):
    bullet = "• " + "x" * 5000 + f" (<{BASE}/pull/1|#1>)"
    [(text, count)] = render.pack_group("Features", [bullet])
    assert count == 1
    assert len(text) <= 3000
    assert text.startswith("*Features*\n• xxx")
    assert text.endswith("x…")


def test_truncate_never_leaves_half_a_link_or_entity(render):
    assert render.truncate("aaaa <https://e.com/x|#1>", 12) == "aaaa…"
    assert render.truncate("a &amp; b", 5) == "a…"
    assert render.truncate("short", 10) == "short"


def test_block_cap_adds_more_items_line_and_footer_last(render):
    bullets = ["• " + "x" * 2900 for _ in range(60)]
    blocks = render.build_blocks("T", "h", [("Features", bullets)], "foot")
    assert len(blocks) == 50
    assert blocks[0]["text"]["text"].startswith("*T*")
    assert blocks[-1] == {"type": "context",
                          "elements": [{"type": "mrkdwn", "text": "foot"}]}
    # 1 header + 47 bullet blocks + overflow line + footer
    assert blocks[-2]["text"]["text"] == "…and 13 more items, see the compare link."


def test_exactly_full_message_needs_no_more_items_line(render):
    bullets = ["• " + "x" * 2900 for _ in range(48)]
    blocks = render.build_blocks("T", "h", [("Features", bullets)], "foot")
    assert len(blocks) == 50
    assert not any("more items" in t for t in section_texts(blocks))
    assert blocks[-1]["type"] == "context"


def test_block_cap_counts_items_inside_hidden_blocks(render):
    big = ["• " + "x" * 2900 for _ in range(48)]
    small = [f"• s{i}" for i in range(10)]
    blocks = render.build_blocks(
        "T", "h", [("Features", big), ("Tests", small)], "foot")
    assert len(blocks) == 50
    # 49 chunks, 47 kept: the last big bullet and the Tests chunk (10) are hidden.
    assert blocks[-2]["text"]["text"] == "…and 11 more items, see the compare link."
    assert "*Tests*" not in "\n".join(section_texts(blocks))


# main: outputs and soft failure


def test_github_output_lines_are_written(render, monkeypatch, tmp_path):
    ai = {"features": [item("a", 1, 999), item("b", 998)], "tests": [item("c", 1)]}
    set_env(monkeypatch, tmp_path, ai, collector(pr(1)))
    render.main()
    assert output_lines(render) == [
        "item_count=2", "dropped_refs=2", "rendered=true"]


def test_main_runs_without_github_output(render, monkeypatch, tmp_path):
    monkeypatch.delenv("GITHUB_OUTPUT")
    payload = set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]},
                      collector(pr(1)))
    render.main()
    assert json.loads(payload.read_text())["channel"] == "C0123"


def test_linear_workspace_env_is_honoured(render, monkeypatch, tmp_path):
    monkeypatch.setenv("LINEAR_WORKSPACE", "acme")
    payload = set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]},
                      collector(pr(1, ["A-1"])))
    render.main()
    assert "linear.app/acme/issue/A-1" in payload.read_text()


def test_payload_is_written_without_ascii_escaping(render, monkeypatch, tmp_path):
    payload = set_env(monkeypatch, tmp_path, {"features": [item("café", 1)]},
                      collector(pr(1)))
    render.main()
    raw = payload.read_text(encoding="utf-8")
    assert "café" in raw and "\\u" not in raw


def assert_soft_failure(render, capsys):
    with pytest.raises(SystemExit) as exc:
        render.main()
    assert exc.value.code == 0
    assert "rendered=false" in output_lines(render)
    assert "rendered=true" not in output_lines(render)
    return capsys.readouterr().out


def test_invalid_json_fails_soft(render, monkeypatch, tmp_path, capsys):
    payload = set_env(monkeypatch, tmp_path, "{not json", collector(pr(1)))
    out = assert_soft_failure(render, capsys)
    assert out.startswith("::warning::release-summary: AI_RESULT is not valid JSON")
    assert not payload.exists()


def test_empty_ai_result_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, "", collector(pr(1)))
    assert_soft_failure(render, capsys)


def test_non_object_ai_result_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, "[1, 2]", collector(pr(1)))
    out = assert_soft_failure(render, capsys)
    assert "not a JSON object" in out


def test_all_groups_empty_fails_soft(render, monkeypatch, tmp_path, capsys):
    ai = {"features": [item("ghost", 999)], "tests": []}
    payload = set_env(monkeypatch, tmp_path, ai, collector(pr(1)))
    assert_soft_failure(render, capsys)
    assert not payload.exists()
    assert output_lines(render) == [
        "item_count=0", "dropped_refs=1", "rendered=false"]


def test_missing_prs_file_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]}, collector(pr(1)))
    monkeypatch.setenv("PRS_FILE", str(tmp_path / "absent.json"))
    out = assert_soft_failure(render, capsys)
    assert "PRS_FILE could not be read" in out


def test_collector_without_version_fails_soft(render, monkeypatch, tmp_path, capsys):
    data = collector(pr(1))
    del data["version"]
    set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]}, data)
    out = assert_soft_failure(render, capsys)
    assert "PRS_FILE has no version" in out


def test_missing_payload_file_env_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]}, collector(pr(1)))
    monkeypatch.delenv("PAYLOAD_FILE")
    assert_soft_failure(render, capsys)


def test_unwritable_payload_file_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]}, collector(pr(1)))
    monkeypatch.setenv("PAYLOAD_FILE", str(tmp_path / "no-dir" / "payload.json"))
    out = assert_soft_failure(render, capsys)
    assert "payload file could not be written" in out


def test_unexpected_error_fails_soft(render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]}, collector(pr(1)))

    def boom(*args, **kwargs):
        raise ValueError("boom\n::error::injected")

    monkeypatch.setattr(render, "build_payload", boom)
    out = assert_soft_failure(render, capsys)
    assert out == "::warning::release-summary: unexpected ValueError: boom ::error::injected\n"


def test_unwritable_github_output_does_not_break_the_step(
        render, monkeypatch, tmp_path, capsys):
    set_env(monkeypatch, tmp_path, "{not json", collector(pr(1)))
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path))  # a directory
    with pytest.raises(SystemExit) as exc:
        render.main()
    assert exc.value.code == 0
    assert "could not write output rendered" in capsys.readouterr().out


def test_script_exits_zero_on_invalid_json(render, monkeypatch, tmp_path):
    set_env(monkeypatch, tmp_path, "{not json", collector(pr(1)))
    proc = subprocess.run([sys.executable, "-I", str(SRC)],
                          capture_output=True, text=True)
    assert proc.returncode == 0
    assert proc.stdout.startswith("::warning::release-summary:")
    assert "rendered=false" in output_lines(render)


def test_script_exits_zero_and_writes_payload_on_success(
        render, monkeypatch, tmp_path):
    payload = set_env(monkeypatch, tmp_path, {"features": [item("a", 1)]},
                      collector(pr(1)))
    proc = subprocess.run([sys.executable, "-I", str(SRC)],
                          capture_output=True, text=True)
    assert proc.returncode == 0
    assert json.loads(payload.read_text())["blocks"][-1]["type"] == "context"
    assert "rendered=true" in output_lines(render)
