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
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode, urljoin, urlparse

HTTP_METHODS = {"get", "post", "put", "patch", "delete", "options", "head"}


@dataclass(frozen=True)
class Endpoint:
    method: str
    path: str
    summary: str
    operation: dict[str, Any]


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def normalise_base_url(url: str) -> str:
    url = url.strip()
    if not url:
        raise ValueError("Base URL is empty.")

    if url.endswith("/docs"):
        url = url.removesuffix("/docs")

    if url.endswith("/openapi.json"):
        url = url.removesuffix("/openapi.json")

    return url.rstrip("/")


def openapi_url_from_base(base_url: str) -> str:
    return f"{normalise_base_url(base_url)}/openapi.json"


def fetch_json(url: str, headers: list[str] | None = None) -> dict[str, Any]:
    request_headers = {
        "Accept": "application/json",
        "User-Agent": "apicurl/0.1",
    }

    for header in headers or []:
        key, value = split_header(header)
        request_headers[key] = expand_header_value(value)

    req = urllib.request.Request(url, headers=request_headers)

    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} while fetching {url}\n{body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not fetch {url}: {exc}") from exc

    try:
        data = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Response from {url} was not valid JSON.") from exc

    if not isinstance(data, dict):
        raise RuntimeError(f"Response from {url} was JSON, but not an object.")

    return data


def split_header(header: str) -> tuple[str, str]:
    if ":" not in header:
        raise ValueError(f"Header must look like 'Name: value': {header!r}")

    key, value = header.split(":", 1)
    key = key.strip()
    value = value.strip()

    if not key:
        raise ValueError(f"Header name is empty: {header!r}")

    return key, value


def expand_header_value(value: str) -> str:
    """
    Used only when fetching /openapi.json.

    The generated curl file preserves env vars literally, but fetching the schema
    may itself need auth. For that case, expand $VAR / ${VAR}.
    """
    return os.path.expandvars(value)


def collect_endpoints(openapi: dict[str, Any]) -> list[Endpoint]:
    paths = openapi.get("paths", {})
    if not isinstance(paths, dict):
        raise RuntimeError("OpenAPI document does not contain a valid 'paths' object.")

    endpoints: list[Endpoint] = []

    for path, path_item in paths.items():
        if not isinstance(path_item, dict):
            continue

        for method, operation in path_item.items():
            method_lower = method.lower()
            if method_lower not in HTTP_METHODS:
                continue

            if not isinstance(operation, dict):
                continue

            summary = str(
                operation.get("summary") or operation.get("operationId") or ""
            )

            endpoints.append(
                Endpoint(
                    method=method_upper(method_lower),
                    path=str(path),
                    summary=summary,
                    operation=operation,
                )
            )

    return sorted(endpoints, key=lambda item: (item.path, item.method))


def method_upper(method: str) -> str:
    return method.upper()


def show_endpoint_menu(endpoints: list[Endpoint]) -> Endpoint:
    if not endpoints:
        raise RuntimeError("No endpoints found in OpenAPI document.")

    print()
    print("Available endpoints")
    print("-------------------")

    for i, endpoint in enumerate(endpoints, start=1):
        summary = f" — {endpoint.summary}" if endpoint.summary else ""
        print(f"[{i:>2}] {endpoint.method:<6} {endpoint.path}{summary}")

    print()

    while True:
        choice = input("Select endpoint number: ").strip()

        if not choice:
            continue

        try:
            index = int(choice)
        except ValueError:
            print("Please enter a number.")
            continue

        if 1 <= index <= len(endpoints):
            return endpoints[index - 1]

        print(f"Please enter a number between 1 and {len(endpoints)}.")


def find_endpoint(
    endpoints: list[Endpoint],
    endpoint_path: str,
    method: str | None,
) -> Endpoint:
    matches = [
        endpoint
        for endpoint in endpoints
        if endpoint.path == endpoint_path
        and (method is None or endpoint.method == method.upper())
    ]

    if not matches:
        raise RuntimeError(
            f"No matching endpoint found for {method or '*'} {endpoint_path}"
        )

    if len(matches) > 1:
        methods = ", ".join(endpoint.method for endpoint in matches)
        raise RuntimeError(
            f"Multiple methods found for {endpoint_path}: {methods}. " "Pass --method."
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

    if "anyOf" in schema and isinstance(schema["anyOf"], list):
        non_null = [
            item
            for item in schema["anyOf"]
            if isinstance(item, dict) and item.get("type") != "null"
        ]
        if non_null:
            return schema_placeholder(openapi, non_null[0], depth + 1)

    if "oneOf" in schema and isinstance(schema["oneOf"], list) and schema["oneOf"]:
        first = schema["oneOf"][0]
        if isinstance(first, dict):
            return schema_placeholder(openapi, first, depth + 1)

    if "allOf" in schema and isinstance(schema["allOf"], list) and schema["allOf"]:
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

    if "enum" in schema and isinstance(schema["enum"], list) and schema["enum"]:
        return schema["enum"][0]

    schema_type = schema.get("type")

    if schema_type == "object" or "properties" in schema:
        properties = schema.get("properties", {})
        required = set(schema.get("required", []))

        if not isinstance(properties, dict):
            return {}

        out: dict[str, Any] = {}

        for key, value in properties.items():
            if not isinstance(value, dict):
                continue

            # Include required properties and optional properties in v0.1.
            # Optional fields are useful as editable prompts in the generated file.
            out[str(key)] = schema_placeholder(openapi, value, depth + 1)

        if not out and schema.get("additionalProperties"):
            return {"key": "value"}

        return out

    if schema_type == "array":
        items = schema.get("items", {})
        if isinstance(items, dict):
            return [schema_placeholder(openapi, items, depth + 1)]
        return []

    if schema_type == "integer":
        return 0

    if schema_type == "number":
        return 0.0

    if schema_type == "boolean":
        return False

    if schema_type == "string":
        fmt = schema.get("format")
        if fmt == "date":
            return "2026-06-25"
        if fmt == "date-time":
            return "2026-06-25T10:00:00"
        return "string"

    return "value"


def operation_parameters(operation: dict[str, Any]) -> list[dict[str, Any]]:
    params = operation.get("parameters", [])
    if not isinstance(params, list):
        return []

    return [param for param in params if isinstance(param, dict)]


def request_body_schema(
    openapi: dict[str, Any],
    operation: dict[str, Any],
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
        content_item = content.get(content_type)
        if isinstance(content_item, dict):
            schema = content_item.get("schema")
            if isinstance(schema, dict):
                return schema

    for content_item in content.values():
        if isinstance(content_item, dict):
            schema = content_item.get("schema")
            if isinstance(schema, dict):
                return schema

    return None


def curl_safe_single_quoted(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def curl_safe_double_quoted(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def path_param_names(path: str) -> list[str]:
    return re.findall(r"{([^{}]+)}", path)


def prompt_for_path_params(path: str, no_prompt: bool) -> dict[str, str]:
    values: dict[str, str] = {}

    for name in path_param_names(path):
        if no_prompt:
            values[name] = f"<{name}>"
        else:
            value = input(f"{name}: ").strip()
            values[name] = value or f"<{name}>"

    return values


def fill_path(path: str, values: dict[str, str]) -> str:
    out = path

    for key, value in values.items():
        out = out.replace("{" + key + "}", quote(value, safe=""))

    return out


def query_params_from_operation(
    operation: dict[str, Any],
    no_prompt: bool,
) -> dict[str, str]:
    query_params: dict[str, str] = {}

    for param in operation_parameters(operation):
        if param.get("in") != "query":
            continue

        name = str(param.get("name", "param"))
        required = bool(param.get("required", False))

        if no_prompt:
            if required:
                query_params[name] = f"<{name}>"
            continue

        label = f"{name}"
        label += " [required]" if required else " [optional]"
        value = input(f"{label}: ").strip()

        if value:
            query_params[name] = value
        elif required:
            query_params[name] = f"<{name}>"

    return query_params


def build_url(base_url: str, endpoint_path: str, query_params: dict[str, str]) -> str:
    url = f"{normalise_base_url(base_url)}{endpoint_path}"

    if query_params:
        url += "?" + urlencode(query_params)

    return url


def operation_content_type(operation: dict[str, Any]) -> str | None:
    request_body = operation.get("requestBody")
    if not isinstance(request_body, dict):
        return None

    content = request_body.get("content", {})
    if not isinstance(content, dict) or not content:
        return None

    if "application/json" in content:
        return "application/json"

    return str(next(iter(content.keys())))


def endpoint_slug(endpoint: Endpoint) -> str:
    raw = f"{endpoint.method.lower()}_{endpoint.path.strip('/') or 'root'}"
    raw = raw.replace("{", "").replace("}", "")
    raw = re.sub(r"[^A-Za-z0-9]+", "_", raw)
    return raw.strip("_").lower() or "request"


def safe_api_name(base_url: str) -> str:
    parsed = urlparse(base_url)
    host = parsed.netloc or "api"
    path = parsed.path.strip("/")

    raw = host
    if path:
        raw += "_" + path

    raw = re.sub(r"[^A-Za-z0-9]+", "_", raw)
    return raw.strip("_").lower() or "api"


def default_output_dir(base_url: str) -> Path:
    return Path.home() / "api_calls" / safe_api_name(base_url)


def make_script(
    openapi: dict[str, Any],
    base_url: str,
    endpoint: Endpoint,
    headers: list[str],
    no_prompt: bool,
) -> str:
    path_values = prompt_for_path_params(endpoint.path, no_prompt=no_prompt)
    endpoint_path = fill_path(endpoint.path, path_values)
    query_params = query_params_from_operation(endpoint.operation, no_prompt=no_prompt)
    request_url = build_url(base_url, endpoint_path, query_params)

    content_type = operation_content_type(endpoint.operation)

    schema = request_body_schema(openapi, endpoint.operation)
    payload: Any | None = None

    if schema is not None:
        payload = schema_placeholder(openapi, schema)

    lines: list[str] = [
        "#!/usr/bin/env bash",
        "set -Eeuo pipefail",
        "",
        "# Generated by apicurl.",
        "# Edit this file, then run it with bash or send blocks to a shell REPL.",
        "",
    ]

    curl_parts = [
        f"curl -X {endpoint.method} {curl_safe_double_quoted(request_url)}",
    ]

    for header in headers:
        curl_parts.append(f"  -H {curl_safe_single_quoted(header)}")

    if content_type and not any(h.lower().startswith("content-type:") for h in headers):
        curl_parts.append(
            f"  -H {curl_safe_single_quoted(f'Content-Type: {content_type}')}"
        )

    if payload is not None:
        curl_parts.append("  --data @- <<'JSON'")

    for i, part in enumerate(curl_parts):
        suffix = " \\" if i < len(curl_parts) - 1 else ""
        lines.append(f"{part}{suffix}")

    if payload is not None:
        lines.append(json.dumps(payload, indent=2))
        lines.append("JSON")

    lines.extend(
        [
            "",
            "",
            "# ---- OpenAPI notes ---------------------------------------------------------",
            "#",
            f"# API title: {openapi.get('info', {}).get('title', '')}",
            f"# API version: {openapi.get('info', {}).get('version', '')}",
            f"# Endpoint: {endpoint.method} {endpoint.path}",
            f"# Summary: {endpoint.summary}",
            "#",
        ]
    )

    params = operation_parameters(endpoint.operation)
    if params:
        lines.append("# Parameters:")
        for param in params:
            name = param.get("name", "")
            location = param.get("in", "")
            required = param.get("required", False)
            description = str(param.get("description", "")).replace("\n", " ")
            lines.append(
                f"#   - {name} ({location}, required={required}) {description}"
            )
        lines.append("#")

    if headers:
        lines.append("# Headers included:")
        for header in headers:
            key, value = split_header(header)
            lines.append(f"#   - {key}: {value}")
        lines.append("#")

    if schema is not None:
        lines.append("# Request body template:")
        for line in json.dumps(payload, indent=2).splitlines():
            lines.append(f"#   {line}")
        lines.append("#")

    responses = endpoint.operation.get("responses", {})
    if isinstance(responses, dict) and responses:
        lines.append("# Responses:")
        for status_code, response in responses.items():
            description = ""
            if isinstance(response, dict):
                description = str(response.get("description", ""))
            lines.append(f"#   - {status_code}: {description}")

    lines.append("")

    return "\n".join(lines)


def write_script(
    script: str,
    output_dir: Path,
    endpoint: Endpoint,
) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    filename = f"{timestamp}_{endpoint_slug(endpoint)}.sh"
    path = output_dir / filename

    path.write_text(script, encoding="utf-8", newline="\n")

    try:
        path.chmod(0o700)
    except OSError:
        # chmod may not behave normally on Windows filesystems.
        pass

    return path


def open_in_editor(path: Path, editor: str | None) -> None:
    selected_editor = (
        editor
        or os.environ.get("EDITOR")
        or shutil.which("nvim")
        or shutil.which("vim")
        or shutil.which("code")
        or default_platform_editor()
    )

    if selected_editor is None:
        print(f"Created: {path}")
        print("No editor found. Open the file manually.")
        return

    cmd = selected_editor.split() + [str(path)]

    try:
        subprocess.run(cmd, check=False)
    except FileNotFoundError:
        print(f"Created: {path}")
        print(f"Could not find editor: {selected_editor}")


def default_platform_editor() -> str | None:
    if platform.system() == "Windows":
        return "notepad"
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="apicurl",
        description="Generate editable curl scratchpad scripts from an OpenAPI/FastAPI API.",
    )

    parser.add_argument(
        "base_url",
        help="Base API URL, /docs URL, or /openapi.json URL.",
    )

    parser.add_argument(
        "--header",
        action="append",
        default=[],
        help=(
            "Header to include. Repeatable. "
            "Example: --header 'Authorization: Bearer $TOKEN'"
        ),
    )

    parser.add_argument(
        "--method",
        choices=sorted(method_upper(x) for x in HTTP_METHODS),
        help="HTTP method to select when using --endpoint.",
    )

    parser.add_argument(
        "--endpoint",
        help="Endpoint path to use directly, e.g. /workflow/run. Skips menu.",
    )

    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory to save generated scripts. Default: ~/api_calls/<api-name>",
    )

    parser.add_argument(
        "--editor",
        help="Editor command. Default: $EDITOR, nvim, vim, code, then notepad on Windows.",
    )

    parser.add_argument(
        "--no-open",
        action="store_true",
        help="Create the file but do not open it.",
    )

    parser.add_argument(
        "--no-prompt",
        action="store_true",
        help="Do not prompt for path/query params; use placeholders instead.",
    )

    parser.add_argument(
        "--list",
        action="store_true",
        help="List endpoints and exit.",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        base_url = normalise_base_url(args.base_url)
        schema_url = openapi_url_from_base(base_url)

        openapi = fetch_json(schema_url, headers=args.header)
        endpoints = collect_endpoints(openapi)

        if args.list:
            for endpoint in endpoints:
                summary = f" — {endpoint.summary}" if endpoint.summary else ""
                print(f"{endpoint.method:<6} {endpoint.path}{summary}")
            return 0

        if args.endpoint:
            endpoint = find_endpoint(
                endpoints=endpoints,
                endpoint_path=args.endpoint,
                method=args.method,
            )
        else:
            endpoint = show_endpoint_menu(endpoints)

        script = make_script(
            openapi=openapi,
            base_url=base_url,
            endpoint=endpoint,
            headers=args.header,
            no_prompt=args.no_prompt,
        )

        output_dir = args.output_dir or default_output_dir(base_url)
        path = write_script(script, output_dir, endpoint)

        print(f"Created: {path}")

        if not args.no_open:
            open_in_editor(path, editor=args.editor)

        return 0

    except KeyboardInterrupt:
        eprint("\nCancelled.")
        return 130
    except Exception as exc:
        eprint(f"apicurl: error: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
