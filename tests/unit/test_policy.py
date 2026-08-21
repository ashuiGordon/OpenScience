from __future__ import annotations

from pathlib import Path

import pytest

from openscience_agent.domain import (
    CapabilityDescriptor,
    CapabilityKind,
    PolicyOutcome,
    RiskLevel,
)
from openscience_agent.errors import ApprovalRequiredError, PathBoundaryError, PolicyDeniedError
from openscience_agent.policy import (
    PolicyEngine,
    is_path_within,
    redact_secrets,
    redact_text,
    resolve_approved_path,
)


def _descriptor(risk: RiskLevel, *permissions: str) -> CapabilityDescriptor:
    return CapabilityDescriptor(
        name=f"test.{risk.value}",
        version="1.0.0",
        kind=CapabilityKind.SOURCE,
        risk=risk,
        permissions=permissions,
    )


def test_network_is_denied_by_default_and_requires_https_when_enabled() -> None:
    descriptor = _descriptor(RiskLevel.NETWORK_READ, "network.read")

    denied = PolicyEngine().evaluate(descriptor, "search", target="https://api.example.test")
    insecure = PolicyEngine(allow_network=True).evaluate(
        descriptor, "search", target="http://api.example.test"
    )
    allowed = PolicyEngine(allow_network=True).evaluate(
        descriptor, "search", target="https://api.example.test/works"
    )

    assert denied.outcome is PolicyOutcome.DENY
    assert "opt-in" in denied.reason
    assert insecure.outcome is PolicyOutcome.DENY
    assert allowed.outcome is PolicyOutcome.ALLOW


def test_dangerous_capabilities_are_never_silently_allowed() -> None:
    engine = PolicyEngine()

    execute = engine.evaluate(
        _descriptor(RiskLevel.EXECUTE, "process.execute"), "run", target="python"
    )
    consequential = engine.evaluate(
        _descriptor(RiskLevel.CONSEQUENTIAL, "external.publish"),
        "publish",
        target="journal",
    )

    assert execute.outcome is PolicyOutcome.DENY
    assert consequential.outcome is PolicyOutcome.APPROVAL_REQUIRED
    with pytest.raises(PolicyDeniedError):
        engine.require_allowed(
            _descriptor(RiskLevel.EXECUTE, "process.execute"), "run", target="python"
        )
    with pytest.raises(ApprovalRequiredError):
        engine.require_allowed(
            _descriptor(RiskLevel.CONSEQUENTIAL, "external.publish"),
            "publish",
            target="journal",
        )


def test_declared_permission_is_required_before_policy_can_allow() -> None:
    descriptor = _descriptor(RiskLevel.NETWORK_READ)

    decision = PolicyEngine(allow_network=True).evaluate(
        descriptor, "search", target="https://api.example.test"
    )

    assert decision.outcome is PolicyOutcome.DENY
    assert "network.read" in decision.reason


def test_local_read_stays_beneath_resolved_approved_roots(tmp_path: Path) -> None:
    root = tmp_path / "corpus"
    root.mkdir()
    accepted = root / "paper.md"
    accepted.write_text("evidence", encoding="utf-8")
    descriptor = _descriptor(RiskLevel.LOCAL_READ, "filesystem.read")
    engine = PolicyEngine(approved_local_roots=(root,))

    decision = engine.evaluate(descriptor, "read", target=str(accepted))

    assert decision.outcome is PolicyOutcome.ALLOW
    assert resolve_approved_path(accepted, (root,)) == accepted.resolve()
    assert is_path_within(accepted, root)
    with pytest.raises(PathBoundaryError):
        resolve_approved_path(tmp_path / "outside.md", (root,))


def test_symlink_escape_is_rejected(tmp_path: Path) -> None:
    root = tmp_path / "corpus"
    root.mkdir()
    outside = tmp_path / "private.txt"
    outside.write_text("private", encoding="utf-8")
    link = root / "link.txt"
    link.symlink_to(outside)

    with pytest.raises(PathBoundaryError, match="approved"):
        resolve_approved_path(link, (root,))


def test_redaction_covers_nested_config_headers_urls_and_token_shapes() -> None:
    value = {
        "api_key": "sk-abcdefghijklmnopqrstuvwxyz123456",
        "nested": {
            "Authorization": "Bearer secret-token-value",
            "url": "https://user:pass@example.test/path?token=visible-secret",
        },
        "safe": ["ordinary text", "github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"],
    }

    redacted = redact_secrets(value)
    rendered = str(redacted)

    assert "abcdefghijklmnopqrstuvwxyz" not in rendered
    assert "secret-token-value" not in rendered
    assert "user:pass" not in rendered
    assert "visible-secret" not in rendered
    assert "github_pat_" not in rendered
    assert "ordinary text" in rendered
    assert redact_text("password=hunter2") == "password=[REDACTED]"
