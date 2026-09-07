"""Fail the guest build if its actual core Wasm imports widen the host ABI."""
import sys
from pathlib import Path


def number(data, offset):
    value = 0
    for shift in range(0, 35, 7):
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("invalid u32")


def string(data, offset):
    length, offset = number(data, offset)
    return data[offset:offset + length].decode("utf-8"), offset + length


def imports(data):
    assert data[:8] == b"\0asm\x01\0\0\0", "expected core Wasm v1"
    offset = 8
    found = []
    while offset < len(data):
        section = data[offset]
        size, start = number(data, offset + 1)
        offset = start + size
        if section != 2:
            continue
        count, at = number(data, start)
        for _ in range(count):
            module, at = string(data, at)
            name, at = string(data, at)
            assert data[at] == 0, "only function imports are allowed"
            _, at = number(data, at + 1)
            found.append((module, name))
        assert at == offset
    return found


if __name__ == "__main__":
    actual = imports(Path(sys.argv[1]).read_bytes())
    expected = {("max_v1", name) for name in
                ("tool_call", "input_size", "input_read", "output_write")}
    assert len(actual) == len(expected) and set(actual) == expected, actual
    print("codemode guest imports: Max ABI only")
