"""One-time import of existing CodexBar logins into the embedded account store."""
from __future__ import annotations

import json
from pathlib import Path

from claude_swap.codex import CodexAccountSwitcher, _plan_type_from_auth, _timestamp
from claude_swap.locking import FileLock


def import_codex_accounts(switcher: CodexAccountSwitcher, registry: Path, *, apply: bool = False) -> dict:
    metadata = json.loads(registry.read_text()) if registry.exists() else {"accounts": []}
    sources = [(switcher.auth_file, "Current Codex login", None, None)]
    for row in metadata.get("accounts", []):
        location = row.get("managedHomePath")
        if not isinstance(location, str) or not Path(location).is_absolute():
            continue
        sources.append((Path(location) / "auth.json", row.get("workspaceLabel", ""),
                        row.get("email"), row.get("workspaceAccountID")))
    # Validate every source before writing any destination. Credentials are
    # read only here; output contains account metadata and never tokens/paths.
    validated = []
    for path, label, expected_email, expected_workspace in sources:
        auth = switcher._read_json(path)
        if not auth:
            continue
        email, workspace, mode = switcher._identity_from_auth(auth)
        if not email or not isinstance(auth.get("tokens"), dict):
            continue
        if expected_email and expected_email != email:
            raise ValueError("An imported login no longer matches its saved account identity.")
        if expected_workspace and expected_workspace != workspace:
            raise ValueError("An imported login no longer matches its saved workspace identity.")
        validated.append((auth, email, workspace, mode, label))

    def merge() -> dict:
        data = switcher._read_sequence()
        rows = []
        for auth, email, workspace, mode, label in validated:
            existing = switcher._match_account_number(data["accounts"], email, workspace)
            number = existing or switcher._next_number(data)
            rows.append({"number": number, "email": email, "workspace": label,
                         "action": "keep existing" if existing else "import"})
            if existing:
                continue
            data["accounts"][number] = {
                "email": email, "accountId": workspace, "authMode": mode,
                "planType": _plan_type_from_auth(auth), "workspaceLabel": label, "added": _timestamp(),
            }
            if apply:
                switcher._write_json(switcher._credential_path(number), auth)
        if apply:
            live = switcher._read_json(switcher.auth_file)
            active = switcher._current_account_for_auth(live, data) if live else None
            data["activeAccountNumber"] = int(active) if active else None
            switcher._write_sequence(data)
        return {"applied": apply, "accounts": rows}

    if apply:
        switcher._setup_directories()
        with FileLock(switcher.lock_file):
            return merge()
    return merge()
