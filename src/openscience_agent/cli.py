"""Command-line application adapter for OpenScience Agent."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any, NoReturn

from . import __version__
from .adapters import (
    CrossrefSourceProvider,
    ExtractiveSynthesizer,
    LocalFileSourceProvider,
    OpenAICompatibleSynthesizer,
    OpenAlexSourceProvider,
    load_fixture_providers,
)
from .domain import ResearchPlan, ResearchRequest, RunLimits, utc_now
from .errors import ConfigurationError, OpenScienceError, PolicyDeniedError, ValidationError
from .export import export_run
from .orchestrator import ResearchOrchestrator
from .policy import PolicyEngine, redact_text
from .registry import ProviderRegistry
from .replay import replay_run
from .report import render_report
from .storage import RunStore
from .validation import validate_claim_evidence, validate_run

EXIT_FAILURE = 1
EXIT_USAGE = 2
EXIT_POLICY = 3
EXIT_PARTIAL = 4


class CLIError(Exception):
    def __init__(self, message: str, *, exit_code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.exit_code = exit_code


class _CLIArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise CLIError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = _CLIArgumentParser(
        prog="openscience",
        description="Evidence-first, reproducible research agent",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan", help="Create a reviewable research plan")
    _add_question(plan_parser)
    _add_request_options(plan_parser)
    plan_parser.add_argument("--output", type=Path, help="Write plan JSON to this file")

    run_parser = subparsers.add_parser("run", help="Create and execute a research run")
    _add_question(run_parser)
    _add_request_options(run_parser)
    _add_provider_options(run_parser)
    run_parser.add_argument("--plan", type=Path, help="Execute a reviewed plan JSON file")
    run_parser.add_argument("--yes", action="store_true", help="Approve the plan")
    run_parser.add_argument(
        "--stop-after-step",
        choices=ResearchOrchestrator.STEP_IDS,
        help=argparse.SUPPRESS,
    )

    resume_parser = subparsers.add_parser("resume", help="Resume from a valid checkpoint")
    resume_parser.add_argument("run_directory", type=Path)
    _add_provider_options(resume_parser, include_workspace=False)
    resume_parser.add_argument("--yes", action="store_true", help="Approve continuation")

    validate_parser = subparsers.add_parser("validate", help="Audit a recorded research run")
    validate_parser.add_argument("run_directory", type=Path)
    validate_parser.add_argument("--json", action="store_true", dest="json_output")

    replay_parser = subparsers.add_parser("replay", help="Reconstruct a run without providers")
    replay_parser.add_argument("run_directory", type=Path)
    replay_parser.add_argument("--json", action="store_true", dest="json_output")

    inspect_parser = subparsers.add_parser("inspect", help="Inspect audited run provenance")
    inspect_parser.add_argument("run_directory", type=Path)
    inspect_parser.add_argument("--json", action="store_true", dest="json_output")

    cancel_parser = subparsers.add_parser("cancel", help="Request cancellation of a research run")
    cancel_parser.add_argument("run_directory", type=Path)
    cancel_parser.add_argument("--json", action="store_true", dest="json_output")

    export_parser = subparsers.add_parser("export", help="Export a portable research bundle")
    export_parser.add_argument("run_directory", type=Path)
    export_parser.add_argument("--output", type=Path, required=True)
    export_parser.add_argument("--json", action="store_true", dest="json_output")

    providers_parser = subparsers.add_parser(
        "providers", help="List declared provider capabilities"
    )
    providers_parser.add_argument("--fixture", type=Path, action="append", default=[])
    providers_parser.add_argument("--local-root", type=Path, action="append", default=[])
    providers_parser.add_argument("--email")
    providers_parser.add_argument("--json", action="store_true", dest="json_output")
    return parser


def _add_question(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("question", nargs="?", help="Research question")
    parser.add_argument("--request", type=Path, help="Load the request from JSON")


def _add_request_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--scope")
    parser.add_argument("--constraint", action="append", default=[])
    parser.add_argument("--assumption", action="append", default=[])
    parser.add_argument("--max-records", type=_positive_int, default=50)
    parser.add_argument("--max-network-requests", type=_nonnegative_int, default=10)
    parser.add_argument("--timeout", type=_positive_int, default=300)
    parser.add_argument("--workspace", type=Path, default=Path(".openscience-runs"))
    parser.add_argument("--json", action="store_true", dest="json_output")


def _add_provider_options(
    parser: argparse.ArgumentParser, *, include_workspace: bool = True
) -> None:
    parser.add_argument("--fixture", type=Path, action="append", default=[])
    parser.add_argument("--local-root", type=Path, action="append", default=[])
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--allow-network", action="store_true")
    parser.add_argument("--email")
    parser.add_argument(
        "--openalex-api-key",
        help="OpenAlex key (prefer OPENSCIENCE_OPENALEX_API_KEY to avoid process arguments)",
    )
    parser.add_argument(
        "--crossref-api-key",
        help="Crossref key (prefer OPENSCIENCE_CROSSREF_API_KEY to avoid process arguments)",
    )
    parser.add_argument("--model-config", type=Path)
    parser.add_argument("--model-endpoint")
    parser.add_argument("--model-name")
    parser.add_argument("--model-timeout", type=_positive_float)
    parser.add_argument("--synthesizer", help="Select a registered synthesis provider by name")
    if not include_workspace:
        parser.add_argument("--json", action="store_true", dest="json_output")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args: argparse.Namespace | None = None
    requested_json = "--json" in (argv if argv is not None else sys.argv[1:])
    try:
        args = parser.parse_args(argv)
        return dispatch(args)
    except CLIError as error:
        _print_error(error, args=args, code="usage.invalid", requested_json=requested_json)
        return error.exit_code
    except PolicyDeniedError as error:
        _print_error(error, args=args, code=error.code, requested_json=requested_json)
        return EXIT_POLICY
    except (ValidationError, ConfigurationError) as error:
        _print_error(error, args=args, code=error.code, requested_json=requested_json)
        return EXIT_USAGE
    except (OpenScienceError, ValueError, OSError, json.JSONDecodeError) as error:
        _print_error(
            error,
            args=args,
            code=getattr(error, "code", "openscience.error"),
            requested_json=requested_json,
        )
        return EXIT_FAILURE
    except Exception as error:  # provider extensions are an untrusted application boundary
        _print_error(
            error,
            args=args,
            code="internal.failure",
            requested_json=requested_json,
        )
        return EXIT_FAILURE


def dispatch(args: argparse.Namespace) -> int:
    if args.command == "plan":
        request = _request_from_args(args)
        orchestrator = _orchestrator(ProviderRegistry(), PolicyEngine())
        plan = orchestrator.create_plan(request)
        result: dict[str, Any] = {"request": request.to_dict(), "plan": plan.to_dict()}
        if args.output:
            _atomic_json(args.output, plan.to_dict())
            result["output"] = str(args.output.expanduser().resolve())
        _print(result, json_output=args.json_output, human=f"Created {len(plan.steps)}-step plan")
        return 0

    if args.command == "providers":
        registry, _ = _build_registry(args)
        records = [item.to_dict() for item in registry.list_descriptors()]
        known = {str(item["name"]) for item in records}
        records.extend(
            {
                "name": health.name,
                "version": health.version,
                "kind": health.kind.value if health.kind else None,
                "risk": None,
                "available": False,
                "health_error": health.error,
                "entry_point_group": health.entry_point_group,
            }
            for health in registry.health().values()
            if not health.available and health.name not in known
        )
        records.sort(key=lambda item: str(item["name"]))
        if args.json_output:
            _print({"providers": records}, json_output=True)
        else:
            for record in records:
                health = (
                    "available" if record["available"] else f"unavailable: {record['health_error']}"
                )
                print(
                    f"{record['name']}\t{record.get('kind')}\t{record.get('risk')}\t"
                    f"v{record['version']}\t{health}"
                )
        return 0

    if args.command == "validate":
        report = validate_run(args.run_directory)
        _print(
            report.to_dict(),
            json_output=args.json_output,
            human=(
                f"PASS: {len(report.warnings)} warning(s)"
                if report.valid
                else f"FAIL: {len(report.errors)} error(s), {len(report.warnings)} warning(s)"
            ),
        )
        return 0 if report.valid else EXIT_FAILURE

    if args.command == "replay":
        summary = replay_run(args.run_directory)
        _print(
            summary,
            json_output=args.json_output,
            human=(
                f"Run {summary['run_id']}: {summary['status']}; "
                f"{summary['sources']} sources, {summary['evidence']} evidence, "
                f"{summary['claims']} claims"
            ),
        )
        return 0

    if args.command == "inspect":
        summary = replay_run(args.run_directory)
        manifest = RunStore.open(args.run_directory).read_json("manifest.json")
        result = {
            "summary": summary,
            "request": manifest.get("request"),
            "plan": manifest.get("plan"),
            "execution": manifest.get("execution"),
            "capabilities": manifest.get("capabilities", []),
            "records": manifest.get("records", {}),
            "artifacts": manifest.get("artifacts", []),
            "limitations": manifest.get("limitations", []),
        }
        _print(
            result,
            json_output=args.json_output,
            human=(
                f"Run {summary['run_id']}: {summary['status']}\n"
                f"Question: {manifest.get('request', {}).get('question', '')}\n"
                f"Completed steps: {', '.join(summary['completed_steps']) or 'none'}\n"
                f"Records: {summary['sources']} sources, {summary['evidence']} evidence, "
                f"{summary['claims']} claims"
            ),
        )
        return 0

    if args.command == "cancel":
        store = RunStore.open(args.run_directory)
        marker = store.run_directory / "cancel-requested.json"
        if marker.exists():
            requested_at = store.read_json("cancel-requested.json").get("requested_at")
        else:
            requested_at = utc_now()
            store.write_json("cancel-requested.json", {"requested_at": requested_at})
        result = {"run_directory": str(store.run_directory), "requested_at": requested_at}
        _print(result, json_output=args.json_output, human="Cancellation requested")
        return 0

    if args.command == "export":
        path = export_run(args.run_directory, args.output)
        export_result: dict[str, Any] = {"output": str(path), "size": path.stat().st_size}
        _print(export_result, json_output=args.json_output, human=f"Exported {path}")
        return 0

    if args.command == "run":
        request = _request_from_args(args)
        registry, default_sources = _build_registry(args)
        source_names = tuple(args.source or default_sources or request.source_names)
        if not source_names:
            raise CLIError("select at least one --source, --fixture, or --local-root")
        request = _request_with_sources(
            request, source_names, approved_local_roots=tuple(args.local_root)
        )
        policy = PolicyEngine(
            allow_network=args.allow_network,
            approved_local_roots=tuple(args.local_root),
        )
        synthesizer_name = _configure_synthesizer(
            registry,
            args.model_config,
            requested_name=args.synthesizer,
            endpoint=args.model_endpoint,
            model=args.model_name,
            timeout=args.model_timeout,
        )
        orchestrator = _orchestrator(registry, policy)
        plan = _load_plan(args.plan) if args.plan else orchestrator.create_plan(request)
        approved = _plan_approved(plan, assume_yes=args.yes, json_output=args.json_output)
        outcome = orchestrator.execute(
            request,
            workspace=args.workspace,
            source_names=source_names,
            synthesizer_name=synthesizer_name,
            plan=plan,
            approved=approved,
            stop_after_step=args.stop_after_step,
        )
        _print_outcome(outcome, args.json_output)
        return _outcome_exit_code(outcome.status.value)

    if args.command == "resume":
        store = RunStore.open(args.run_directory)
        checkpoint = store.read_json("checkpoint.json")
        stored_request = ResearchRequest.from_dict(store.read_json("request.json"))
        registry, default_sources = _build_registry(args)
        source_names = tuple(args.source or default_sources or checkpoint.get("source_names", []))
        missing = [name for name in source_names if not _registry_has_source(registry, name)]
        if missing:
            raise CLIError("resume requires provider configuration for: " + ", ".join(missing))
        if "local-files" in source_names:
            configured_roots = tuple(str(path.expanduser().resolve()) for path in args.local_root)
            if configured_roots != stored_request.approved_local_roots:
                raise CLIError("resume local roots must exactly match the recorded approved roots")
        synthesizer_name = _configure_synthesizer(
            registry,
            args.model_config,
            requested_name=args.synthesizer,
            endpoint=args.model_endpoint,
            model=args.model_name,
            timeout=args.model_timeout,
        )
        if checkpoint.get("synthesizer") != synthesizer_name:
            raise CLIError(
                f"recorded synthesizer is {checkpoint.get('synthesizer')!r}, "
                f"configured {synthesizer_name!r}"
            )
        plan = ResearchPlan.from_dict(store.read_json("plan.json"))
        approved = _plan_approved(plan, assume_yes=args.yes, json_output=args.json_output)
        if not approved:
            raise CLIError("resume requires explicit plan approval", exit_code=EXIT_POLICY)
        policy = PolicyEngine(
            allow_network=args.allow_network,
            approved_local_roots=tuple(args.local_root),
        )
        outcome = _orchestrator(registry, policy).resume(
            args.run_directory,
            source_names=source_names,
            synthesizer_name=synthesizer_name,
            approved=True,
        )
        _print_outcome(outcome, args.json_output)
        return _outcome_exit_code(outcome.status.value)

    raise CLIError(f"unknown command {args.command!r}")


def _request_from_args(args: argparse.Namespace) -> ResearchRequest:
    if args.request:
        payload = _load_json_object(args.request)
        request = ResearchRequest.from_dict(payload)
        if args.question and args.question != request.question:
            raise CLIError("positional question conflicts with --request content")
        return request
    if not args.question:
        raise CLIError("provide a QUESTION or --request JSON")
    return ResearchRequest(
        question=args.question,
        scope=args.scope,
        constraints=tuple(args.constraint),
        assumptions=tuple(args.assumption),
        limits=RunLimits(
            max_records=args.max_records,
            max_network_requests=args.max_network_requests,
            timeout_seconds=args.timeout,
        ),
    )


def _request_with_sources(
    request: ResearchRequest,
    source_names: tuple[str, ...],
    *,
    approved_local_roots: tuple[Path, ...] = (),
) -> ResearchRequest:
    payload = request.to_dict()
    payload.pop("request_id", None)
    payload["source_names"] = list(source_names)
    if approved_local_roots:
        payload["approved_local_roots"] = [str(path) for path in approved_local_roots]
    return ResearchRequest.from_dict(payload)


def _build_registry(args: argparse.Namespace) -> tuple[ProviderRegistry, list[str]]:
    registry = ProviderRegistry()
    registry.register_synthesizer(ExtractiveSynthesizer())
    defaults: list[str] = []
    for fixture in getattr(args, "fixture", []):
        for name, provider in load_fixture_providers(fixture).items():
            registry.register_source(provider)
            defaults.append(name)
    local_roots = tuple(getattr(args, "local_root", []))
    if local_roots:
        local = LocalFileSourceProvider(local_roots)
        registry.register_source(local)
        defaults.append(_descriptor_record(local)["name"])
    email = getattr(args, "email", None)
    registry.register_source(
        OpenAlexSourceProvider(
            api_key=getattr(args, "openalex_api_key", None)
            or os.environ.get("OPENSCIENCE_OPENALEX_API_KEY"),
            mailto=email,
            user_agent=f"openscience-agent/{__version__}",
        )
    )
    registry.register_source(
        CrossrefSourceProvider(
            api_key=getattr(args, "crossref_api_key", None)
            or os.environ.get("OPENSCIENCE_CROSSREF_API_KEY"),
            mailto=email,
            user_agent=f"openscience-agent/{__version__}",
        )
    )
    registry.discover_entry_points()
    return registry, list(dict.fromkeys(defaults))


def _configure_synthesizer(
    registry: ProviderRegistry,
    config_path: Path | None,
    *,
    requested_name: str | None = None,
    endpoint: str | None = None,
    model: str | None = None,
    timeout: float | None = None,
) -> str:
    inline_values = (endpoint, model, timeout)
    has_inline_value = any(value is not None for value in inline_values)
    if config_path is not None and has_inline_value:
        raise CLIError("--model-config cannot be combined with inline model options")
    if config_path is None and not has_inline_value:
        selected_name = requested_name or "extractive"
        registry.get_synthesizer(selected_name)
        return selected_name
    if requested_name not in {None, "openai-compatible"}:
        raise CLIError("model configuration can only configure the openai-compatible synthesizer")
    if config_path is not None:
        config = _load_json_object(config_path)
    else:
        missing_inline = [
            name
            for name, value in (("--model-endpoint", endpoint), ("--model-name", model))
            if not value
        ]
        if missing_inline:
            raise CLIError("inline model configuration is missing: " + ", ".join(missing_inline))
        config = {
            "endpoint": endpoint,
            "model": model,
            "timeout": timeout if timeout is not None else 30.0,
            "api_key_env": "OPENSCIENCE_MODEL_API_KEY",
        }
    required = ("endpoint", "model")
    missing = [key for key in required if not config.get(key)]
    if missing:
        raise CLIError("model config is missing: " + ", ".join(missing))
    environment_name = str(config.get("api_key_env", "OPENSCIENCE_MODEL_API_KEY"))
    api_key = os.environ.get(environment_name)
    if not api_key:
        raise CLIError(f"model API key environment variable is not set: {environment_name}")
    provider = OpenAICompatibleSynthesizer(
        endpoint=str(config["endpoint"]),
        model=str(config["model"]),
        api_key=api_key,
        timeout=float(config.get("timeout", 30.0)),
        user_agent=f"openscience-agent/{__version__}",
    )
    registry.register_synthesizer(provider)
    name = _descriptor_record(provider).get("name")
    if not isinstance(name, str):
        raise CLIError("model provider descriptor has no valid name")
    return name


def _load_plan(path: Path) -> ResearchPlan:
    payload = _load_json_object(path)
    payload.pop("plan_id", None)
    return ResearchPlan.from_dict(payload)


def _plan_approved(plan: ResearchPlan, *, assume_yes: bool, json_output: bool) -> bool:
    if assume_yes:
        return True
    if not sys.stdin.isatty() or json_output:
        return False
    print(json.dumps(plan.to_dict(), ensure_ascii=False, indent=2), file=sys.stderr)
    answer = input("Approve this plan? [y/N] ").strip().casefold()
    return answer in {"y", "yes"}


def _orchestrator(registry: ProviderRegistry, policy: PolicyEngine) -> ResearchOrchestrator:
    return ResearchOrchestrator(
        registry=registry,
        policy=policy,
        store_factory=_FileStoreFactory(),
        run_validator=validate_run,
        claim_validator=validate_claim_evidence,
        report_renderer=render_report,
        software_version=__version__,
    )


class _FileStoreFactory:
    """CLI composition adapter; the orchestration kernel sees only repository ports."""

    def create(
        self,
        workspace: Path,
        run_id: str,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunStore:
        return RunStore.create(workspace, run_id, redactor=redactor)

    def open(
        self,
        run_directory: Path,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunStore:
        return RunStore.open(run_directory, redactor=redactor)


def _descriptor_record(provider_or_descriptor: Any) -> dict[str, Any]:
    descriptor = provider_or_descriptor
    if not hasattr(descriptor, "to_dict"):
        candidate = getattr(provider_or_descriptor, "descriptor", None)
        descriptor = candidate() if callable(candidate) else candidate
    result = descriptor.to_dict()
    if not isinstance(result, dict):
        raise CLIError("provider descriptor must serialize to a JSON object")
    return result


def _registry_has_source(registry: ProviderRegistry, name: str) -> bool:
    try:
        registry.get_source(name)
    except (KeyError, OpenScienceError):
        return False
    return True


def _load_json_object(path: Path) -> dict[str, Any]:
    with path.expanduser().open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise CLIError(f"expected a JSON object in {path}")
    return value


def _atomic_json(path: Path, value: Any) -> None:
    target = path.expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, target)


def _print(value: dict[str, Any], *, json_output: bool, human: str | None = None) -> None:
    if json_output:
        print(json.dumps(value, ensure_ascii=False, sort_keys=True))
    elif human:
        print(human)


def _print_error(
    error: BaseException,
    *,
    args: argparse.Namespace | None,
    code: str,
    requested_json: bool = False,
) -> None:
    if requested_json or (args is not None and bool(getattr(args, "json_output", False))):
        print(
            json.dumps(
                {
                    "error": {
                        "code": code,
                        "message": redact_text(str(error)),
                        "type": type(error).__name__,
                    }
                },
                ensure_ascii=False,
                sort_keys=True,
            )
        )
    else:
        print(f"error: {redact_text(str(error))}", file=sys.stderr)


def _print_outcome(outcome: Any, json_output: bool) -> None:
    data = outcome.to_dict()
    _print(
        data,
        json_output=json_output,
        human=(
            f"Run {data['run_id']}: {data['status']}\n"
            f"Directory: {data['run_directory']}\n"
            f"Report: {data['report']}\n"
            f"Manifest: {data['manifest']}\n"
            f"Records: {data['sources']} sources, {data['evidence']} evidence, "
            f"{data['claims']} claims"
        ),
    )


def _outcome_exit_code(status: str) -> int:
    if status in {"completed", "awaiting_approval"}:
        return 0
    if status == "partial":
        return EXIT_PARTIAL
    return EXIT_FAILURE


def _positive_int(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def _nonnegative_int(value: str) -> int:
    result = int(value)
    if result < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return result


def _positive_float(value: str) -> float:
    result = float(value)
    if not 0 < result <= 300:
        raise argparse.ArgumentTypeError("must be in (0, 300]")
    return result


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
