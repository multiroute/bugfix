"""Minimal JSON Schema validator covering the subset bugfix's schemas use.

Implements only what's exercised by `schemas/{events,run-state,config}.schema.json`:

  type (including union like ["string","null"]), enum, const,
  required, properties, additionalProperties (bool or schema),
  items, minLength, maxLength, minimum, maximum,
  allOf, anyOf, oneOf, not, if/then/else.

Metadata keywords ($schema, $id, title, description) are ignored.
`format` is recognised but NOT enforced — this matches stock `jsonschema`
behavior (format checking is opt-in via FormatChecker, which the prior
callers did not pass).

This module exists so the plugin's runtime has no PyPI dependency. If you
add a new JSON Schema keyword to any schema in this repo, extend this
validator to match.
"""


class ValidationError(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


def validate(instance, schema):
    """Validate `instance` against `schema`. Raises ValidationError on failure."""
    _validate(instance, schema, "$")


def _check_type(value, type_name):
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "null":
        return value is None
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "object":
        return isinstance(value, dict)
    if type_name == "array":
        return isinstance(value, list)
    raise ValidationError(f"unknown type in schema: {type_name!r}")


def _validate(instance, schema, path):
    if not isinstance(schema, dict):
        raise ValidationError(f"{path}: schema must be an object, got {type(schema).__name__}")

    if "type" in schema:
        t = schema["type"]
        types = t if isinstance(t, list) else [t]
        if not any(_check_type(instance, tn) for tn in types):
            raise ValidationError(f"{path}: {instance!r} is not of type {t!r}")

    if "enum" in schema:
        if instance not in schema["enum"]:
            raise ValidationError(f"{path}: {instance!r} is not one of {schema['enum']!r}")

    if "const" in schema:
        if instance != schema["const"]:
            raise ValidationError(f"{path}: {instance!r} != const {schema['const']!r}")

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise ValidationError(f"{path}: string shorter than minLength={schema['minLength']}")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            raise ValidationError(f"{path}: string longer than maxLength={schema['maxLength']}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValidationError(f"{path}: {instance} < minimum={schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise ValidationError(f"{path}: {instance} > maximum={schema['maximum']}")

    if isinstance(instance, dict):
        if "required" in schema:
            for key in schema["required"]:
                if key not in instance:
                    raise ValidationError(f"{path}: {key!r} is a required property")
        props = schema.get("properties", {})
        for key, value in instance.items():
            if key in props:
                _validate(value, props[key], f"{path}.{key}")
        ap = schema.get("additionalProperties", True)
        if ap is False:
            extras = [k for k in instance.keys() if k not in props]
            if extras:
                bad = sorted(extras)[0]
                raise ValidationError(
                    f"Additional properties are not allowed ({bad!r} was unexpected)"
                )
        elif isinstance(ap, dict):
            for key, value in instance.items():
                if key not in props:
                    _validate(value, ap, f"{path}.{key}")

    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            _validate(item, schema["items"], f"{path}[{i}]")

    if "allOf" in schema:
        for sub in schema["allOf"]:
            _validate(instance, sub, path)

    if "anyOf" in schema:
        if not any(_matches(instance, s, path) for s in schema["anyOf"]):
            raise ValidationError(f"{path}: value did not match any of anyOf schemas")

    if "oneOf" in schema:
        matches = sum(1 for s in schema["oneOf"] if _matches(instance, s, path))
        if matches != 1:
            raise ValidationError(
                f"{path}: expected exactly one oneOf match, got {matches}"
            )

    if "not" in schema:
        if _matches(instance, schema["not"], path):
            raise ValidationError(f"{path}: value matched 'not' schema")

    if "if" in schema:
        if _matches(instance, schema["if"], path):
            if "then" in schema:
                _validate(instance, schema["then"], path)
        else:
            if "else" in schema:
                _validate(instance, schema["else"], path)


def _matches(instance, schema, path):
    try:
        _validate(instance, schema, path)
        return True
    except ValidationError:
        return False
