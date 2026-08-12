"""Built-in provider adapters for scholarly discovery and claim synthesis."""

from .crossref import CrossrefSourceProvider
from .fixtures import FIXTURE_RETRIEVED_AT, FixtureSourceProvider, load_fixture_providers
from .local_files import DEFAULT_EXTENSIONS, LocalFileSourceProvider
from .model import ExtractiveSynthesizer, ModelTransport, OpenAICompatibleSynthesizer
from .openalex import OpenAlexSourceProvider, SourceTransport

__all__ = [
    "DEFAULT_EXTENSIONS",
    "FIXTURE_RETRIEVED_AT",
    "CrossrefSourceProvider",
    "ExtractiveSynthesizer",
    "FixtureSourceProvider",
    "LocalFileSourceProvider",
    "ModelTransport",
    "OpenAICompatibleSynthesizer",
    "OpenAlexSourceProvider",
    "SourceTransport",
    "load_fixture_providers",
]
