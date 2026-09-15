"""Cross-language value identity used by the Lua NavigationData boundary.

This is an identity checksum, not a cryptographic authenticity mechanism.
Empty arrays and objects intentionally share an encoding because Factorio's
plain Lua tables do not preserve that distinction through storage and JSON.
"""

from __future__ import annotations

import math
import zlib


class CanonicalError(ValueError):
    pass


def canonical_bytes(value: object) -> bytes:
    active: set[int] = set()
    values = 0

    def encode(item: object, depth: int) -> bytes:
        nonlocal values
        values += 1
        if values > 1_000_000:
            raise CanonicalError("value count exceeds 1000000")
        if depth > 64:
            raise CanonicalError("value nesting exceeds 64")
        if item is None:
            return b"z;"
        if isinstance(item, bool):
            return b"b1;" if item else b"b0;"
        if isinstance(item, str):
            try:
                encoded = item.encode("utf-8", "strict")
            except UnicodeError as error:
                raise CanonicalError("invalid UTF-8 string") from error
            return b"s" + str(len(encoded)).encode("ascii") + b":" + encoded
        if isinstance(item, (int, float)):
            try:
                number = float(item)
            except OverflowError as error:
                raise CanonicalError("number is not a finite IEEE754 value") from error
            if not math.isfinite(number) or isinstance(item, int) and item != number:
                raise CanonicalError("number is not exactly representable as finite IEEE754")
            if number == 0:
                return b"n0p0;"
            numerator, denominator = number.as_integer_ratio()
            exponent = -(denominator.bit_length() - 1)
            while numerator % 2 == 0:
                numerator //= 2
                exponent += 1
            return f"n{numerator}p{exponent};".encode("ascii")
        if not isinstance(item, (list, dict)):
            raise CanonicalError("unsupported value type")
        if id(item) in active:
            raise CanonicalError("cyclic value")
        if not item:
            return b"e;"
        active.add(id(item))
        try:
            if isinstance(item, list):
                return (b"a" + str(len(item)).encode("ascii") + b":"
                        + b"".join(encode(child, depth + 1) for child in item))
            if not all(isinstance(key, str) for key in item):
                raise CanonicalError("object keys must be strings")
            try:
                keys = sorted(item, key=lambda key: key.encode("utf-8", "strict"))
            except UnicodeError as error:
                raise CanonicalError("invalid UTF-8 key") from error
            return (b"o" + str(len(keys)).encode("ascii") + b":"
                    + b"".join(encode(key, depth + 1) + encode(item[key], depth + 1)
                               for key in keys))
        finally:
            active.remove(id(item))

    encoded = encode(value, 0)
    if len(encoded) > 8 * 1024 * 1024:
        raise CanonicalError("canonical byte count exceeds 8 MiB")
    return encoded


def content_hash(value: object) -> str:
    encoded = canonical_bytes(value)
    return f"scv-c14n1-adler32:{zlib.adler32(encoded):08x}:{len(encoded)}"
