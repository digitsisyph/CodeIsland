import json

from claude_swap.codex_usage import _convert_payload
from claude_swap.island import AccountService, account_payload, render
from claude_swap.models import AccountSnapshot, AccountsSnapshot
from claude_swap.usage_store import UsageEntry


def account(usage=None, **overrides):
    fields = dict(number="1", email="person@example.com", org_name="Personal", org_uuid="workspace-a",
                  is_active=False, kind="oauth", switchable=True,
                  usage=usage if isinstance(usage, UsageEntry) else UsageEntry(last_good=usage, fetched_at=1_800_000_000))
    fields.update(overrides)
    return AccountSnapshot(**fields)


def test_weekly_primary_and_extra_model_are_not_lost():
    raw = {"rate_limit": {"primary_window": {"used_percent": 52, "limit_window_seconds": 604800}},
           "additional_rate_limits": [None, {"limit_name": "Spark", "rate_limit": {
               "primary_window": {"used_percent": 2, "limit_window_seconds": 18000},
               "secondary_window": {"used_percent": 7, "limit_window_seconds": 604800}}}],
           "rate_limit_reset_credits": {"available_count": 3}}
    row = account_payload("codex", account(_convert_payload(raw)))
    assert [(w["label"], w["remainingPercent"]) for w in row["windows"]] == [
        ("Weekly", 48), ("Spark 5h", 98), ("Spark weekly", 93)]
    assert row["resetCredits"] == {"available": 3, "earliestExpiresAt": None}
    assert row["windows"][0]["resetsAt"] is None


def test_unknown_is_not_zero_and_invalid_percent_is_not_serialized():
    row = account_payload("codex", account({"five_hour": {"pct": float("nan")}}))
    assert row["windows"] == []
    assert row["resetCredits"] is None
    json.dumps(row, allow_nan=False)


def test_same_email_different_workspace_remains_distinct():
    first = account_payload("codex", account({}, org_uuid="workspace-a"))
    second = account_payload("codex", account({}, org_uuid="workspace-b"))
    assert first["id"] != second["id"]


def test_foreign_credentials_never_expose_previous_quota_as_current():
    row = account_payload("claude", account(usage=UsageEntry(sentinel="foreign credential",
        last_good={"five_hour": {"pct": 10}})))
    assert row["windows"] == []
    assert row["status"] == "foreign credential"


def test_stale_data_is_labeled_and_negative_remaining_is_clamped():
    row = account_payload("claude", account(usage=UsageEntry(last_error="http-429",
        last_good={"seven_day": {"pct": 110}})))
    assert row["windows"][0]["remainingPercent"] == 0
    assert row["status"] == "stale"
    assert "[stale]" in render({"accounts": [row], "errors": []})


def test_one_failed_provider_does_not_hide_the_other_or_expose_error_body():
    class Failing:
        def accounts_snapshot(self):
            raise ValueError("Bearer secret-token")
    class Working:
        def accounts_snapshot(self):
            return AccountsSnapshot(None, (account({"weekly": {"pct": 30}}),), 1_800_000_000)
    service = AccountService.__new__(AccountService)
    service.providers = {"claude": Failing(), "codex": Working()}
    result = service.snapshot()
    assert len(result["accounts"]) == 1
    assert result["errors"][0]["provider"] == "claude"
    assert "secret-token" not in json.dumps(result)
