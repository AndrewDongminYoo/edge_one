#!/usr/bin/env python3
"""Generate the narrow Dart and TypeScript contract surface from one JSON Schema."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas/system-one-v1.schema.json"
OUTPUTS = {
    "dart": ROOT / "packages/edge_one/lib/src/generated/system_one_v1.dart",
    "ts": ROOT / "packages/react-native-edge-one/src/generated/system-one-v1.ts",
}
QUESTION_NAMES = ("ChoiceQuestion", "ScoreQuestion", "NoulQuestion")
ANSWER_NAMES = ("ChoiceAnswer", "ScoreAnswer", "NoulAnswer")
ROOT_NAMES = ("Usage", "SystemOneRequest", "SystemOneResponse")


def reference_name(value: dict) -> str:
    reference = value.get("$ref")
    if not isinstance(reference, str) or not reference.startswith("#/definitions/"):
        raise ValueError(f"Unsupported reference: {reference!r}")
    return reference.rsplit("/", 1)[1]


def ts_type(value: dict) -> str:
    if "$ref" in value:
        name = reference_name(value)
        return "unknown" if name == "JsonValue" else name
    if "const" in value:
        return json.dumps(value["const"])
    if "enum" in value:
        return " | ".join(json.dumps(item) for item in value["enum"])
    if "oneOf" in value or "anyOf" in value:
        return " | ".join(
            ts_type(item) for item in value.get("oneOf", value.get("anyOf"))
        )
    kind = value.get("type")
    if kind == "string":
        return "string"
    if kind in ("number", "integer"):
        return "number"
    if kind == "boolean":
        return "boolean"
    if kind == "null":
        return "null"
    if kind == "array":
        item_type = ts_type(value["items"])
        if value.get("minItems") == 1:
            return f"[{item_type}, ...{item_type}[]]"
        return f"{item_type}[]"
    if kind == "object":
        properties = value.get("properties", {})
        if properties:
            required = set(value.get("required", []))
            fields = [
                f"  {name}{'' if name in required else '?'}: {ts_type(field)};"
                for name, field in properties.items()
            ]
            if value.get("patternProperties"):
                patterns = value["patternProperties"]
                if set(patterns) != {"^x_"}:
                    raise ValueError(f"Unsupported patternProperties: {patterns}")
                fields.append("  [key: `x_${string}`]: unknown;")
            return "{\n" + "\n".join(fields) + "\n}"
        if "additionalProperties" in value and isinstance(
            value["additionalProperties"], dict
        ):
            if "propertyNames" in value:
                allowed = value["propertyNames"].get("enum")
                if not allowed or not all(isinstance(name, str) for name in allowed):
                    raise ValueError(
                        f"Unsupported propertyNames: {value['propertyNames']}"
                    )
                names = " | ".join(json.dumps(name) for name in allowed)
                item_type = ts_type(value["additionalProperties"])
                return f"Partial<Record<{names}, {item_type}>>"
            return f"Record<string, {ts_type(value['additionalProperties'])}>"
        if value.get("additionalProperties") is True:
            return "Record<string, unknown>"
        if value.get("additionalProperties") is False:
            return "Record<string, never>"
        raise ValueError(f"Unsupported object shape: {value}")
    if not value or set(value) == {"description"}:
        return "unknown"
    raise ValueError(f"Unsupported schema type: {value}")


def dart_type(value: dict) -> str:
    if "$ref" in value:
        return reference_name(value)
    if "const" in value or "enum" in value or value.get("type") == "string":
        return "String"
    if "oneOf" in value:
        names = {reference_name(item) for item in value["oneOf"]}
        if names == set(QUESTION_NAMES):
            return "SystemOneQuestion"
        if names == set(ANSWER_NAMES):
            return "SystemOneAnswer"
        raise ValueError(f"Unsupported Dart union: {names}")
    if "anyOf" in value:
        options = value["anyOf"]
        if len(options) == 2 and options[1].get("type") == "null":
            return f"{dart_type(options[0])}?"
        raise ValueError(f"Unsupported Dart anyOf: {options}")
    kind = value.get("type")
    if kind == "number":
        return "double"
    if kind == "integer":
        return "int"
    if kind == "boolean":
        return "bool"
    if kind == "array":
        return f"List<{dart_type(value['items'])}>"
    if kind == "object":
        if "properties" in value:
            raise ValueError("Nested Dart object properties need a named definition")
        extra = value.get("additionalProperties")
        if isinstance(extra, dict):
            return f"Map<String, {dart_type(extra)}>"
        if extra is True:
            return "Map<String, JsonValue>"
        raise ValueError(f"Unsupported Dart object: {value}")
    if not value or set(value) == {"description"}:
        return "JsonValue"
    raise ValueError(f"Unsupported Dart type: {value}")


def render_ts(definitions: dict, digest: str) -> str:
    lines = [
        "// Generated from schemas/system-one-v1.schema.json.",
        f"// Schema SHA-256: {digest}",
        "// Do not edit. Run: python3 tools/generate_contracts.py",
        "",
        "export type StructuredValue = "
        + ts_type(definitions["StructuredValue"])
        + ";",
        "export type OptionalStructuredValue = "
        + ts_type(definitions["OptionalStructuredValue"])
        + ";",
        "",
    ]
    for name in (*QUESTION_NAMES, *ANSWER_NAMES, *ROOT_NAMES):
        lines.append(f"export type {name} = {ts_type(definitions[name])};")
        lines.append("")
    lines.extend(
        [
            "export type SystemOneQuestion = ChoiceQuestion | ScoreQuestion | NoulQuestion;",
            "export type SystemOneAnswer = ChoiceAnswer | ScoreAnswer | NoulAnswer;",
            "export type SystemOneV1 = SystemOneRequest | SystemOneResponse;",
            "",
        ]
    )
    return "\n".join(lines)


def render_dart(definitions: dict, digest: str) -> str:
    lines = [
        "// Generated from schemas/system-one-v1.schema.json.",
        f"// Schema SHA-256: {digest}",
        "// Do not edit. Run: python3 tools/generate_contracts.py",
        "",
        "typedef JsonValue = Object?;",
        "typedef StructuredValue = Object;",
        "typedef OptionalStructuredValue = Object?;",
        "",
        "sealed class SystemOneQuestion {",
        "  const SystemOneQuestion();",
        "}",
        "",
        "sealed class SystemOneAnswer {",
        "  const SystemOneAnswer();",
        "}",
        "",
    ]
    for name in (*QUESTION_NAMES, *ANSWER_NAMES, *ROOT_NAMES):
        definition = definitions[name]
        properties = definition["properties"]
        required = set(definition.get("required", []))
        base = (
            "SystemOneQuestion"
            if name in QUESTION_NAMES
            else "SystemOneAnswer" if name in ANSWER_NAMES else None
        )
        lines.append(f"final class {name}{f' extends {base}' if base else ''} {{")
        has_extensions = definition.get("patternProperties") == {
            "^x_": {"$ref": "#/definitions/JsonValue"}
        }
        for field_name, field in properties.items():
            if "const" in field:
                lines.append(
                    f"  String get {field_name} => {json.dumps(field['const'])};"
                )
                continue
            field_type = dart_type(field)
            if (
                field_name not in required
                and field_type not in {"JsonValue", "OptionalStructuredValue"}
                and not field_type.endswith("?")
            ):
                field_type += "?"
            lines.append(f"  final {field_type} {camel(field_name)};")
        if has_extensions:
            lines.append("  final Map<String, JsonValue> xExtensions;")
        lines.append("")
        fields = [
            field_name
            for field_name, field in properties.items()
            if "const" not in field
        ]
        if fields:
            arguments = []
            for field_name in fields:
                prefix = "required " if field_name in required else ""
                arguments.append(f"{prefix}this.{camel(field_name)}")
            if has_extensions:
                arguments.append("this.xExtensions = const {}")
            inline = f"  const {name}({{{', '.join(arguments)}}});"
            if len(inline) <= 80:
                lines.append(inline)
            else:
                lines.append(f"  const {name}({{")
                lines.extend(f"    {argument}," for argument in arguments)
                lines.append("  });")
        else:
            lines.append(f"  const {name}();")
        lines.extend(["}", ""])
    return "\n".join(lines)


def camel(value: str) -> str:
    parts = value.split("_")
    return parts[0] + "".join(part.capitalize() for part in parts[1:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="fail when generated files differ"
    )
    args = parser.parse_args()
    source = SCHEMA.read_bytes()
    schema = json.loads(source)
    definitions = schema["definitions"]
    expected = {
        "JsonValue",
        "StructuredValue",
        "OptionalStructuredValue",
        *QUESTION_NAMES,
        *ANSWER_NAMES,
        *ROOT_NAMES,
    }
    if set(definitions) != expected:
        raise ValueError(
            f"Unexpected schema definitions: {set(definitions) ^ expected}"
        )
    digest = hashlib.sha256(source).hexdigest()
    output = {
        "dart": render_dart(definitions, digest),
        "ts": render_ts(definitions, digest),
    }
    stale = []
    for language, target in OUTPUTS.items():
        rendered = output[language]
        if target.exists() and target.read_text() == rendered:
            continue
        if args.check:
            stale.append(str(target.relative_to(ROOT)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rendered)
            print(f"Generated {target.relative_to(ROOT)}")
    if stale:
        print("Generated contracts are missing or stale: " + ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
