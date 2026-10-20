import importlib.util
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace

import pytest

SOURCE = Path(__file__).resolve().parents[1] / "src/check.py"
spec = importlib.util.spec_from_file_location("check_pins", SOURCE)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
SHA = "a" * 40


@pytest.fixture
def repository(tmp_path):
    (tmp_path / ".github/workflows").mkdir(parents=True)
    return tmp_path


def workflow(repository, reference, reusable=False, suffix=""):
    job = (f"    uses: {reference}{suffix}\n" if reusable else
           f"    runs-on: ubuntu-latest\n    steps:\n      - uses: {reference}{suffix}\n")
    (repository / ".github/workflows/check.yaml").write_text(
        "name: Check\non: push\njobs:\n  check:\n" + job)


@pytest.fixture
def zizmor():
    binary = shutil.which("zizmor")
    if not binary:
        pytest.fail("Integration tests require zizmor 1.30.1 on PATH")
    assert subprocess.check_output([binary, "--version"], text=True).strip() == "zizmor 1.30.1"
    return binary


@pytest.mark.parametrize("reference,reusable,expected", [
    ("actions/checkout@v4", False, 1),
    ("actions/checkout@abcdef0", False, 1),
    (f"actions/checkout@{'a' * 39}", False, 1),
    (f"actions/checkout@{'a' * 41}", False, 1),
    (f"actions/checkout@{SHA}", False, 0),
    ("loft-sh/github-actions/.github/actions/example@example/v1", False, 0),
    ("loft-sh/github-actions/.github/workflows/example.yaml@main", True, 0),
    ("vendor/example/.github/workflows/example.yaml@v1", True, 1),
    (f"vendor/example/.github/workflows/example.yaml@{SHA}", True, 0),
    ("loft-sh-spoof/example@v1", False, 1),
    ("evil/loft-sh/example@v1", False, 1),
    ("./.github/actions/example", False, 0),
])
def test_policy(repository, zizmor, reference, reusable, expected):
    workflow(repository, reference, reusable)
    assert check.check(zizmor, repository) == expected


@pytest.mark.parametrize("reference,expected", [
    ("vendor/example@v1", 1), (f"vendor/example@{SHA}", 0),
    ("loft-sh/example@example/v1", 0),
])
def test_composite(repository, zizmor, reference, expected):
    action = repository / ".github/actions/example"
    action.mkdir(parents=True)
    (action / "action.yml").write_text(
        "name: Example\ndescription: Example\nruns:\n  using: composite\n  steps:\n"
        f"    - uses: {reference}\n")
    assert check.check(zizmor, repository) == expected


def test_ignores_and_caller_config_cannot_bypass(repository, zizmor, monkeypatch):
    workflow(repository, "vendor/example@v1", suffix=" # zizmor: ignore[unpinned-uses]")
    config = repository / ".github/zizmor.yml"
    config.write_text("rules:\n  unpinned-uses:\n    disable: true\n")
    monkeypatch.setenv("ZIZMOR_CONFIG", str(config))
    assert check.check(zizmor, repository) == 1


def test_ignored_file_is_collected(repository, zizmor):
    workflow(repository, "vendor/example@v1")
    (repository / ".gitignore").write_text(".github/workflows/check.yaml\n")
    assert check.check(zizmor, repository) == 1


@pytest.mark.parametrize("filename", ["dependabot.yml", "dependabot.yaml"])
@pytest.mark.parametrize("reference,expected", [("vendor/example@v1", 1),
                                                 (f"vendor/example@{SHA}", 0)])
def test_workflow_named_dependabot_is_audited(repository, zizmor, filename, reference, expected):
    workflow(repository, reference)
    source = repository / ".github/workflows/check.yaml"
    source.rename(source.with_name(filename))
    assert check.check(zizmor, repository) == expected


def test_docs_and_script_text_are_not_references(repository, zizmor):
    workflow(repository, f"actions/checkout@{SHA}")
    (repository / ".github/README.md").write_text("uses: vendor/example@v1")
    (repository / ".github/example.sh").write_text("uses: vendor/example@v1")
    assert check.check(zizmor, repository) == 0


def test_only_pinning_findings_block(repository, zizmor):
    workflow(repository, f"actions/checkout@{SHA}")
    # checkout's persisted credentials produces an unrelated security finding.
    assert check.check(zizmor, repository) == 0


def test_malformed_workflow_fails_closed(repository, zizmor):
    (repository / ".github/workflows/check.yaml").write_text("jobs: [broken")
    with pytest.raises(check.CheckError, match="zizmor failed"):
        check.check(zizmor, repository)


def test_invalid_workflow_schema_fails_closed(repository, zizmor):
    (repository / ".github/workflows/check.yaml").write_text("name: Invalid\njobs: 1\n")
    with pytest.raises(check.CheckError, match="zizmor failed"):
        check.check(zizmor, repository)


@pytest.mark.parametrize("output", ["", "not json", "{}", "[null]", '[{"ident":1}]',
                                   '[{}]', '[{"ident":"unexpected"}]'])
def test_invalid_scanner_output_fails_closed(output):
    with pytest.raises(check.CheckError):
        check.findings(output)


def test_scanner_failure_fails_even_with_valid_json(repository, monkeypatch):
    monkeypatch.setattr(check, "run", lambda *args, **kwargs:
                        SimpleNamespace(returncode=1, stdout="[]", stderr="failed"))
    with pytest.raises(check.CheckError, match="zizmor failed"):
        check.check("scanner", repository)


def test_command_enforces_policy(repository, monkeypatch):
    def fake_run(command, **kwargs):
        assert "--no-ignores" in command
        assert "--strict-collection" in command
        assert "--offline" in command
        assert "--no-exit-codes" in command
        assert command[command.index("--config") + 1] == str(check.POLICY)
        assert "ZIZMOR_CONFIG" not in kwargs["env"]
        return SimpleNamespace(returncode=0, stdout="[]", stderr="")
    monkeypatch.setenv("ZIZMOR_CONFIG", "untrusted")
    monkeypatch.setattr(check, "run", fake_run)
    assert check.check("scanner", repository) == 0


def test_existing_version_is_reused(tmp_path, monkeypatch):
    monkeypatch.setattr(check.shutil, "which", lambda _: "/trusted/zizmor")
    monkeypatch.setattr(check, "run", lambda *_: SimpleNamespace(
        returncode=0, stdout="zizmor 1.30.1\n"))
    assert check.scanner(tmp_path) == "/trusted/zizmor"


def test_install_is_pinned_and_isolated(tmp_path, monkeypatch):
    monkeypatch.setattr(check.shutil, "which", lambda _: None)
    monkeypatch.setattr(check.venv, "create", lambda *args, **kwargs: None)
    commands = []
    def fake_run(command):
        commands.append(command)
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(check, "run", fake_run)
    assert check.scanner(tmp_path) == str(tmp_path / "venv/bin/zizmor")
    assert "-I" in commands[0]
    assert "--isolated" in commands[0]
    assert "--no-deps" in commands[0]
    assert "zizmor==1.30.1" in commands[0]


def test_install_failure_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(check.shutil, "which", lambda _: None)
    monkeypatch.setattr(check.venv, "create", lambda *args, **kwargs: None)
    monkeypatch.setattr(check, "run", lambda *_: SimpleNamespace(returncode=1, stderr="offline"))
    with pytest.raises(check.CheckError, match="Could not install"):
        check.scanner(tmp_path)
