from __future__ import annotations

from datetime import UTC, datetime, timedelta
from importlib import metadata
from typing import Any

import pytest

from openscience_agent.domain import (
    CapabilityDescriptor,
    CapabilityKind,
    Claim,
    ClaimKind,
    ResearchRequest,
    RiskLevel,
    SearchRequest,
    SourceCandidate,
    ToolContext,
)
from openscience_agent.errors import ProviderRegistrationError
from openscience_agent.ports import SourceProvider, SynthesisProvider
from openscience_agent.registry import ProviderRegistry


class FixtureSource:
    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="fixture.alpha",
            version="1.0.0",
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.LOCAL_READ,
            permissions=("filesystem.read",),
        )

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]:
        assert not context.is_cancelled()
        return [
            SourceCandidate(
                provider="fixture.alpha",
                provider_id="work-1",
                title=f"Result for {request.query}",
                response_hash="a" * 64,
            )
        ][: request.limit]


class ExtractiveSynthesizer:
    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="extractive",
            version="1.0.0",
            kind=CapabilityKind.SYNTHESIS,
            risk=RiskLevel.LOCAL_READ,
        )

    def synthesize(
        self,
        request: ResearchRequest,
        sources: list[Any],
        evidence: list[Any],
        context: ToolContext,
    ) -> list[Claim]:
        del request, sources, context
        return [
            Claim(
                text="A source-bound fact with traceable evidence.",
                kind=ClaimKind.SOURCED_FACT,
                evidence_ids=(str(evidence[0]["evidence_id"]),),
                created_by="extractive/1.0.0",
            )
        ]


def _context() -> ToolContext:
    def authorize(
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> Any:
        del descriptor, action, target, risk
        raise AssertionError("offline fixture must not request authorization itself")

    return ToolContext(
        deadline=datetime.now(UTC) + timedelta(seconds=10),
        remaining_network_requests=0,
        authorize=authorize,
        user_agent="openscience-agent/test",
        emit=lambda _event, _payload: None,
    )


def test_source_and_synthesizer_are_structural_protocols() -> None:
    assert isinstance(FixtureSource(), SourceProvider)
    assert isinstance(ExtractiveSynthesizer(), SynthesisProvider)


def test_registry_registers_provider_neutrally_and_descriptors_are_visible() -> None:
    registry = ProviderRegistry()
    registry.register_source(FixtureSource())
    registry.register_synthesizer(ExtractiveSynthesizer())

    source = registry.get_source("fixture.alpha")
    found = source.search(SearchRequest(query="reproducibility", limit=1), _context())

    assert found[0].provider_id == "work-1"
    assert registry.get_synthesizer("extractive").descriptor().kind is CapabilityKind.SYNTHESIS
    assert [item.name for item in registry.list_descriptors()] == ["extractive", "fixture.alpha"]


@pytest.mark.parametrize(
    "provider",
    [
        object(),
        type(
            "BadDescriptor",
            (),
            {"descriptor": lambda self: {"name": "bad"}, "search": lambda *_: []},
        )(),
        type(
            "WrongKind",
            (),
            {
                "descriptor": lambda self: CapabilityDescriptor(
                    name="wrong.kind",
                    version="1",
                    kind=CapabilityKind.SYNTHESIS,
                    risk=RiskLevel.LOCAL_READ,
                ),
                "search": lambda *_: [],
            },
        )(),
    ],
)
def test_registry_rejects_malformed_source_providers(provider: object) -> None:
    with pytest.raises(ProviderRegistrationError):
        ProviderRegistry().register_source(provider)


def test_registry_rejects_duplicate_and_incompatible_contracts() -> None:
    registry = ProviderRegistry()
    registry.register_source(FixtureSource())
    with pytest.raises(ProviderRegistrationError, match="already registered"):
        registry.register_source(FixtureSource())

    class FutureSource(FixtureSource):
        def descriptor(self) -> CapabilityDescriptor:
            return CapabilityDescriptor(
                name="future.source",
                version="2.0.0",
                kind=CapabilityKind.SOURCE,
                risk=RiskLevel.LOCAL_READ,
                contract_version=2,
                supported_contract_versions=(2,),
            )

    with pytest.raises(ProviderRegistrationError, match="contract"):
        registry.register_source(FutureSource())


class _FakeEntryPoint:
    def __init__(self, name: str, factory: object, group: str) -> None:
        self.name = name
        self.group = group
        self.value = f"tests:{name}"
        self._factory = factory

    def load(self) -> object:
        if isinstance(self._factory, BaseException):
            raise self._factory
        return self._factory


class _FakeEntryPoints(list[_FakeEntryPoint]):
    def select(self, *, group: str) -> _FakeEntryPoints:
        return _FakeEntryPoints(item for item in self if item.group == group)


def test_entry_point_discovery_isolated_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    entry_points = _FakeEntryPoints(
        [
            _FakeEntryPoint("fixture", FixtureSource, "openscience_agent.sources"),
            _FakeEntryPoint(
                "broken",
                RuntimeError("extension import failed"),
                "openscience_agent.sources",
            ),
            _FakeEntryPoint(
                "extractive",
                ExtractiveSynthesizer,
                "openscience_agent.synthesizers",
            ),
        ]
    )
    monkeypatch.setattr(metadata, "entry_points", lambda: entry_points)

    registry = ProviderRegistry()
    failures = registry.discover_entry_points()

    assert registry.get_source("fixture.alpha")
    assert registry.get_synthesizer("extractive")
    assert len(failures) == 1
    assert failures[0].entry_point == "broken"
    assert "extension import failed" in failures[0].error
    assert registry.health()["broken"].available is False
