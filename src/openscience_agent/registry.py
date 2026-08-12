"""Validated built-in and Python entry-point provider registration."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from importlib import metadata
from threading import RLock
from typing import Any

from .domain import CapabilityDescriptor, CapabilityKind
from .errors import ProviderRegistrationError
from .ports import SourceProvider, SynthesisProvider

SOURCE_ENTRY_POINT_GROUP = "openscience_agent.sources"
SYNTHESIS_ENTRY_POINT_GROUP = "openscience_agent.synthesizers"
CONTRACT_VERSION = 1


@dataclass(frozen=True, slots=True)
class ProviderLoadFailure:
    entry_point: str
    group: str
    error: str

    def to_dict(self) -> dict[str, str]:
        return {
            "entry_point": self.entry_point,
            "group": self.group,
            "error": self.error,
        }


@dataclass(frozen=True, slots=True)
class ProviderHealth:
    name: str
    kind: CapabilityKind | None
    available: bool
    version: str | None = None
    error: str | None = None
    entry_point_group: str | None = None

    def to_dict(self) -> dict[str, str | bool | None]:
        return {
            "name": self.name,
            "kind": self.kind.value if self.kind else None,
            "version": self.version,
            "available": self.available,
            "error": self.error,
            "entry_point_group": self.entry_point_group,
        }


class ProviderRegistry:
    """Own provider identities while keeping imports out of the orchestrator."""

    def __init__(
        self,
        *,
        contract_version: int = CONTRACT_VERSION,
        sources: Iterable[object] = (),
        synthesizers: Iterable[object] = (),
    ) -> None:
        if (
            isinstance(contract_version, bool)
            or not isinstance(contract_version, int)
            or contract_version < 1
        ):
            raise ProviderRegistrationError("contract_version must be a positive integer")
        self.contract_version = contract_version
        self._sources: dict[str, SourceProvider] = {}
        self._synthesizers: dict[str, SynthesisProvider] = {}
        self._health: dict[str, ProviderHealth] = {}
        self._failures: list[ProviderLoadFailure] = []
        self._lock = RLock()
        for provider in sources:
            self.register_source(provider)
        for provider in synthesizers:
            self.register_synthesizer(provider)

    @property
    def failures(self) -> tuple[ProviderLoadFailure, ...]:
        with self._lock:
            return tuple(self._failures)

    def register(self, provider: object, *, replace: bool = False) -> CapabilityDescriptor:
        descriptor = _provider_descriptor(provider)
        if descriptor.kind is CapabilityKind.SOURCE:
            return self.register_source(provider, replace=replace)
        if descriptor.kind is CapabilityKind.SYNTHESIS:
            return self.register_synthesizer(provider, replace=replace)
        raise ProviderRegistrationError(
            f"provider {descriptor.name!r} has unsupported kind {descriptor.kind.value!r}; "
            "the MVP registry supports source and synthesis providers"
        )

    def register_source(
        self,
        provider: object,
        *,
        replace: bool = False,
    ) -> CapabilityDescriptor:
        descriptor = self._validate(provider, CapabilityKind.SOURCE, "search")
        with self._lock:
            self._reserve_name(descriptor.name, replace=replace)
            if replace:
                self._synthesizers.pop(descriptor.name, None)
            self._sources[descriptor.name] = provider  # type: ignore[assignment]
            self._health[descriptor.name] = ProviderHealth(
                name=descriptor.name,
                kind=descriptor.kind,
                version=descriptor.version,
                available=descriptor.available,
                error=descriptor.health_error,
            )
        return descriptor

    def register_synthesizer(
        self,
        provider: object,
        *,
        replace: bool = False,
    ) -> CapabilityDescriptor:
        descriptor = self._validate(provider, CapabilityKind.SYNTHESIS, "synthesize")
        with self._lock:
            self._reserve_name(descriptor.name, replace=replace)
            if replace:
                self._sources.pop(descriptor.name, None)
            self._synthesizers[descriptor.name] = provider  # type: ignore[assignment]
            self._health[descriptor.name] = ProviderHealth(
                name=descriptor.name,
                kind=descriptor.kind,
                version=descriptor.version,
                available=descriptor.available,
                error=descriptor.health_error,
            )
        return descriptor

    # Descriptive aliases useful when a caller distinguishes configured built-ins from extensions.
    register_builtin = register
    register_source_provider = register_source
    register_synthesis_provider = register_synthesizer

    def get_source(self, name: str) -> SourceProvider:
        with self._lock:
            try:
                provider = self._sources[name]
            except KeyError as error:
                raise ProviderRegistrationError(
                    f"source provider is not registered: {name}"
                ) from error
            health = self._health[name]
            if not health.available:
                raise ProviderRegistrationError(
                    f"source provider {name!r} is unavailable: {health.error or 'health check failed'}"
                )
            return provider

    def get_synthesizer(self, name: str) -> SynthesisProvider:
        with self._lock:
            try:
                provider = self._synthesizers[name]
            except KeyError as error:
                raise ProviderRegistrationError(
                    f"synthesis provider is not registered: {name}"
                ) from error
            health = self._health[name]
            if not health.available:
                raise ProviderRegistrationError(
                    f"synthesis provider {name!r} is unavailable: {health.error or 'health check failed'}"
                )
            return provider

    def list_descriptors(
        self,
        kind: CapabilityKind | str | None = None,
        *,
        include_unavailable: bool = True,
    ) -> list[CapabilityDescriptor]:
        requested_kind = CapabilityKind(kind) if kind is not None else None
        with self._lock:
            providers: list[object] = []
            if requested_kind in (None, CapabilityKind.SOURCE):
                providers.extend(self._sources.values())
            if requested_kind in (None, CapabilityKind.SYNTHESIS):
                providers.extend(self._synthesizers.values())
            descriptors = [_provider_descriptor(provider) for provider in providers]
        if not include_unavailable:
            descriptors = [item for item in descriptors if item.available]
        return sorted(descriptors, key=lambda item: item.name)

    def health(self) -> dict[str, ProviderHealth]:
        with self._lock:
            return dict(sorted(self._health.items()))

    def discover_entry_points(
        self,
        *,
        groups: Iterable[str] = (SOURCE_ENTRY_POINT_GROUP, SYNTHESIS_ENTRY_POINT_GROUP),
    ) -> tuple[ProviderLoadFailure, ...]:
        """Load zero-argument factories; isolate every import/factory/contract failure."""

        current_failures: list[ProviderLoadFailure] = []
        try:
            available = metadata.entry_points()
        except Exception as error:  # import metadata can be supplied by external installers
            failure = ProviderLoadFailure("<discovery>", "<all>", _error_text(error))
            self._record_failure(failure)
            return (failure,)

        for group in tuple(groups):
            if group not in {SOURCE_ENTRY_POINT_GROUP, SYNTHESIS_ENTRY_POINT_GROUP}:
                raise ProviderRegistrationError(f"unsupported provider entry-point group: {group}")
            for entry_point in _entry_points_for(available, group):
                entry_name = str(getattr(entry_point, "name", "<unnamed>"))
                try:
                    loaded = entry_point.load()
                    if not callable(loaded):
                        raise ProviderRegistrationError(
                            "entry point must load a zero-argument factory"
                        )
                    provider = loaded()
                    if group == SOURCE_ENTRY_POINT_GROUP:
                        descriptor = self.register_source(provider)
                    else:
                        descriptor = self.register_synthesizer(provider)
                    with self._lock:
                        existing = self._health[descriptor.name]
                        self._health[descriptor.name] = ProviderHealth(
                            name=existing.name,
                            kind=existing.kind,
                            version=existing.version,
                            available=existing.available,
                            error=existing.error,
                            entry_point_group=group,
                        )
                except Exception as error:
                    failure = ProviderLoadFailure(entry_name, group, _error_text(error))
                    current_failures.append(failure)
                    self._record_failure(failure)
        return tuple(current_failures)

    def _record_failure(self, failure: ProviderLoadFailure) -> None:
        with self._lock:
            self._failures.append(failure)
            self._health[failure.entry_point] = ProviderHealth(
                name=failure.entry_point,
                kind=(
                    CapabilityKind.SOURCE
                    if failure.group == SOURCE_ENTRY_POINT_GROUP
                    else CapabilityKind.SYNTHESIS
                    if failure.group == SYNTHESIS_ENTRY_POINT_GROUP
                    else None
                ),
                available=False,
                error=failure.error,
                entry_point_group=failure.group,
            )

    def _validate(
        self,
        provider: object,
        expected_kind: CapabilityKind,
        operation: str,
    ) -> CapabilityDescriptor:
        descriptor = _provider_descriptor(provider)
        if descriptor.kind is not expected_kind:
            raise ProviderRegistrationError(
                f"provider {descriptor.name!r} declares kind {descriptor.kind.value!r}; "
                f"expected {expected_kind.value!r}"
            )
        if self.contract_version not in descriptor.supported_contract_versions:
            raise ProviderRegistrationError(
                f"provider {descriptor.name!r} does not support contract version "
                f"{self.contract_version}; supports {descriptor.supported_contract_versions}"
            )
        if descriptor.contract_version != self.contract_version:
            raise ProviderRegistrationError(
                f"provider {descriptor.name!r} targets contract version "
                f"{descriptor.contract_version}, expected {self.contract_version}"
            )
        if not callable(getattr(provider, operation, None)):
            raise ProviderRegistrationError(
                f"provider {descriptor.name!r} must implement callable {operation}()"
            )
        return descriptor

    def _reserve_name(self, name: str, *, replace: bool) -> None:
        exists = name in self._sources or name in self._synthesizers
        if exists and not replace:
            raise ProviderRegistrationError(f"provider name is already registered: {name}")


def _provider_descriptor(provider: object) -> CapabilityDescriptor:
    descriptor_member = getattr(provider, "descriptor", None)
    if descriptor_member is None:
        raise ProviderRegistrationError("provider must expose descriptor()")
    try:
        descriptor = descriptor_member() if callable(descriptor_member) else descriptor_member
    except Exception as error:
        raise ProviderRegistrationError(
            f"provider descriptor failed: {_error_text(error)}"
        ) from error
    if not isinstance(descriptor, CapabilityDescriptor):
        raise ProviderRegistrationError(
            "provider descriptor() must return CapabilityDescriptor, "
            f"not {type(descriptor).__name__}"
        )
    return descriptor


def _entry_points_for(available: Any, group: str) -> tuple[Any, ...]:
    select = getattr(available, "select", None)
    if callable(select):
        return tuple(select(group=group))
    if isinstance(available, Mapping):
        return tuple(available.get(group, ()))
    return tuple(item for item in available if getattr(item, "group", None) == group)


def _error_text(error: BaseException) -> str:
    message = str(error).strip()
    return f"{type(error).__name__}: {message}" if message else type(error).__name__


__all__ = [
    "CONTRACT_VERSION",
    "ProviderHealth",
    "ProviderLoadFailure",
    "ProviderRegistry",
    "SOURCE_ENTRY_POINT_GROUP",
    "SYNTHESIS_ENTRY_POINT_GROUP",
]
