import base64
import json

from claude_swap.codex import CodexAccountSwitcher
from claude_swap.island_import import import_codex_accounts


def auth(workspace):
    payload = base64.urlsafe_b64encode(json.dumps({"email": "a@example.com"}).encode()).decode().rstrip("=")
    return {"auth_mode": "chatgpt", "tokens": {"id_token": f"x.{payload}.x", "account_id": workspace,
                                              "access_token": "test-only", "refresh_token": "test-only"}}


def test_import_preview_then_idempotent_save_preserves_live_login_and_existing_tokens(tmp_path, monkeypatch):
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "live"))
    switcher = CodexAccountSwitcher()
    switcher.backup_dir = tmp_path / "store"
    switcher.provider_dir = switcher.backup_dir / "codex"
    switcher.credentials_dir = switcher.provider_dir / "credentials"
    switcher.sequence_file = switcher.provider_dir / "sequence.json"
    switcher.lock_file = switcher.backup_dir / ".lock"
    switcher.auth_file.parent.mkdir()
    switcher.auth_file.write_text(json.dumps(auth("personal")))
    live_bytes = switcher.auth_file.read_bytes()
    managed = tmp_path / "managed"
    managed.mkdir()
    (managed / "auth.json").write_text(json.dumps(auth("team")))
    registry = tmp_path / "registry.json"
    registry.write_text(json.dumps({"accounts": [{"managedHomePath": str(managed), "email": "a@example.com",
        "workspaceAccountID": "team", "workspaceLabel": "Team"}]}))
    preview = import_codex_accounts(switcher, registry)
    assert len(preview["accounts"]) == 2
    assert not switcher.sequence_file.exists()
    assert "test-only" not in json.dumps(preview)
    import_codex_accounts(switcher, registry, apply=True)
    saved = switcher._read_sequence()
    assert len(saved["accounts"]) == 2
    assert saved["activeAccountNumber"] == 1
    existing = switcher._credential_path("2").read_bytes()
    (managed / "auth.json").write_text(json.dumps({**auth("team"), "new": "not imported"}))
    again = import_codex_accounts(switcher, registry, apply=True)
    assert all(row["action"] == "keep existing" for row in again["accounts"])
    assert switcher._credential_path("2").read_bytes() == existing
    assert switcher.auth_file.read_bytes() == live_bytes


def test_identity_mismatch_refuses_import_before_writing(tmp_path, monkeypatch):
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "missing"))
    switcher = CodexAccountSwitcher()
    managed = tmp_path / "managed"
    managed.mkdir()
    (managed / "auth.json").write_text(json.dumps(auth("wrong-workspace")))
    registry = tmp_path / "registry.json"
    registry.write_text(json.dumps({"accounts": [{"managedHomePath": str(managed),
        "workspaceAccountID": "expected-workspace"}]}))
    import pytest
    with pytest.raises(ValueError, match="workspace"):
        import_codex_accounts(switcher, registry, apply=True)
    assert not switcher.sequence_file.exists()
