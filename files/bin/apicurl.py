#!/usr/bin/env python
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, quote_plus

APP_NAME = "curlapi"
APP_VERSION = "0.5.0"
HTTP_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"}


@dataclass(frozen=True)
class Endpoint:
    method: str
    path: str
    summary: str
    operation: dict[str, Any]


@dataclass(frozen=True)
class FetchResult:
    data: dict[str, Any]
    raw_text: str
    http_status: int
    url: str


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def config_root() -> Path:
    if explicit := os.environ.get("CURLAPI_CONFIG_HOME"):
        return Path(explicit).expanduser()
    if xdg := os.environ.get("XDG_CONFIG_HOME"):
        return Path(xdg).expanduser() / APP_NAME
    if platform.system() == "Windows" and (appdata := os.environ.get("APPDATA")):
        return Path(appdata) / APP_NAME
    return Path.home() / ".config" / APP_NAME


def validate_name(value: str, label: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError(f"{label} is empty.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise ValueError(
            f"{label} must only contain letters, numbers, underscore, dash, or dot: {value!r}"
        )
    return value


def api_root(alias: str) -> Path:
    return config_root() / "apis" / validate_name(alias, "API alias")


def config_path(alias: str) -> Path:
    return api_root(alias) / "config.json"


def cache_path(alias: str) -> Path:
    return api_root(alias) / "openapi_cache.json"


def aliases_path(alias: str) -> Path:
    return api_root(alias) / "aliases.json"


def endpoints_path(alias: str) -> Path:
    return api_root(alias) / "endpoints.json"


def scripts_dir(alias: str) -> Path:
    return api_root(alias) / "scripts"


def watch_path(alias: str) -> Path:
    return api_root(alias) / "watch.json"


def history_dir(alias: str) -> Path:
    return api_root(alias) / "history"


def history_index_path(alias: str) -> Path:
    return history_dir(alias) / "index.jsonl"


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def ensure_api_exists(alias: str) -> None:
    if not config_path(alias).exists():
        raise RuntimeError(
            f"Unknown API alias: {alias}. Create it first with: curlapi init {alias} <url>"
        )


def load_config(alias: str) -> dict[str, Any]:
    ensure_api_exists(alias)
    data = read_json(config_path(alias), {})
    if not isinstance(data, dict):
        raise RuntimeError(f"Invalid config: {config_path(alias)}")
    return data


def save_config(alias: str, data: dict[str, Any]) -> None:
    data["updated_at"] = utc_now()
    write_json(config_path(alias), data)


def normalise_base_url(url: str) -> str:
    url = url.strip()
    if not url:
        raise ValueError("Base URL is empty.")
    if not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", url):
        url = "http://" + url
    for suffix in ("/docs", "/redoc", "/openapi.json"):
        if url.rstrip("/").endswith(suffix):
            url = url.rstrip("/")[: -len(suffix)]
            break
    return url.rstrip("/")


def openapi_url_from_base(base_url: str, docs_path: str | None = None) -> str:
    docs_path = docs_path or "/openapi.json"
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", docs_path):
        return docs_path
    return f"{normalise_base_url(base_url)}/{docs_path.lstrip('/')}"


def split_header(header: str) -> tuple[str, str]:
    if ":" not in header:
        raise ValueError(f"Header must look like 'Name: value': {header!r}")
    key, value = header.split(":", 1)
    key = key.strip()
    value = os.path.expandvars(value.strip())
    if not key:
        raise ValueError(f"Header name is empty: {header!r}")
    return key, value


def fetch_json(url: str, headers: list[str] | None = None) -> FetchResult:
    req_headers = {
        "Accept": "application/json",
        "User-Agent": f"{APP_NAME}/{APP_VERSION}",
    }
    for header in headers or []:
        key, value = split_header(header)
        req_headers[key] = value

    req = urllib.request.Request(url, headers=req_headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read()
            status = int(response.status)
            final_url = response.geturl()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} while fetching {url}\n{body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not fetch {url}: {exc}") from exc

    raw_text = raw.decode("utf-8", errors="replace")
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"Response from {url} was not valid JSON. For FastAPI use /openapi.json, not HTML /docs."
        ) from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"Response from {url} was JSON, but not an object.")
    return FetchResult(data=data, raw_text=raw_text, http_status=status, url=final_url)


def ask_yes_no(message: str, *, default: bool = False) -> bool:
    if not sys.stdin.isatty():
        return default
    suffix = "[Y/n]" if default else "[y/N]"
    while True:
        reply = input(f"{message} {suffix} ").strip().lower()
        if not reply:
            return default
        if reply in {"y", "yes"}:
            return True
        if reply in {"n", "no"}:
            return False
        print("Please answer y or n.")


def confirm_prod_if_needed(alias: str, action: str) -> None:
    config = load_config(alias)
    if not config.get("prod"):
        return
    if not ask_yes_no(
        f"Confirm intention to use Production API '{alias}' for {action}.",
        default=False,
    ):
        raise RuntimeError("Cancelled production API action.")


def collect_endpoints(openapi: dict[str, Any]) -> list[Endpoint]:
    paths = openapi.get("paths", {})
    if not isinstance(paths, dict):
        raise RuntimeError("OpenAPI document does not contain a valid 'paths' object.")
    endpoints: list[Endpoint] = []
    for path, path_item in paths.items():
        if not isinstance(path_item, dict):
            continue
        for method, operation in path_item.items():
            method_upper = method.upper()
            if method_upper not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            summary = str(
                operation.get("summary") or operation.get("operationId") or ""
            )
            endpoints.append(
                Endpoint(
                    method=method_upper,
                    path=str(path),
                    summary=summary,
                    operation=operation,
                )
            )
    return sorted(endpoints, key=lambda item: (item.path, item.method))


def openapi_meta(openapi: dict[str, Any]) -> dict[str, Any]:
    info = openapi.get("info", {})
    if not isinstance(info, dict):
        info = {}
    return {
        "title": str(info.get("title", "")),
        "version": str(info.get("version", "")),
        "openapi": str(openapi.get("openapi", "")),
        "endpoints": len(collect_endpoints(openapi)),
    }


def save_openapi_cache(alias: str, fetch: FetchResult) -> dict[str, Any]:
    cache = {
        "schema_version": 1,
        "fetched_at": utc_now(),
        "source_url": fetch.url,
        "http_status": fetch.http_status,
        "meta": openapi_meta(fetch.data),
        "openapi": fetch.data,
    }
    write_json(cache_path(alias), cache)
    return cache


def load_openapi_cache(alias: str) -> dict[str, Any] | None:
    if not cache_path(alias).exists():
        return None
    cache = read_json(cache_path(alias), None)
    if not isinstance(cache, dict) or not isinstance(cache.get("openapi"), dict):
        raise RuntimeError(f"Invalid OpenAPI cache: {cache_path(alias)}")
    return cache


def cache_status_line(cache: dict[str, Any]) -> str:
    meta = cache.get("meta", {})
    if not isinstance(meta, dict):
        meta = {}
    bits = [f"last refreshed: {cache.get('fetched_at', 'unknown')}"]
    if meta.get("title"):
        bits.append(f"title: {meta['title']}")
    if meta.get("version"):
        bits.append(f"version: {meta['version']}")
    if meta.get("endpoints") is not None:
        bits.append(f"endpoints: {meta['endpoints']}")
    return "; ".join(bits)


def print_cache_summary(alias: str, cache: dict[str, Any]) -> None:
    meta = cache.get("meta", {})
    if not isinstance(meta, dict):
        meta = {}
    print(f"Docs cache for {alias}")
    print(f"HTTP status: {cache.get('http_status', '')}")
    print(f"Updated at: {cache.get('fetched_at', '')}")
    print(f"Source URL: {cache.get('source_url', '')}")
    if meta.get("title"):
        print(f"Title: {meta['title']}")
    if meta.get("version"):
        print(f"Version: {meta['version']}")
    if meta.get("openapi"):
        print(f"OpenAPI: {meta['openapi']}")
    print(f"Endpoints: {meta.get('endpoints', 0)}")


def read_key() -> str:
    """Read one keypress for the interactive selector."""
    if platform.system() == "Windows":
        import msvcrt

        ch = msvcrt.getwch()
        if ch in {"\x00", "\xe0"}:
            ch2 = msvcrt.getwch()
            return {"H": "up", "P": "down"}.get(ch2, ch2)
        if ch == "\r":
            return "enter"
        if ch == "\x1b":
            return "escape"
        return ch

    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        ch = sys.stdin.read(1)
        if ch == "\x1b":
            ch2 = sys.stdin.read(1)
            if ch2 == "[":
                ch3 = sys.stdin.read(1)
                return {"A": "up", "B": "down"}.get(ch3, ch3)
            return "escape"
        if ch in {"\r", "\n"}:
            return "enter"
        return ch
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def numbered_select(title: str, labels: list[str], footer: str | None = None) -> int:
    print()
    print(title)
    print("-" * len(title))
    for i, label in enumerate(labels, start=1):
        print(f"[{i:>2}] {label}")
    if footer:
        print()
        print(footer)
    print()
    while True:
        choice = input("Select number: ").strip()
        try:
            index = int(choice)
        except ValueError:
            print("Please enter a number.")
            continue
        if 1 <= index <= len(labels):
            return index - 1
        print(f"Please enter a number between 1 and {len(labels)}.")


def interactive_select(title: str, labels: list[str], footer: str | None = None) -> int:
    """Tiny dependency-free selector: arrows/j/k to move, Enter to select."""
    if not labels:
        raise RuntimeError("Nothing to select.")
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return numbered_select(title, labels, footer)

    selected = 0
    top = 0
    max_rows = max(5, min(18, shutil.get_terminal_size((100, 24)).lines - 8))

    def render() -> None:
        nonlocal top
        if selected < top:
            top = selected
        if selected >= top + max_rows:
            top = selected - max_rows + 1
        visible = labels[top : top + max_rows]
        print("\x1b[2J\x1b[H", end="")
        print(title)
        print("-" * len(title))
        print("Use ↑/↓ or j/k. Enter picks. q cancels.\n")
        for offset, label in enumerate(visible):
            i = top + offset
            prefix = "❯" if i == selected else " "
            print(f"{prefix} {i + 1:>2}. {label}")
        if len(labels) > max_rows:
            print(f"\nShowing {top + 1}-{top + len(visible)} of {len(labels)}")
        if footer:
            print(f"\n{footer}")

    while True:
        render()
        key = read_key()
        if key in {"up", "k"}:
            selected = (selected - 1) % len(labels)
        elif key in {"down", "j"}:
            selected = (selected + 1) % len(labels)
        elif key == "enter":
            print("\x1b[2J\x1b[H", end="")
            return selected
        elif key in {"q", "Q", "escape", "\x03"}:
            print("\x1b[2J\x1b[H", end="")
            raise KeyboardInterrupt


def show_endpoint_menu(endpoints: list[Endpoint], cache: dict[str, Any]) -> Endpoint:
    if not endpoints:
        raise RuntimeError("No endpoints found in OpenAPI document.")
    labels = []
    for endpoint in endpoints:
        summary = f" — {endpoint.summary}" if endpoint.summary else ""
        labels.append(f"{endpoint.method:<6} {endpoint.path}{summary}")
    index = interactive_select(
        "Available endpoints", labels, footer=f"Docs cache: {cache_status_line(cache)}"
    )
    return endpoints[index]


def find_endpoint(
    endpoints: list[Endpoint], endpoint_path: str, method: str | None
) -> Endpoint:
    matches = [
        e
        for e in endpoints
        if e.path == endpoint_path and (method is None or e.method == method.upper())
    ]
    if not matches:
        raise RuntimeError(
            f"No matching endpoint found for {method or '*'} {endpoint_path}"
        )
    if len(matches) > 1:
        methods = ", ".join(e.method for e in matches)
        raise RuntimeError(
            f"Multiple methods found for {endpoint_path}: {methods}. Pass --method."
        )
    return matches[0]


def resolve_ref(openapi: dict[str, Any], ref: str) -> Any:
    if not ref.startswith("#/"):
        return {}
    current: Any = openapi
    for part in ref.removeprefix("#/").split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or part not in current:
            return {}
        current = current[part]
    return current


def dereference_schema(
    openapi: dict[str, Any], schema: dict[str, Any]
) -> dict[str, Any]:
    if "$ref" in schema:
        resolved = resolve_ref(openapi, str(schema["$ref"]))
        if isinstance(resolved, dict):
            return resolved
    return schema


def schema_placeholder(
    openapi: dict[str, Any], schema: dict[str, Any], depth: int = 0
) -> Any:
    if depth > 8:
        return "..."
    schema = dereference_schema(openapi, schema)

    for key in ("anyOf", "oneOf"):
        if key in schema and isinstance(schema[key], list):
            choices = [
                item
                for item in schema[key]
                if isinstance(item, dict) and item.get("type") != "null"
            ]
            if choices:
                return schema_placeholder(openapi, choices[0], depth + 1)

    if "allOf" in schema and isinstance(schema["allOf"], list):
        merged: dict[str, Any] = {"type": "object", "properties": {}}
        required: list[str] = []
        for item in schema["allOf"]:
            if not isinstance(item, dict):
                continue
            item_schema = dereference_schema(openapi, item)
            if isinstance(item_schema.get("properties"), dict):
                merged["properties"].update(item_schema["properties"])
            if isinstance(item_schema.get("required"), list):
                required.extend(str(x) for x in item_schema["required"])
        if required:
            merged["required"] = sorted(set(required))
        return schema_placeholder(openapi, merged, depth + 1)

    if isinstance(schema.get("enum"), list) and schema["enum"]:
        return schema["enum"][0]

    schema_type = schema.get("type")
    if schema_type == "object" or "properties" in schema:
        props = schema.get("properties", {})
        if not isinstance(props, dict):
            return {}
        out = {
            str(k): schema_placeholder(openapi, v, depth + 1)
            for k, v in props.items()
            if isinstance(v, dict)
        }
        return (
            out
            if out
            else ({"key": "value"} if schema.get("additionalProperties") else {})
        )
    if schema_type == "array":
        items = schema.get("items", {})
        return (
            [schema_placeholder(openapi, items, depth + 1)]
            if isinstance(items, dict)
            else []
        )
    if schema_type == "integer":
        return 0
    if schema_type == "number":
        return 0.0
    if schema_type == "boolean":
        return False
    if schema_type == "string":
        fmt = schema.get("format")
        if fmt == "date":
            return "2026-07-02"
        if fmt == "date-time":
            return "2026-07-02T10:00:00Z"
        return "string"
    return "value"


def operation_parameters(operation: dict[str, Any]) -> list[dict[str, Any]]:
    params = operation.get("parameters", [])
    return (
        [p for p in params if isinstance(p, dict)] if isinstance(params, list) else []
    )


def request_body_schema(
    openapi: dict[str, Any], operation: dict[str, Any]
) -> dict[str, Any] | None:
    request_body = operation.get("requestBody")
    if not isinstance(request_body, dict):
        return None
    if "$ref" in request_body:
        resolved = resolve_ref(openapi, str(request_body["$ref"]))
        if isinstance(resolved, dict):
            request_body = resolved
    content = request_body.get("content", {})
    if not isinstance(content, dict):
        return None
    for content_type in ("application/json", "application/*+json"):
        if isinstance(content.get(content_type), dict) and isinstance(
            content[content_type].get("schema"), dict
        ):
            return content[content_type]["schema"]
    for item in content.values():
        if isinstance(item, dict) and isinstance(item.get("schema"), dict):
            return item["schema"]
    return None


def operation_content_type(operation: dict[str, Any]) -> str | None:
    request_body = operation.get("requestBody")
    if not isinstance(request_body, dict):
        return None
    content = request_body.get("content", {})
    if not isinstance(content, dict) or not content:
        return None
    return (
        "application/json"
        if "application/json" in content
        else str(next(iter(content.keys())))
    )


def shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def shell_double_quote(value: str) -> str:
    return (
        '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'
    )


def is_placeholder(value: str) -> bool:
    return bool(re.fullmatch(r"<[^<>]+>", value))


def encode_query_component(value: str) -> str:
    return value if is_placeholder(value) else quote_plus(value)


def path_param_names(path: str) -> list[str]:
    return re.findall(r"{([^{}]+)}", path)


def fill_path(path: str, values: dict[str, str]) -> str:
    out = path
    for key, value in values.items():
        encoded = value if is_placeholder(value) else quote(value, safe="")
        out = out.replace("{" + key + "}", encoded)
    return out


def query_params_for_simple(
    operation: dict[str, Any], no_prompt: bool
) -> dict[str, str]:
    out: dict[str, str] = {}
    for param in operation_parameters(operation):
        if param.get("in") != "query":
            continue
        name = str(param.get("name", "param"))
        required = bool(param.get("required", False))
        if no_prompt or not sys.stdin.isatty():
            if required:
                out[name] = f"<{name}>"
            continue
        label = f"{name} {'[required]' if required else '[optional]'}"
        value = input(f"{label}: ").strip()
        if value:
            out[name] = value
        elif required:
            out[name] = f"<{name}>"
    return out


def path_params_for_simple(path: str, no_prompt: bool) -> dict[str, str]:
    out: dict[str, str] = {}
    for name in path_param_names(path):
        if no_prompt or not sys.stdin.isatty():
            out[name] = f"<{name}>"
        else:
            value = input(f"{name}: ").strip()
            out[name] = value or f"<{name}>"
    return out


def build_relative_url(path: str, query_params: dict[str, str]) -> str:
    relative = path if path.startswith("/") else f"/{path}"
    if query_params:
        relative += "?" + "&".join(
            f"{quote_plus(k)}={encode_query_component(v)}"
            for k, v in query_params.items()
        )
    return relative


def env_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "_", name).upper()


def endpoint_slug(endpoint: Endpoint, name: str | None = None) -> str:
    raw = name or f"{endpoint.method.lower()}_{endpoint.path.strip('/') or 'root'}"
    raw = raw.replace("{", "").replace("}", "")
    raw = re.sub(r"[^A-Za-z0-9]+", "_", raw)
    return raw.strip("_").lower() or "request"


def script_metadata_line(metadata: dict[str, Any]) -> str:
    return "# curlapi-meta: " + json.dumps(metadata, sort_keys=True)


def parse_script_metadata(path: Path) -> dict[str, Any]:
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines()[
            :50
        ]:
            if line.startswith("# curlapi-meta:"):
                data = json.loads(line.split(":", 1)[1].strip())
                return data if isinstance(data, dict) else {}
    except Exception:
        return {}
    return {}


AUTH_MODES = {"bearer", "api-key", "none"}


def normalise_auth_mode(value: str | None) -> str | None:
    if value is None:
        return None
    mode = value.strip().lower()
    if mode in {"", "none"}:
        return None
    if mode not in AUTH_MODES:
        raise ValueError(
            f"Unsupported auth mode: {value!r}. Supported: bearer, api-key, none."
        )
    return mode


def generated_auth_lines(api_alias: str, auth: str | None) -> list[str]:
    mode = normalise_auth_mode(auth)
    if mode is None:
        return []
    safe_env_alias = env_name(api_alias)
    if mode == "bearer":
        return [
            f'curl_args+=( -H "Authorization: Bearer ${{{safe_env_alias}_TOKEN:?set {safe_env_alias}_TOKEN}}" )'
        ]
    if mode == "api-key":
        return [
            f'curl_args+=( -H "X-API-Key: ${{{safe_env_alias}_API_KEY:?set {safe_env_alias}_API_KEY}}" )'
        ]
    return []


def generated_auth_example_lines(api_alias: str) -> list[str]:
    safe_env_alias = env_name(api_alias)
    return [
        "# Auth examples. Regenerate with --auth bearer to make bearer auth active by default.",
        f'# curl_args+=( -H "Authorization: Bearer ${{{safe_env_alias}_TOKEN:?set {safe_env_alias}_TOKEN}}" )',
        f'# curl_args+=( -H "X-API-Key: ${{{safe_env_alias}_API_KEY:?set {safe_env_alias}_API_KEY}}" )',
        "",
    ]


def script_contains(path: Path, needle: str) -> bool:
    try:
        return needle in path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def simple_script(
    *,
    api_alias: str,
    base_url: str,
    openapi: dict[str, Any] | None,
    endpoint: Endpoint,
    relative_url: str,
    payload: Any | None,
    content_type: str | None,
    source: str,
    auth: str | None,
) -> str:
    auth = normalise_auth_mode(auth)
    meta = {
        "schema_version": 1,
        "tool": APP_NAME,
        "mode": "simple",
        "source": source,
        "api_alias": api_alias,
        "method": endpoint.method,
        "path": endpoint.path,
        "relative_url": relative_url,
        "summary": endpoint.summary,
        "auth": auth or "",
        "supports_show": True,
        "created_at": utc_now(),
    }
    url = f"{base_url.rstrip('/')}{relative_url}"

    lines = [
        "#!/usr/bin/env bash",
        "set -Eeuo pipefail",
        "",
        "# Generated by curlapi.",
        "# Mode: simple/literal. This is intentionally close to a curl command you might write yourself.",
        "# Edit this file freely. For repeatable runtime parameters, regenerate with --flex/--flexible.",
        script_metadata_line(meta),
        "",
    ]
    if payload is not None:
        lines += [
            'payload_file="$(mktemp)"',
            'cleanup() { rm -f "$payload_file"; }',
            "trap cleanup EXIT",
            "cat > \"$payload_file\" <<'JSON'",
            json.dumps(payload, indent=2),
            "JSON",
            "",
        ]

    lines += [
        "curl_args=(",
        "  -sS",
        f"  -X {shell_single_quote(endpoint.method)}",
        ")",
        "",
    ]
    if content_type:
        lines.append(
            f"curl_args+=( -H {shell_single_quote(f'Content-Type: {content_type}')} )"
        )
        lines.append("")
    if auth:
        lines += generated_auth_lines(api_alias, auth) + [""]
    else:
        lines += generated_auth_example_lines(api_alias)
    if payload is not None:
        lines += [
            'curl_args+=( --data @"$payload_file" )',
            "",
        ]
    lines += [
        f"curl_args+=( {shell_single_quote(url)} )",
        "",
    ]
    lines += curl_exec_block()
    lines += openapi_notes(openapi, endpoint, relative_url, payload)
    return "\n".join(lines)


def flexible_script(
    *,
    api_alias: str,
    base_url: str,
    openapi: dict[str, Any] | None,
    endpoint: Endpoint,
    payload: Any | None,
    content_type: str | None,
    source: str,
    auth: str | None,
) -> str:
    auth = normalise_auth_mode(auth)
    meta = {
        "schema_version": 1,
        "tool": APP_NAME,
        "mode": "flex",
        "source": source,
        "api_alias": api_alias,
        "method": endpoint.method,
        "path": endpoint.path,
        "relative_url": endpoint.path,
        "summary": endpoint.summary,
        "auth": auth or "",
        "supports_show": True,
        "supports_body_overrides": payload is not None,
        "created_at": utc_now(),
    }
    safe_env_alias = env_name(api_alias)
    lines = [
        "#!/usr/bin/env bash",
        "set -Eeuo pipefail",
        "",
        "# Generated by curlapi.",
        "# Mode: flexible. Runtime values can be passed with: curlapi run API ALIAS --query name=value --body name=value",
        "# Empty runtime query values omit optional query params, e.g. --query candidates=",
        "# Body overrides edit the JSON request body before curl runs, e.g. --body series=Summer --body limit=10",
        script_metadata_line(meta),
        "",
        f'BASE_URL="${{CURLAPI_{safe_env_alias}_BASE_URL:-{base_url}}}"',
        f"REQUEST_PATH_TEMPLATE={shell_single_quote(endpoint.path)}",
        "",
    ]

    # Path params.
    for name in path_param_names(endpoint.path):
        lines.append(f"{env_name(name)}=${{{env_name(name)}-'<{name}>'}}")
    if path_param_names(endpoint.path):
        lines.append("")
        lines.append('REQUEST_PATH="$REQUEST_PATH_TEMPLATE"')
        for name in path_param_names(endpoint.path):
            lines.append(
                f'REQUEST_PATH="${{REQUEST_PATH//{{{name}}}/${env_name(name)}}}"'
            )
    else:
        lines.append('REQUEST_PATH="$REQUEST_PATH_TEMPLATE"')

    lines += [
        "",
        "urlencode() {",
        "  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))' \"$1\"",
        "}",
        "",
        "query_parts=()",
        "add_query_param() {",
        '  local key="$1"',
        '  local value="$2"',
        '  if [[ -n "$value" ]]; then',
        '    query_parts+=("$(urlencode "$key")=$(urlencode "$value")")',
        "  fi",
        "}",
        "",
    ]

    for param in operation_parameters(endpoint.operation):
        if param.get("in") != "query":
            continue
        name = str(param.get("name", "param"))
        required = bool(param.get("required", False))
        default = f"<{name}>" if required else ""
        var = env_name(name)
        lines.append(f"{var}=${{{var}-{shell_single_quote(default)}}}")
        lines.append(f'add_query_param {shell_single_quote(name)} "${var}"')
    if not any(
        p.get("in") == "query" for p in operation_parameters(endpoint.operation)
    ):
        lines.append(
            "# No OpenAPI query parameters were detected. Add add_query_param lines here if needed."
        )
    lines += [
        "",
        'QUERY_STRING=""',
        "if (( ${#query_parts[@]} > 0 )); then",
        '  IFS="&"; QUERY_STRING="${query_parts[*]}"; unset IFS',
        "fi",
        'REQUEST_RELATIVE_URL="$REQUEST_PATH"',
        'if [[ -n "$QUERY_STRING" ]]; then',
        '  REQUEST_RELATIVE_URL="${REQUEST_RELATIVE_URL}?${QUERY_STRING}"',
        "fi",
        'REQUEST_URL="${BASE_URL%/}${REQUEST_RELATIVE_URL}"',
        "",
        "curl_args=(",
        "  -sS",
        f"  -X {shell_single_quote(endpoint.method)}",
        ")",
        "",
    ]
    if content_type:
        lines.append(
            f"curl_args+=( -H {shell_single_quote(f'Content-Type: {content_type}')} )"
        )
        lines.append("")
    if auth:
        lines += generated_auth_lines(api_alias, auth) + [""]
    else:
        lines += generated_auth_example_lines(api_alias)
    if payload is not None:
        lines += [
            'payload_file="$(mktemp)"',
            'cleanup() { rm -f "$payload_file"; }',
            "trap cleanup EXIT",
            "cat > \"$payload_file\" <<'JSON'",
            json.dumps(payload, indent=2),
            "JSON",
            "",
            'if [[ -n "${CURLAPI_BODY_OVERRIDES_JSON:-}" ]]; then',
            "  python3 - \"$payload_file\" <<'PY'",
            "import json",
            "import os",
            "import sys",
            "",
            "path = sys.argv[1]",
            'with open(path, encoding="utf-8") as fh:',
            "    body = json.load(fh)",
            'overrides = json.loads(os.environ.get("CURLAPI_BODY_OVERRIDES_JSON", "{}"))',
            "if not isinstance(overrides, dict):",
            '    raise SystemExit("CURLAPI_BODY_OVERRIDES_JSON must be a JSON object")',
            "if not isinstance(body, dict):",
            '    raise SystemExit("Runtime --body overrides require a JSON object request body template")',
            "",
            "def set_dotted(target, dotted_key, value):",
            '    parts = [part for part in dotted_key.split(".") if part]',
            "    if not parts:",
            '        raise SystemExit("Body override key cannot be empty")',
            "    current = target",
            "    for part in parts[:-1]:",
            "        existing = current.get(part)",
            "        if not isinstance(existing, dict):",
            "            existing = {}",
            "            current[part] = existing",
            "        current = existing",
            "    current[parts[-1]] = value",
            "",
            "for key, value in overrides.items():",
            "    set_dotted(body, str(key), value)",
            'with open(path, "w", encoding="utf-8") as fh:',
            "    json.dump(body, fh, indent=2)",
            '    fh.write("\\n")',
            "PY",
            "fi",
            "",
            'curl_args+=( --data @"$payload_file" )',
            "",
        ]
    lines += [
        'curl_args+=( "$REQUEST_URL" )',
        "",
    ]
    lines += curl_exec_block()
    lines += openapi_notes(openapi, endpoint, "$REQUEST_RELATIVE_URL", payload)
    return "\n".join(lines)


def curl_exec_block() -> list[str]:
    return [
        "print_curl_command() {",
        '  printf "%q " curl "${curl_args[@]}"',
        '  printf "\\n"',
        "}",
        "",
        'if [[ "${CURLAPI_SHOW_COMMAND:-}" == "1" ]]; then',
        "  print_curl_command",
        '  if [[ -n "${payload_file:-}" && -f "$payload_file" ]]; then',
        '    printf "\\n# Request body from %s:\\n" "$payload_file"',
        '    cat "$payload_file"',
        '    printf "\\n"',
        "  fi",
        "  exit 0",
        "fi",
        "",
        'if [[ -n "${CURLAPI_CAPTURE_DIR:-}" ]]; then',
        '  mkdir -p "$CURLAPI_CAPTURE_DIR"',
        '  http_code="$(curl -w "%{http_code}" -o "$CURLAPI_CAPTURE_DIR/response.body" "${curl_args[@]}")"',
        '  printf "%s\\n" "$http_code" > "$CURLAPI_CAPTURE_DIR/http_status"',
        "else",
        '  curl "${curl_args[@]}"',
        "fi",
        "",
    ]


def openapi_notes(
    openapi: dict[str, Any] | None,
    endpoint: Endpoint,
    relative_url: str,
    payload: Any | None,
) -> list[str]:
    lines = [
        "",
        "# ---- Notes ---------------------------------------------------------",
        "#",
    ]
    if openapi is not None and isinstance(openapi.get("info"), dict):
        info = openapi["info"]
        lines += [
            f"# API title: {info.get('title', '')}",
            f"# API version: {info.get('version', '')}",
        ]
    lines += [
        f"# Source endpoint: {endpoint.method} {endpoint.path}",
        f"# Generated URL path: {relative_url}",
        f"# Summary: {endpoint.summary}",
        "#",
    ]
    params = operation_parameters(endpoint.operation)
    if params:
        lines.append("# Parameters:")
        for param in params:
            name = param.get("name", "")
            loc = param.get("in", "")
            req = param.get("required", False)
            desc = str(param.get("description", "")).replace("\n", " ")
            lines.append(f"#   - {name} ({loc}, required={req}) {desc}")
        lines.append("#")
    if payload is not None:
        lines.append("# Request body template:")
        for line in json.dumps(payload, indent=2).splitlines():
            lines.append(f"#   {line}")
        lines.append("#")
    responses = endpoint.operation.get("responses", {})
    if isinstance(responses, dict) and responses:
        lines.append("# Responses:")
        for status_code, response in responses.items():
            desc = (
                str(response.get("description", ""))
                if isinstance(response, dict)
                else ""
            )
            lines.append(f"#   - {status_code}: {desc}")
    lines.append("")
    return lines


def write_script(script: str, alias: str, filename_slug: str) -> Path:
    scripts_dir(alias).mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    path = scripts_dir(alias) / f"{timestamp}_{filename_slug}.sh"
    path.write_text(script, encoding="utf-8", newline="\n")
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def default_platform_editor() -> str | None:
    return "notepad" if platform.system() == "Windows" else None


def open_in_editor(path: Path, editor: str | None) -> None:
    selected = (
        editor
        or os.environ.get("EDITOR")
        or shutil.which("nvim")
        or shutil.which("vim")
        or shutil.which("code")
        or default_platform_editor()
    )
    if selected is None:
        print(f"Created: {path}")
        print("No editor found. Open the file manually.")
        return
    try:
        subprocess.run(selected.split() + [str(path)], check=False)
    except FileNotFoundError:
        print(f"Created: {path}")
        print(f"Could not find editor: {selected}")


def read_aliases(api_alias: str) -> dict[str, Any]:
    data = read_json(aliases_path(api_alias), {"schema_version": 1, "aliases": {}})
    if not isinstance(data, dict):
        data = {"schema_version": 1, "aliases": {}}
    if not isinstance(data.get("aliases"), dict):
        data["aliases"] = {}
    return data


def write_aliases(api_alias: str, data: dict[str, Any]) -> None:
    data.setdefault("schema_version", 1)
    data["updated_at"] = utc_now()
    write_json(aliases_path(api_alias), data)


def read_endpoints(api_alias: str) -> dict[str, Any]:
    data = read_json(endpoints_path(api_alias), {"schema_version": 1, "endpoints": {}})
    if not isinstance(data, dict):
        data = {"schema_version": 1, "endpoints": {}}
    if not isinstance(data.get("endpoints"), dict):
        data["endpoints"] = {}
    return data


def write_endpoints(api_alias: str, data: dict[str, Any]) -> None:
    data.setdefault("schema_version", 1)
    data["updated_at"] = utc_now()
    write_json(endpoints_path(api_alias), data)


def create_endpoint_record(
    api_alias: str,
    *,
    source: str,
    mode: str,
    endpoint: Endpoint,
    script_path: Path,
    request_alias: str | None,
    auth: str | None,
) -> str:
    data = read_endpoints(api_alias)
    ep_id = "ep_" + uuid.uuid4().hex[:8]
    data["endpoints"][ep_id] = {
        "id": ep_id,
        "source": source,
        "mode": mode,
        "method": endpoint.method,
        "path": endpoint.path,
        "summary": endpoint.summary,
        "file_path": str(script_path.expanduser().resolve()),
        "alias": request_alias,
        "auth": auth or "",
        "created_at": utc_now(),
    }
    write_endpoints(api_alias, data)
    return ep_id


def set_alias(
    api_alias: str,
    request_alias: str,
    script_path: Path,
    endpoint_id: str | None = None,
) -> None:
    request_alias = validate_name(request_alias, "Request alias")
    script_path = script_path.expanduser().resolve()
    if not script_path.exists():
        raise RuntimeError(f"Script file does not exist: {script_path}")
    meta = parse_script_metadata(script_path)
    data = read_aliases(api_alias)
    aliases = data["aliases"]
    now = utc_now()
    old = (
        aliases.get(request_alias, {})
        if isinstance(aliases.get(request_alias), dict)
        else {}
    )
    aliases[request_alias] = {
        "file_path": str(script_path),
        "endpoint_id": endpoint_id or old.get("endpoint_id"),
        "created_at": old.get("created_at", now),
        "updated_at": now,
        "method": meta.get("method"),
        "path": meta.get("path"),
        "relative_url": meta.get("relative_url"),
        "summary": meta.get("summary"),
        "mode": meta.get("mode", "simple"),
        "source": meta.get("source", ""),
        "auth": meta.get("auth", ""),
    }
    write_aliases(api_alias, data)


def find_alias_entry(api_alias: str, request_alias: str) -> dict[str, Any]:
    data = read_aliases(api_alias)
    aliases = data.get("aliases", {})
    if not isinstance(aliases, dict) or request_alias not in aliases:
        raise RuntimeError(f"Unknown request alias for {api_alias}: {request_alias}")
    entry = aliases[request_alias]
    if not isinstance(entry, dict) or not entry.get("file_path"):
        raise RuntimeError(f"Invalid alias entry for {api_alias} {request_alias}")
    return entry


def find_endpoint_record(api_alias: str, ep_id: str) -> dict[str, Any]:
    data = read_endpoints(api_alias)
    eps = data.get("endpoints", {})
    if not isinstance(eps, dict) or ep_id not in eps:
        raise RuntimeError(f"Unknown endpoint id for {api_alias}: {ep_id}")
    ep = eps[ep_id]
    if not isinstance(ep, dict):
        raise RuntimeError(f"Invalid endpoint record: {ep_id}")
    return ep


def watch_enabled(api_alias: str) -> bool:
    return bool(read_json(watch_path(api_alias), {}).get("enabled"))


def load_watch(api_alias: str) -> dict[str, Any]:
    data = read_json(watch_path(api_alias), {})
    return data if isinstance(data, dict) else {}


def append_history(
    api_alias: str, record: dict[str, Any], body: str | None = None
) -> dict[str, Any]:
    history_dir(api_alias).mkdir(parents=True, exist_ok=True)
    record = dict(record)
    record["id"] = uuid.uuid4().hex[:8]
    record["timestamp"] = utc_now()
    if body is not None:
        body_path = history_dir(api_alias) / f"{record['id']}.body"
        body_path.write_text(body, encoding="utf-8", newline="\n")
        record["body_path"] = str(body_path)
    with history_index_path(api_alias).open("a", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")
    return record


def maybe_record_history(
    api_alias: str, record: dict[str, Any], body: str | None = None
) -> None:
    watch = load_watch(api_alias)
    if not watch.get("enabled"):
        return
    append_history(
        api_alias, record, body=body if watch.get("capture_output", True) else None
    )


def history_records(api_alias: str) -> list[dict[str, Any]]:
    path = history_index_path(api_alias)
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                item = json.loads(line)
                if isinstance(item, dict):
                    out.append(item)
            except json.JSONDecodeError:
                pass
    return out


def command_init(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    root = api_root(api_alias)
    path = config_path(api_alias)
    if path.exists() and not ask_yes_no(
        f"API alias '{api_alias}' already exists. Overwrite URL/config?", default=False
    ):
        print("Cancelled.")
        return 1
    now = utc_now()
    existing = read_json(path, {}) if path.exists() else {}
    if not isinstance(existing, dict):
        existing = {}
    root.mkdir(parents=True, exist_ok=True)
    config = {
        "schema_version": 1,
        "alias": api_alias,
        "base_url": normalise_base_url(args.url),
        "docs_path": args.path or existing.get("docs_path") or "/openapi.json",
        "prod": bool(existing.get("prod", False)),
        "created_at": existing.get("created_at", now),
        "updated_at": now,
    }
    write_json(path, config)
    scripts_dir(api_alias).mkdir(parents=True, exist_ok=True)
    if not aliases_path(api_alias).exists():
        write_aliases(
            api_alias, {"schema_version": 1, "aliases": {}, "created_at": now}
        )
    if not endpoints_path(api_alias).exists():
        write_endpoints(
            api_alias, {"schema_version": 1, "endpoints": {}, "created_at": now}
        )
    print(f"Initialised {api_alias}: {config['base_url']}")
    print(f"Config: {path}")
    return 0


def command_config(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    config = load_config(api_alias)
    changed = False
    if args.url:
        config["base_url"] = normalise_base_url(args.url)
        changed = True
    if args.path:
        config["docs_path"] = args.path
        changed = True
    if args.prod:
        config["prod"] = True
        changed = True
    if args.no_prod:
        config["prod"] = False
        changed = True
    if args.prod and args.no_prod:
        raise RuntimeError("Use only one of --prod or --no-prod.")
    if changed:
        save_config(api_alias, config)
        print(f"Updated config for {api_alias}.")
    print(f"API alias: {api_alias}")
    print(f"Base URL: {config.get('base_url')}")
    print(f"Docs path: {config.get('docs_path')}")
    print(f"Production confirmation: {'on' if config.get('prod') else 'off'}")
    print(f"Config: {config_path(api_alias)}")
    return 0


def command_docs(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    confirm_prod_if_needed(api_alias, "docs")
    config = load_config(api_alias)

    if args.read_only:
        cache = load_openapi_cache(api_alias)
        if cache is None:
            raise RuntimeError(
                f"No cached docs found for {api_alias}. Run: curlapi docs {api_alias}"
            )
        print_cache_summary(api_alias, cache)
        if args.list:
            print()
            for endpoint in collect_endpoints(cache["openapi"]):
                summary = f" — {endpoint.summary}" if endpoint.summary else ""
                print(f"{endpoint.method:<6} {endpoint.path}{summary}")
        return 0

    docs_path = args.path or str(config.get("docs_path") or "/openapi.json")
    if args.path:
        config["docs_path"] = args.path
        save_config(api_alias, config)

    url = openapi_url_from_base(str(config["base_url"]), docs_path)
    fetch = fetch_json(url, headers=args.header or [])
    cache = save_openapi_cache(api_alias, fetch)
    maybe_record_history(
        api_alias,
        {
            "kind": "docs-refresh",
            "method": "GET",
            "url": fetch.url,
            "http_status": fetch.http_status,
            "exit_code": 0,
        },
        body=fetch.raw_text,
    )
    print_cache_summary(api_alias, cache)
    return 0


def command_drop_docs(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    if not cache_path(api_alias).exists():
        print(f"No docs cache found for {api_alias}.")
        return 0
    if not ask_yes_no(f"Remove cached docs for {api_alias}?", default=False):
        print("Cancelled.")
        return 1
    cache_path(api_alias).unlink(missing_ok=True)
    print(f"Removed docs cache for {api_alias}.")
    return 0


def make_script_for_endpoint(
    args: argparse.Namespace,
    endpoint: Endpoint,
    *,
    openapi: dict[str, Any] | None,
    source: str,
) -> tuple[str, str]:
    api_alias = args.alias
    config = load_config(api_alias)
    schema = (
        request_body_schema(openapi, endpoint.operation)
        if openapi is not None
        else None
    )
    payload = (
        schema_placeholder(openapi, schema)
        if openapi is not None and schema is not None
        else None
    )
    content_type = operation_content_type(endpoint.operation)
    auth = normalise_auth_mode(getattr(args, "auth", None))

    if args.flexible:
        return (
            flexible_script(
                api_alias=api_alias,
                base_url=str(config["base_url"]),
                openapi=openapi,
                endpoint=endpoint,
                payload=payload,
                content_type=content_type,
                source=source,
                auth=auth,
            ),
            "flex",
        )

    path_values = path_params_for_simple(endpoint.path, no_prompt=args.no_prompt)
    endpoint_path = fill_path(endpoint.path, path_values)
    query_params = query_params_for_simple(endpoint.operation, no_prompt=args.no_prompt)
    relative_url = build_relative_url(endpoint_path, query_params)
    return (
        simple_script(
            api_alias=api_alias,
            base_url=str(config["base_url"]),
            openapi=openapi,
            endpoint=endpoint,
            relative_url=relative_url,
            payload=payload,
            content_type=content_type,
            source=source,
            auth=auth,
        ),
        "simple",
    )


def command_add(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    confirm_prod_if_needed(api_alias, "add")

    if args.endpoint_path:
        path = (
            args.endpoint_path
            if args.endpoint_path.startswith("/")
            else f"/{args.endpoint_path}"
        )
        endpoint = Endpoint(
            method=args.method.upper(),
            path=path,
            summary="Manual endpoint",
            operation={"parameters": []},
        )
        openapi = None
        source = "manual"
    else:
        cache = load_openapi_cache(api_alias)
        if cache is None:
            ok = ask_yes_no(
                f"No cached docs found for {api_alias}. Run docs now?", default=True
            )
            if not ok:
                raise RuntimeError(
                    f"No cached docs found. Run: curlapi docs {api_alias}"
                )
            config = load_config(api_alias)
            fetch = fetch_json(
                openapi_url_from_base(
                    str(config["base_url"]),
                    str(config.get("docs_path") or "/openapi.json"),
                )
            )
            cache = save_openapi_cache(api_alias, fetch)
            print_cache_summary(api_alias, cache)
        openapi = cache["openapi"]
        endpoints = collect_endpoints(openapi)
        if args.endpoint:
            endpoint = find_endpoint(endpoints, args.endpoint, args.method)
        else:
            endpoint = show_endpoint_menu(endpoints, cache)
        source = "docs"

    script, mode = make_script_for_endpoint(
        args, endpoint, openapi=openapi, source=source
    )
    script_path = write_script(script, api_alias, endpoint_slug(endpoint, args.name))
    ep_id = create_endpoint_record(
        api_alias,
        source=source,
        mode=mode,
        endpoint=endpoint,
        script_path=script_path,
        request_alias=args.alias_name,
        auth=normalise_auth_mode(getattr(args, "auth", None)),
    )

    print(f"Created: {script_path}")
    print(f"Endpoint id: {ep_id}")
    print(f"Source: {source}")
    print(f"Mode: {mode}")

    if args.alias_name:
        set_alias(api_alias, args.alias_name, script_path, endpoint_id=ep_id)
        print(f"Alias added: {api_alias} {args.alias_name} -> {script_path}")
    else:
        print(f"To alias it: curlapi alias {api_alias} <NAME> {script_path}")

    if not args.no_open:
        open_in_editor(script_path, editor=args.editor)
    return 0


def command_alias(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    set_alias(api_alias, args.request_alias, Path(args.file_path))
    print(
        f"Alias added: {api_alias} {args.request_alias} -> {Path(args.file_path).expanduser().resolve()}"
    )
    return 0


def parse_query_overrides(items: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    raw: dict[str, str] = {}
    env: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise ValueError(f"--query must look like name=value: {item!r}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError("--query name cannot be empty.")
        raw[key] = value
        env[env_name(key)] = value
    return raw, env


def parse_runtime_json_value(value: str) -> Any:
    stripped = value.strip()
    if stripped == "":
        return ""
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return value


def parse_body_overrides(items: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    raw: dict[str, str] = {}
    parsed: dict[str, Any] = {}
    for item in items:
        if "=" not in item:
            raise ValueError(f"--body must look like name=value: {item!r}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError("--body name cannot be empty.")
        raw[key] = value
        parsed[key] = parse_runtime_json_value(value)
    env = (
        {"CURLAPI_BODY_OVERRIDES_JSON": json.dumps(parsed, separators=(",", ":"))}
        if parsed
        else {}
    )
    return raw, env


def run_script_with_capture(
    api_alias: str,
    request_alias: str,
    script_path: Path,
    entry: dict[str, Any],
    run_env: dict[str, str],
    query_raw: dict[str, str],
    body_raw: dict[str, str],
) -> int:
    watch = load_watch(api_alias)
    capture_output = bool(watch.get("capture_output", True))
    with tempfile.TemporaryDirectory(prefix="curlapi-") as tmp:
        env = os.environ.copy()
        env.update(run_env)
        env["CURLAPI_CAPTURE_DIR"] = tmp
        proc = subprocess.run(
            ["bash", str(script_path)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        capture_dir = Path(tmp)
        body_path = capture_dir / "response.body"
        status_path = capture_dir / "http_status"
        body = (
            body_path.read_text(encoding="utf-8", errors="replace")
            if body_path.exists()
            else proc.stdout
        )
        http_status = (
            status_path.read_text(encoding="utf-8", errors="replace").strip()
            if status_path.exists()
            else None
        )
        if body:
            print(body, end="")
            if not body.endswith("\n"):
                print()
        if proc.stderr:
            print(proc.stderr, end="", file=sys.stderr)
        append_history(
            api_alias,
            {
                "kind": "run",
                "request_alias": request_alias,
                "method": entry.get("method"),
                "path": entry.get("path"),
                "url": entry.get("relative_url"),
                "http_status": http_status,
                "exit_code": proc.returncode,
                "script_path": str(script_path),
                "query_overrides": query_raw,
                "query_env": {
                    k: v
                    for k, v in run_env.items()
                    if k != "CURLAPI_BODY_OVERRIDES_JSON"
                },
                "body_overrides": body_raw,
            },
            body=body if capture_output else None,
        )
        return proc.returncode


def alias_choices(api_alias: str) -> list[tuple[str, dict[str, Any]]]:
    aliases = read_aliases(api_alias).get("aliases", {})
    if not isinstance(aliases, dict):
        return []
    out: list[tuple[str, dict[str, Any]]] = []
    for name, entry in sorted(aliases.items()):
        if isinstance(entry, dict):
            out.append((str(name), entry))
    return out


def choose_request_alias(api_alias: str) -> str:
    choices = alias_choices(api_alias)
    if not choices:
        raise RuntimeError(
            f"No request aliases found for {api_alias}. Add one with: curlapi add {api_alias} --alias NAME"
        )
    labels = []
    for name, entry in choices:
        method = str(entry.get("method") or "").strip()
        path = str(entry.get("path") or entry.get("relative_url") or "").strip()
        mode = str(entry.get("mode") or "").strip()
        summary = str(entry.get("summary") or "").strip()
        extra = " — " + summary if summary else ""
        labels.append(f"{name:<18} {mode:<6} {method:<6} {path}{extra}".rstrip())
    index = interactive_select(f"Run request for {api_alias}", labels)
    return choices[index][0]


def command_run(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    request_alias = (
        validate_name(args.request_alias, "Request alias")
        if args.request_alias
        else choose_request_alias(api_alias)
    )
    confirm_prod_if_needed(api_alias, "run")
    entry = find_alias_entry(api_alias, request_alias)
    script_path = Path(str(entry["file_path"])).expanduser()
    if not script_path.exists():
        raise RuntimeError(f"Alias script does not exist: {script_path}")

    query_raw, query_env = parse_query_overrides(args.query or [])
    body_raw, body_env = parse_body_overrides(args.body or [])
    run_env = {**query_env, **body_env}
    meta = parse_script_metadata(script_path)
    mode = str(meta.get("mode") or entry.get("mode") or "simple")
    if (query_raw or body_raw) and mode != "flex":
        raise RuntimeError(
            "Runtime --query/--body are only supported for scripts created with --flex/--flexible."
        )
    if body_raw and not script_contains(script_path, "CURLAPI_BODY_OVERRIDES_JSON"):
        raise RuntimeError(
            "Runtime --body requires a 0.5.0 flex script with a generated JSON request body. Regenerate the alias with curlapi add --flex."
        )

    if args.show:
        if not script_contains(script_path, "CURLAPI_SHOW_COMMAND"):
            prefix = " ".join(
                f"{key}={shell_single_quote(value)}"
                for key, value in sorted(run_env.items())
                if key != "CURLAPI_BODY_OVERRIDES_JSON"
            )
            command = f"bash {shell_single_quote(str(script_path))}"
            print("This script was generated before curlapi run --show support.")
            print("Best-effort command:")
            print(f"{prefix + ' ' if prefix else ''}{command}")
            return 0
        env = os.environ.copy()
        env.update(run_env)
        env["CURLAPI_SHOW_COMMAND"] = "1"
        proc = subprocess.run(["bash", str(script_path)], check=False, env=env)
        return proc.returncode

    if watch_enabled(api_alias):
        return run_script_with_capture(
            api_alias, request_alias, script_path, entry, run_env, query_raw, body_raw
        )

    env = os.environ.copy()
    env.update(run_env)
    proc = subprocess.run(["bash", str(script_path)], check=False, env=env)
    return proc.returncode


def format_table(rows: list[list[str]], headers: list[str]) -> str:
    all_rows = [headers] + rows
    widths = [max(len(str(row[i])) for row in all_rows) for i in range(len(headers))]

    def fmt(row: list[str]) -> str:
        return "  ".join(str(value).ljust(widths[i]) for i, value in enumerate(row))

    return "\n".join(
        [fmt(headers), fmt(["-" * w for w in widths])] + [fmt(row) for row in rows]
    )


def command_show(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)

    if args.target:
        path = script_path_for_target(api_alias, args.target)
        if args.path_only:
            print(path)
            return 0
        print(path.read_text(encoding="utf-8", errors="replace"), end="")
        return 0

    rows: list[list[str]] = []
    aliases = read_aliases(api_alias).get("aliases", {})
    eps = read_endpoints(api_alias).get("endpoints", {})
    alias_to_ep = (
        {
            str(v.get("endpoint_id")): k
            for k, v in aliases.items()
            if isinstance(v, dict) and v.get("endpoint_id")
        }
        if isinstance(aliases, dict)
        else {}
    )

    if isinstance(eps, dict):
        for ep_id, ep in sorted(eps.items()):
            if not isinstance(ep, dict):
                continue
            if not args.all and not (ep.get("alias") or ep_id in alias_to_ep):
                continue
            rows.append(
                [
                    str(ep_id),
                    str(ep.get("alias") or alias_to_ep.get(ep_id, "")),
                    str(ep.get("source") or ""),
                    str(ep.get("mode") or ""),
                    str(ep.get("method") or ""),
                    str(ep.get("path") or ""),
                    str(ep.get("auth") or ""),
                    str(ep.get("file_path") or ""),
                ]
            )

    # Include aliases that point to external files/not endpoint records.
    if isinstance(aliases, dict):
        known_eps = {str(row[0]) for row in rows}
        for name, entry in sorted(aliases.items()):
            if not isinstance(entry, dict):
                continue
            ep_id = str(entry.get("endpoint_id") or "")
            if ep_id and ep_id in known_eps:
                continue
            rows.append(
                [
                    ep_id,
                    str(name),
                    str(entry.get("source") or "external"),
                    str(entry.get("mode") or ""),
                    str(entry.get("method") or ""),
                    str(entry.get("path") or ""),
                    str(entry.get("auth") or ""),
                    str(entry.get("file_path") or ""),
                ]
            )

    if not rows:
        print(f"No endpoints or aliases found for {api_alias}.")
        print(f"Add one with: curlapi add {api_alias}")
        return 0
    print(
        format_table(
            rows, ["id", "alias", "source", "mode", "method", "path", "auth", "file"]
        )
    )
    return 0


def script_path_for_target(api_alias: str, target: str) -> Path:
    if target.startswith("ep_"):
        ep = find_endpoint_record(api_alias, target)
        return Path(str(ep["file_path"])).expanduser()
    entry = find_alias_entry(api_alias, target)
    return Path(str(entry["file_path"])).expanduser()


def command_edit(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    target = (
        validate_name(args.target, "Request alias")
        if args.target
        else choose_request_alias(api_alias)
    )
    path = script_path_for_target(api_alias, target)
    if not path.exists():
        raise RuntimeError(f"Script file does not exist: {path}")
    open_in_editor(path, editor=args.editor)
    return 0


def docs_cache_date_for_ls(api_alias: str) -> str:
    cache = read_json(cache_path(api_alias), None)
    if not isinstance(cache, dict):
        return "none"
    fetched_at = str(cache.get("fetched_at") or "")
    if not fetched_at:
        return "unknown"
    try:
        dt = datetime.fromisoformat(fetched_at.replace("Z", "+00:00"))
        return dt.strftime("%d-%m-%Y")
    except ValueError:
        return fetched_at[:10] or "unknown"


def command_ls(args: argparse.Namespace) -> int:
    root = config_root() / "apis"
    if not root.exists():
        print(f"No curlapi APIs found under {root}.")
        return 0
    found = False
    for path in sorted(root.iterdir()):
        if not path.is_dir() or not (path / "config.json").exists():
            continue
        api_alias = path.name
        config = read_json(path / "config.json", {})
        if not isinstance(config, dict):
            continue
        aliases = read_aliases(api_alias).get("aliases", {})
        alias_count = len(aliases) if isinstance(aliases, dict) else 0
        watch = "on" if watch_enabled(api_alias) else "off"
        base_url = str(config.get("base_url") or "")
        compact_url = re.sub(r"^https?://", "", base_url)
        print(
            f"{api_alias:<8} {compact_url} docs cache {docs_cache_date_for_ls(api_alias)}, endpoint alias count: {alias_count}. Watch: {watch}"
        )
        found = True
    if not found:
        print(f"No curlapi APIs found under {root}.")
    return 0


def command_drop_ep(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ep_id = validate_name(args.endpoint_id, "Endpoint id")
    data = read_endpoints(api_alias)
    ep = find_endpoint_record(api_alias, ep_id)
    if not ask_yes_no(
        f"Drop endpoint {ep_id} ({ep.get('method')} {ep.get('path')})?", default=False
    ):
        print("Cancelled.")
        return 1
    path = Path(str(ep.get("file_path") or "")).expanduser()
    data["endpoints"].pop(ep_id, None)
    write_endpoints(api_alias, data)

    aliases = read_aliases(api_alias)
    removed_aliases = []
    for name, entry in list(aliases.get("aliases", {}).items()):
        if isinstance(entry, dict) and entry.get("endpoint_id") == ep_id:
            aliases["aliases"].pop(name, None)
            removed_aliases.append(name)
    write_aliases(api_alias, aliases)

    if path.exists() and ask_yes_no(f"Remove script file too? {path}", default=False):
        path.unlink(missing_ok=True)

    print(f"Dropped endpoint: {ep_id}")
    if removed_aliases:
        print("Removed aliases: " + ", ".join(removed_aliases))
    return 0


def command_drop_alias(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    request_alias = validate_name(args.request_alias, "Request alias")
    data = read_aliases(api_alias)
    if request_alias not in data.get("aliases", {}):
        print(f"No alias named {request_alias} for {api_alias}.")
        return 0
    data["aliases"].pop(request_alias, None)
    write_aliases(api_alias, data)
    eps = read_endpoints(api_alias)
    for ep in eps.get("endpoints", {}).values():
        if isinstance(ep, dict) and ep.get("alias") == request_alias:
            ep["alias"] = None
    write_endpoints(api_alias, eps)
    print(f"Removed alias: {api_alias} {request_alias}")
    return 0


def command_watch(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    write_json(
        watch_path(api_alias),
        {
            "enabled": True,
            "capture_output": not args.no_output,
            "updated_at": utc_now(),
        },
    )
    print(f"Watching {api_alias}. Capture output: {'no' if args.no_output else 'yes'}")
    return 0


def command_drop_watch(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    write_json(watch_path(api_alias), {"enabled": False, "updated_at": utc_now()})
    print(f"Stopped watching {api_alias}. History kept.")
    return 0


def command_history(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    records = history_records(api_alias)

    if args.target and re.fullmatch(r"[0-9a-f]{8}", args.target):
        match = next((r for r in records if r.get("id") == args.target), None)
        if not match:
            raise RuntimeError(f"No history record found: {args.target}")
        body_path = match.get("body_path")
        if not body_path:
            print(json.dumps(match, indent=2))
            return 0
        print(
            Path(str(body_path)).read_text(encoding="utf-8", errors="replace"), end=""
        )
        return 0

    if args.target:
        records = [r for r in records if r.get("request_alias") == args.target]
    if args.status:
        records = [r for r in records if str(r.get("http_status")) == args.status]
    if args.method:
        records = [
            r for r in records if str(r.get("method")).upper() == args.method.upper()
        ]
    if args.contains:
        records = [r for r in records if args.contains.lower() in json.dumps(r).lower()]

    records = records[-args.limit :]

    if args.full:
        for r in records:
            print(
                f"\n===== {r.get('id')} {r.get('timestamp')} {r.get('request_alias') or ''} {r.get('method') or ''} {r.get('path') or r.get('url') or ''} status={r.get('http_status')} ====="
            )
            body_path = r.get("body_path")
            if body_path and Path(str(body_path)).exists():
                print(
                    Path(str(body_path)).read_text(encoding="utf-8", errors="replace"),
                    end="",
                )
                if not str(
                    Path(str(body_path)).read_text(encoding="utf-8", errors="replace")
                ).endswith("\n"):
                    print()
            else:
                print("(no captured body)")
        return 0

    rows = [
        [
            str(r.get("id", "")),
            str(r.get("timestamp", "")),
            str(r.get("kind", "")),
            str(r.get("request_alias") or ""),
            str(r.get("method") or ""),
            str(r.get("http_status") or ""),
            str(r.get("exit_code") if r.get("exit_code") is not None else ""),
            str(r.get("path") or r.get("url") or ""),
            (
                json.dumps(r.get("query_overrides", {}), sort_keys=True)
                if r.get("query_overrides")
                else ""
            ),
            (
                json.dumps(r.get("body_overrides", {}), sort_keys=True)
                if r.get("body_overrides")
                else ""
            ),
        ]
        for r in records
    ]
    if rows:
        print(
            format_table(
                rows,
                [
                    "id",
                    "timestamp",
                    "kind",
                    "alias",
                    "method",
                    "status",
                    "exit",
                    "target",
                    "query",
                    "body",
                ],
            )
        )
    else:
        print(f"No history for {api_alias}.")
    return 0


def command_drop_history(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    if not history_dir(api_alias).exists():
        print(f"No history found for {api_alias}.")
        return 0
    if not ask_yes_no(f"Remove all history for {api_alias}?", default=False):
        print("Cancelled.")
        return 1
    shutil.rmtree(history_dir(api_alias))
    print(f"Removed history for {api_alias}.")
    return 0


def command_drop_files(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    if not ask_yes_no(
        f"Remove scripts, endpoint records and aliases for {api_alias}?", default=False
    ):
        print("Cancelled.")
        return 1
    if scripts_dir(api_alias).exists():
        shutil.rmtree(scripts_dir(api_alias))
    write_aliases(
        api_alias, {"schema_version": 1, "aliases": {}, "created_at": utc_now()}
    )
    write_endpoints(
        api_alias, {"schema_version": 1, "endpoints": {}, "created_at": utc_now()}
    )
    print(f"Removed scripts/endpoints/aliases for {api_alias}.")
    return 0


def command_rm(args: argparse.Namespace) -> int:
    if args.all:
        root = config_root()
        if not root.exists():
            print(f"No curlapi config found: {root}")
            return 0
        if not ask_yes_no(
            f"Factory reset curlapi and remove all files under {root}?", default=False
        ):
            print("Cancelled.")
            return 1
        shutil.rmtree(root)
        print(f"Removed: {root}")
        return 0
    if not args.alias:
        raise RuntimeError("Pass an API alias or --all.")
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    if not ask_yes_no(
        f"Remove API alias {api_alias} and all associated curlapi files?", default=False
    ):
        print("Cancelled.")
        return 1
    shutil.rmtree(api_root(api_alias))
    print(f"Removed API alias: {api_alias}")
    return 0


def command_export(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    ensure_api_exists(api_alias)
    root = api_root(api_alias)
    files: dict[str, str] = {}
    for path in root.rglob("*"):
        if path.is_file():
            files[str(path.relative_to(root))] = path.read_text(
                encoding="utf-8", errors="replace"
            )
    out = {
        "schema_version": 1,
        "exported_at": utc_now(),
        "api_alias": api_alias,
        "files": files,
    }
    Path(args.file).expanduser().write_text(
        json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Exported {api_alias} to {Path(args.file).expanduser()}")
    return 0


def command_import(args: argparse.Namespace) -> int:
    api_alias = validate_name(args.alias, "API alias")
    target = api_root(api_alias)
    if target.exists() and not args.force:
        if not ask_yes_no(
            f"Import will overwrite existing {api_alias}. Continue?", default=False
        ):
            print("Cancelled.")
            return 1
        shutil.rmtree(target)
    data = json.loads(Path(args.file).expanduser().read_text(encoding="utf-8"))
    files = data.get("files", {})
    if not isinstance(files, dict):
        raise RuntimeError("Invalid export file.")
    for rel, content in files.items():
        path = target / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(content), encoding="utf-8", newline="\n")
        if rel.startswith("scripts/") and rel.endswith(".sh"):
            try:
                path.chmod(0o700)
            except OSError:
                pass
    print(f"Imported {api_alias} from {Path(args.file).expanduser()}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=Path(sys.argv[0]).name,
        description="Manage API curl scripts, OpenAPI caches, aliases, and request history.",
    )
    parser.add_argument("--version", action="store_true", help="Show version and exit.")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("init", help="Register an API base URL.")
    p.add_argument("alias")
    p.add_argument("url")
    p.add_argument("--path", help="OpenAPI JSON path. Default: /openapi.json")
    p.set_defaults(func=command_init)

    p = sub.add_parser("config", help="View or update API config.")
    p.add_argument("alias")
    p.add_argument("--url", help="Replace stored base URL.")
    p.add_argument("--path", help="Replace stored OpenAPI JSON path.")
    p.add_argument(
        "--prod", action="store_true", help="Require confirmation before docs/add/run."
    )
    p.add_argument(
        "--no-prod", action="store_true", help="Disable production confirmation."
    )
    p.set_defaults(func=command_config)

    p = sub.add_parser("docs", help="Fetch/update OpenAPI cache only.")
    p.add_argument("alias")
    p.add_argument(
        "--read-only",
        action="store_true",
        help="Show cached docs metadata without fetching.",
    )
    p.add_argument(
        "--list", action="store_true", help="With --read-only, list cached endpoints."
    )
    p.add_argument(
        "--path",
        help="OpenAPI JSON path or full URL. Default from config: /openapi.json",
    )
    p.add_argument(
        "--header",
        action="append",
        default=[],
        help="Temporary header for docs fetch. Not stored.",
    )
    p.set_defaults(func=command_docs)

    p = sub.add_parser("drop-docs", help="Remove cached OpenAPI docs.")
    p.add_argument("alias")
    p.set_defaults(func=command_drop_docs)

    p = sub.add_parser(
        "add", help="Create a curl script from cached docs, or manually from a path."
    )
    p.add_argument("alias")
    p.add_argument(
        "endpoint_path",
        nargs="?",
        help="Manual path. Omit to use cached docs endpoint picker.",
    )
    p.add_argument(
        "--endpoint", help="Docs endpoint path to use directly, e.g. /workflow/run."
    )
    p.add_argument("--method", default="GET", choices=sorted(HTTP_METHODS))
    p.add_argument("--name", help="Custom generated script filename slug.")
    p.add_argument(
        "--alias",
        dest="alias_name",
        help="Assign a request alias to the generated file.",
    )
    p.add_argument(
        "--flex",
        "--flexible",
        dest="flexible",
        action="store_true",
        help="Generate a parameterised script that supports run --query and JSON --body overrides.",
    )
    p.add_argument(
        "--auth",
        choices=sorted(AUTH_MODES),
        default="none",
        help="Add an active auth header to the generated script. bearer uses ${API}_TOKEN; api-key uses ${API}_API_KEY.",
    )
    p.add_argument("--editor")
    p.add_argument("--no-open", action="store_true")
    p.add_argument("--no-prompt", action="store_true")
    p.set_defaults(func=command_add)

    p = sub.add_parser("drop-ep", help="Remove one endpoint record by id.")
    p.add_argument("alias")
    p.add_argument("endpoint_id")
    p.set_defaults(func=command_drop_ep)

    p = sub.add_parser("alias", help="Map a request alias to a curl script.")
    p.add_argument("alias")
    p.add_argument("request_alias")
    p.add_argument("file_path")
    p.set_defaults(func=command_alias)

    p = sub.add_parser("run", help="Run an aliased curl script.")
    p.add_argument("alias")
    p.add_argument(
        "request_alias", nargs="?", help="Request alias. Omit for interactive selector."
    )
    p.add_argument(
        "--query",
        action="append",
        default=[],
        help="Runtime query value for flex scripts, name=value. Repeatable.",
    )
    p.add_argument(
        "--body",
        action="append",
        default=[],
        help="Runtime JSON body override for 0.5 flex scripts, name=value. Repeatable. Dot paths are supported.",
    )
    p.add_argument(
        "--show",
        action="store_true",
        help="Show the final curl command without making the request.",
    )
    p.set_defaults(func=command_run)

    p = sub.add_parser("edit", help="Open an aliased curl script in $EDITOR.")
    p.add_argument("alias")
    p.add_argument(
        "target",
        nargs="?",
        help="Request alias or endpoint id. Omit for interactive selector.",
    )
    p.add_argument("--editor")
    p.set_defaults(func=command_edit)

    p = sub.add_parser("ls", help="List registered API URL aliases.")
    p.set_defaults(func=command_ls)

    p = sub.add_parser("show", help="Show endpoints/aliases, or a script body.")
    p.add_argument("alias")
    p.add_argument("target", nargs="?", help="Request alias or endpoint id.")
    p.add_argument(
        "--all", action="store_true", help="Show unaliased endpoint files too."
    )
    p.add_argument(
        "--path-only",
        action="store_true",
        help="For a target, print only the script path.",
    )
    p.set_defaults(func=command_show)

    p = sub.add_parser("drop-alias", help="Remove a request alias.")
    p.add_argument("alias")
    p.add_argument("request_alias")
    p.set_defaults(func=command_drop_alias)

    p = sub.add_parser("watch", help="Enable request history for docs/run.")
    p.add_argument("alias")
    p.add_argument(
        "--no-output",
        action="store_true",
        help="Track metadata/status only, not full response bodies.",
    )
    p.set_defaults(func=command_watch)

    p = sub.add_parser(
        "drop-watch", help="Disable request history while keeping existing history."
    )
    p.add_argument("alias")
    p.set_defaults(func=command_drop_watch)

    p = sub.add_parser(
        "history", help="Show request history, or stored response bodies."
    )
    p.add_argument("alias")
    p.add_argument("target", nargs="?", help="History id or request alias.")
    p.add_argument("--full", action="store_true")
    p.add_argument("--status")
    p.add_argument("--method")
    p.add_argument("--contains")
    p.add_argument("--limit", type=int, default=50)
    p.set_defaults(func=command_history)

    p = sub.add_parser("drop-history", help="Remove all history for an API alias.")
    p.add_argument("alias")
    p.set_defaults(func=command_drop_history)

    p = sub.add_parser(
        "drop-files",
        help="Remove generated/manual scripts and aliases for an API alias.",
    )
    p.add_argument("alias")
    p.set_defaults(func=command_drop_files)

    p = sub.add_parser("rm", help="Remove one API alias, or reset curlapi with --all.")
    p.add_argument("alias", nargs="?")
    p.add_argument("--all", action="store_true")
    p.set_defaults(func=command_rm)

    p = sub.add_parser(
        "export", help="Export config, cache, aliases, endpoints, and scripts."
    )
    p.add_argument("alias")
    p.add_argument("file")
    p.set_defaults(func=command_export)

    p = sub.add_parser("import", help="Import exported curlapi data for an API alias.")
    p.add_argument("alias")
    p.add_argument("file")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=command_import)

    p = sub.add_parser("version", help="Show version.")
    p.set_defaults(func=lambda args: print(APP_VERSION) or 0)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.version:
        print(APP_VERSION)
        return 0
    if not hasattr(args, "func"):
        parser.print_help()
        return 1
    try:
        return int(args.func(args) or 0)
    except KeyboardInterrupt:
        eprint("\nCancelled.")
        return 130
    except Exception as exc:
        eprint(f"{Path(sys.argv[0]).name}: error: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
