"""Decode test JSON with Python's standard parser and emit a Lua data literal."""

import json
import math
import sys


def lua_literal(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return '"' + "".join(f"\\{byte:03d}" for byte in value.encode("utf-8")) + '"'
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            raise ValueError("non-finite number")
        return str(value)
    items = enumerate(value, 1) if isinstance(value, list) else value.items()
    return "{" + ",".join(f"[{lua_literal(key)}]={lua_literal(item)}" for key, item in items) + "}"


if __name__ == "__main__":
    try:
        print(lua_literal(json.loads(sys.argv[1])))
    except (ValueError, TypeError):
        sys.exit(1)
