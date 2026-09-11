"""CodeIsland's account core, shared by the terminal and bundled macOS app.

The app invokes its own bundled executable. Provider operations are Python
function calls into this source tree; no installed cswap/CodexBar is required.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from claude_swap.codex import CodexAccountSwitcher
from claude_swap.models import AccountSnapshot
from claude_swap.switcher import ClaudeAccountSwitcher


def timestamp(value: float | None) -> str | None:
    if value is None:
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec="seconds")


def account_payload(provider: str, account: AccountSnapshot) -> dict:
    entry = account.usage
    # Never relabel a different credential's old measurements as current.
    usage = entry.last_good if not entry.sentinel else None
    windows = []

    def append_window(key: str, label: str, raw: object) -> None:
        if not isinstance(raw, dict):
            return
        used = raw.get("pct")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
            return
        windows.append({
            "id": key, "label": label, "usedPercent": used,
            "remainingPercent": max(0, min(100, 100 - used)),
            "resetsAt": raw.get("resets_at"),
        })

    if usage:
        for key, label in (("five_hour", "5h"), ("seven_day", "Weekly"), ("weekly", "Weekly")):
            append_window(key, label, usage.get(key))
        for i, raw in enumerate(usage.get("scoped") or []):
            append_window(f"scoped-{i}", f"{raw.get('name', 'Model')} weekly", raw)
        for i, raw in enumerate(usage.get("additional") or []):
            append_window(f"additional-{i}", raw.get("name", "Model"), raw)

    resets = (usage or {}).get("reset_credits")
    return {
        "id": f"{provider}:{account.number}:{account.email}:{account.org_uuid}",
        "provider": provider, "number": account.number,
        "email": account.email, "organization": account.org_name,
        "workspaceId": account.org_uuid, "active": account.is_active,
        "status": entry.sentinel or ("stale" if entry.last_error and usage else "ok" if usage else "unavailable"),
        # The UI receives a bounded diagnostic, never raw provider bodies/tokens.
        "error": "Refresh failed; showing last successful measurement." if entry.last_error and usage else
                 "Could not fetch usage. Try signing in again." if entry.last_error else None,
        "fetchedAt": timestamp(entry.fetched_at), "windows": windows,
        "resetCredits": {"available": resets.get("available"), "earliestExpiresAt": resets.get("expires_at")}
                        if isinstance(resets, dict) else None,
    }


class AccountService:
    def __init__(self) -> None:
        self.providers = {
            "claude": ClaudeAccountSwitcher,
            "codex": CodexAccountSwitcher,
        }

    def snapshot(self, provider: str = "all") -> dict:
        accounts, errors = [], []
        for name, switcher in self.providers.items():
            if provider not in ("all", name):
                continue
            try:
                if isinstance(switcher, type):
                    switcher = switcher()
                    self.providers[name] = switcher
                result = switcher.accounts_snapshot()
                accounts.extend(account_payload(name, a) for a in result.accounts)
            except Exception as exc:
                errors.append({"provider": name, "message": f"Account query failed ({type(exc).__name__})."})
        return {"schemaVersion": 1, "updatedAt": timestamp(time.time()), "accounts": accounts, "errors": errors}


def local_reset(value: str | None) -> str:
    if not value:
        return "—"
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return moment.astimezone().strftime("%m-%d %H:%M %Z")
    except ValueError:
        return "—"


def render(snapshot: dict) -> str:
    lines = ["ACCOUNT / WORKSPACE · remaining quota · reset (local time)"]
    for account in snapshot["accounts"]:
        active = " *" if account["active"] else ""
        lines.append(f"\n{account['provider'].upper()} {account['number']}{active}  {account['email']}  [{account['organization'] or 'Personal'}]")
        for window in account["windows"]:
            lines.append(f"  {window['label']:<28} {window['remainingPercent']:5.1f}% left    {local_reset(window['resetsAt'])}")
        if account["resetCredits"] is not None:
            resets = account["resetCredits"]
            count = resets["available"] if resets["available"] is not None else "—"
            lines.append(f"  Reset credits: {count}    earliest expiry: {local_reset(resets['earliestExpiresAt'])}")
        if account["status"] != "ok":
            lines.append(f"  [{account['status']}] {account['error'] or ''}")
        lines.append(f"  Updated: {local_reset(account['fetchedAt'])}")
    if not snapshot["accounts"]:
        lines.append("No managed accounts. Use codeisland claude add / codeisland codex add.")
    for error in snapshot["errors"]:
        lines.append(f"{error['provider']}: {error['message']}")
    return "\n".join(lines)


def main() -> None:
    from claude_swap.cli import _use_native_tls
    _use_native_tls()
    argv = sys.argv[1:]
    if argv and argv[0] == "import-codexbar":
        from claude_swap.island_import import import_codex_accounts
        parser = argparse.ArgumentParser(prog="codeisland import-codexbar")
        parser.add_argument("--apply", action="store_true", help="Save the previewed accounts; existing slots are preserved")
        args = parser.parse_args(argv[1:])
        registry = Path.home() / "Library/Application Support/CodexBar/managed-codex-accounts.json"
        result = import_codex_accounts(CodexAccountSwitcher(), registry, apply=args.apply)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    # Retain the upstream account-management operations in this executable.
    if argv and argv[0] in ("claude", "codex"):
        from claude_swap.cli import main as accounts_main
        if any(arg in ("upgrade", "update", "--upgrade") for arg in argv[1:]):
            raise SystemExit("Update CodeIsland from its repository or app release.")
        sys.argv = ["codeisland", *(argv[1:] if argv[0] == "claude" else argv)]
        accounts_main()
        return
    parser = argparse.ArgumentParser(prog="codeisland", description="Claude + Codex multi-account quota")
    parser.add_argument("command", nargs="?", default="usage", choices=["usage", "accounts", "watch"])
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--provider", choices=["all", "claude", "codex"], default="all")
    parser.add_argument("--interval", type=int, default=60, help="Watch interval in seconds (minimum 60)")
    args = parser.parse_args(argv)
    if args.interval < 60:
        parser.error("--interval must be at least 60 seconds")
    service = AccountService()
    try:
        while True:
            snapshot = service.snapshot(args.provider)
            if args.command == "watch" and not args.json and sys.stdout.isatty():
                print("\033[2J\033[H", end="")
            print(json.dumps(snapshot, ensure_ascii=False, allow_nan=False) if args.json else render(snapshot), flush=True)
            if args.command != "watch":
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return


if __name__ == "__main__":
    main()
