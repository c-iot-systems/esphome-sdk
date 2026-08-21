"""Unit tests for the Serial API wire protocol (AIOT-131, SER-1).

The protocol layer is C++ (it is the firmware's own lexer and formatters), so these tests compile it
with g++ into the host CLI (serial_api_cli.cpp) and drive that — they assert on the real firmware
code, not a Python re-implementation, which is the only way the test can prove the frozen grammar.
Only the standard library is used: g++ ships on the CI runner and `unittest`/`subprocess` are stdlib,
so nothing heavyweight is added.
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent
_PROTO_DIR = _REPO / "components" / "serial_api"

_CLI: Path | None = None
_TMPDIR: tempfile.TemporaryDirectory | None = None


def setUpModule() -> None:
    global _CLI, _TMPDIR
    _TMPDIR = tempfile.TemporaryDirectory()
    cli = Path(_TMPDIR.name) / "serial_api_cli"
    subprocess.run(
        [
            "g++",
            "-std=c++17",
            "-Wall",
            "-Werror",
            f"-I{_PROTO_DIR}",
            str(_HERE / "serial_api_cli.cpp"),
            str(_PROTO_DIR / "serial_api_protocol.cpp"),
            "-o",
            str(cli),
        ],
        check=True,
    )
    _CLI = cli


def tearDownModule() -> None:
    if _TMPDIR is not None:
        _TMPDIR.cleanup()


def _run(*args: str, stdin: bytes = b"") -> str:
    result = subprocess.run(
        [str(_CLI), *args], input=stdin, capture_output=True, check=True
    )
    return result.stdout.decode()


def _feed(data: bytes) -> list[dict]:
    """Feed a raw byte stream through the assembler+parser, one event per produced line."""
    out = _run("feed", stdin=data.hex().encode())
    events = []
    for line in out.splitlines():
        if line == "TOOLONG":
            events.append({"event": "TOOLONG"})
            continue
        fields = line.split("\t")
        rec = {"event": fields[0]}
        for f in fields[1:]:
            key, _, val = f.partition("=")
            rec[key] = val
        events.append(rec)
    return events


def _quote(raw: bytes) -> bytes:
    return bytes.fromhex(_run("quote", raw.hex()).strip())


def _expose(object_id: str, internal: bool) -> str:
    return _run("expose", object_id, "1" if internal else "0").strip()


def _setswitch(value: bytes) -> str:
    return _run("setswitch", value.hex()).strip()


def _setnumber(value: bytes, min_v: str, max_v: str) -> str:
    return _run("setnumber", value.hex(), min_v, max_v).strip()


def _settext(value: bytes, min_len: int, max_len: int) -> str:
    return _run("settext", value.hex(), str(min_len), str(max_len)).strip()


def _setselect(value: bytes, *options: bytes) -> str:
    return _run("setselect", value.hex(), *[o.hex() for o in options]).strip()


def _setbutton(value: bytes) -> str:
    return _run("setbutton", value.hex()).strip()


class LexerVerbTest(unittest.TestCase):
    def test_every_verb_is_recognised(self):
        cases = {
            b"LIST\n": ("LIST", "1"),
            b"SUB\n": ("SUB", "1"),
            b"UNSUB\n": ("UNSUB", "1"),
            b"PING\n": ("PING", "1"),
            b"HELLO\n": ("HELLO", "1"),
            b"GET switch/relay\n": ("GET", "1"),
            b"GET *\n": ("GET", "1"),
            b"SET switch/relay ON\n": ("SET", "1"),
        }
        for line, (verb, ok) in cases.items():
            events = _feed(line)
            self.assertEqual(len(events), 1, line)
            self.assertEqual(events[0]["verb"], verb, line)
            self.assertEqual(events[0]["ok"], ok, line)

    def test_get_address_is_split(self):
        (rec,) = _feed(b"GET sensor/temperature\n")
        self.assertEqual(rec["verb"], "GET")
        self.assertEqual(rec["type"], "sensor")
        self.assertEqual(rec["oid"], "temperature")
        self.assertEqual(rec["wc"], "0")

    def test_get_wildcard(self):
        (rec,) = _feed(b"GET *\n")
        self.assertEqual(rec["wc"], "1")

    def test_unknown_verb_is_parse_error(self):
        (rec,) = _feed(b"NOPE\n")
        self.assertEqual(rec["verb"], "UNKNOWN")
        self.assertEqual(rec["ok"], "0")
        self.assertEqual(rec["code"], "parse")

    def test_get_without_address_is_parse_error(self):
        (rec,) = _feed(b"GET\n")
        self.assertEqual(rec["ok"], "0")
        self.assertEqual(rec["code"], "parse")

    def test_get_with_malformed_address_is_parse_error(self):
        for line in (b"GET switch\n", b"GET /relay\n", b"GET switch/\n"):
            (rec,) = _feed(line)
            self.assertEqual(rec["ok"], "0", line)
            self.assertEqual(rec["code"], "parse", line)

    def test_invalid_utf8_in_address_is_parse_error(self):
        # An address is part of the UTF-8 line: a malformed-encoding address is ERR parse, not a
        # lookup miss. Covers both GET and SET address segments.
        for line in (b"GET sensor/\xff\n", b"SET \xffbad/x ON\n", b"GET \xc3/x\n"):
            (rec,) = _feed(line)
            self.assertEqual(rec["ok"], "0", line)
            self.assertEqual(rec["code"], "parse", line)

    def test_leading_space_is_ignored(self):
        (rec,) = _feed(b" PING\n")
        self.assertEqual(rec["verb"], "PING")
        self.assertEqual(rec["ok"], "1")

    def test_nullary_verbs_reject_trailing_fields(self):
        # A nullary verb takes no field; a trailing separator or payload is malformed.
        for line in (b"LIST x\n", b"PING \n", b"SUB x\n", b"UNSUB x\n", b"HELLO world\n"):
            (rec,) = _feed(line)
            self.assertEqual(rec["ok"], "0", line)
            self.assertEqual(rec["code"], "parse", line)


class SetValueGrammarTest(unittest.TestCase):
    def test_raw_value_preserves_inner_and_trailing_spaces(self):
        (rec,) = _feed(b"SET text/x ab  \n")
        self.assertEqual(rec["hasval"], "1")
        self.assertEqual(bytes.fromhex(rec["val"]), b"ab  ")

    def test_empty_value_two_spellings(self):
        # `SET <addr>` and `SET <addr> ` both mean the empty value.
        for line in (b"SET text/x\n", b"SET text/x \n"):
            (rec,) = _feed(line)
            self.assertEqual(rec["verb"], "SET", line)
            self.assertEqual(rec["ok"], "1", line)
            self.assertEqual(rec["hasval"], "1", line)
            self.assertEqual(rec["val"], "", line)

    def test_control_byte_in_value_is_bad_value(self):
        (rec,) = _feed(b"SET text/x a\x01b\n")
        self.assertEqual(rec["verb"], "SET")
        self.assertEqual(rec["ok"], "0")
        self.assertEqual(rec["code"], "bad-value")

    def test_set_needs_address(self):
        (rec,) = _feed(b"SET\n")
        self.assertEqual(rec["ok"], "0")
        self.assertEqual(rec["code"], "parse")

    def test_valid_utf8_value_is_accepted(self):
        # "café" — a valid two-byte UTF-8 sequence in the value.
        (rec,) = _feed("SET text/x café\n".encode("utf-8"))
        self.assertEqual(rec["ok"], "1")
        self.assertEqual(bytes.fromhex(rec["val"]), "café".encode("utf-8"))

    def test_invalid_utf8_value_is_bad_value(self):
        for bad in (b"\xff", b"\xc3", b"\xa9", b"a\xc3\x28b", b"\xed\xa0\x80"):
            (rec,) = _feed(b"SET text/x " + bad + b"\n")
            self.assertEqual(rec["ok"], "0", bad)
            self.assertEqual(rec["code"], "bad-value", bad)


class LineFramingTest(unittest.TestCase):
    def test_crlf_line_ending(self):
        (rec,) = _feed(b"PING\r\n")
        self.assertEqual(rec["verb"], "PING")
        self.assertEqual(rec["ok"], "1")

    def test_maximum_length_line_is_accepted(self):
        # 255 content bytes + terminator = 256, the inbound budget. Not over-long.
        events = _feed(b"a" * 255 + b"\n")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event"], "LINE")

    def test_over_long_line_reports_too_long_then_resyncs(self):
        events = _feed(b"a" * 256 + b"junk\n" + b"PING\n")
        self.assertEqual(events[0]["event"], "TOOLONG")
        # The stream resynced at the newline: the following PING parses normally.
        self.assertEqual(events[-1]["verb"], "PING")
        self.assertEqual(events[-1]["ok"], "1")

    def test_two_lines_in_one_stream(self):
        events = _feed(b"PING\nLIST\n")
        self.assertEqual([e["verb"] for e in events], ["PING", "LIST"])


class QuotingTest(unittest.TestCase):
    def test_plain_name(self):
        self.assertEqual(_quote(b"Relay"), b'"Relay"')

    def test_embedded_quote_and_backslash_are_escaped(self):
        self.assertEqual(_quote(b'A"B\\C'), b'"A\\"B\\\\C"')

    def test_option_containing_a_space(self):
        out = _run("seldomain", b"Easy".hex(), b"Hard Mode".hex()).strip()
        self.assertEqual(out, '"Easy" "Hard Mode"')


class ExposureRuleTest(unittest.TestCase):
    def test_ordinary_entity_is_exposed(self):
        self.assertEqual(_expose("relay", False), "exposed")

    def test_reset_room_is_exposed(self):
        self.assertEqual(_expose("reset_room", False), "exposed")

    def test_internal_is_denied(self):
        self.assertEqual(_expose("relay", True), "denied")

    def test_system_prefix_denied_case_insensitive(self):
        for oid in ("system_restart", "SYSTEM_shutdown", "System_x"):
            self.assertEqual(_expose(oid, False), "denied", oid)

    def test_ota_prefix_denied(self):
        self.assertEqual(_expose("ota_https_prod", False), "denied")

    def test_secret_ota_denied_exactly(self):
        self.assertEqual(_expose("secret_ota", False), "denied")
        # A different name that merely contains the substring is not denied by this rule.
        self.assertEqual(_expose("my_secret_otax", False), "exposed")


class FloatFormatTest(unittest.TestCase):
    """State floats round-trip: no precision loss for small values, no truncation for large ones."""

    def _statef(self, value: str, has_state: bool = True) -> str:
        return _run("statef", value, "1" if has_state else "0").strip()

    def test_unpublished_is_nan(self):
        self.assertEqual(self._statef("0", has_state=False), "NaN")

    def test_zero_and_negative_zero(self):
        self.assertEqual(self._statef("0"), "0")
        self.assertEqual(self._statef("-0"), "0")

    def test_integral_and_simple_decimals(self):
        self.assertEqual(self._statef("21.5"), "21.5")
        self.assertEqual(self._statef("100"), "100")
        self.assertEqual(self._statef("0.1"), "0.1")

    def test_small_nonzero_value_is_not_collapsed_to_zero(self):
        out = self._statef("0.0000004")
        self.assertNotEqual(out, "0")
        self.assertAlmostEqual(float(out), 0.0000004, places=10)

    def test_large_finite_value_is_not_truncated(self):
        out = self._statef("3.4e38")
        # Parses back to a large finite float, never a truncated/garbage token.
        self.assertGreater(float(out), 1e38)

    def test_small_value_needing_many_fractional_digits_round_trips(self):
        # A value in [1e-4, 1e-3) needs leading zeros plus ~9 significant digits; it must still
        # round-trip exactly, not be truncated to a shorter (wrong) fixed form.
        import struct

        def as_float32(x: str) -> float:
            return struct.unpack("f", struct.pack("f", float(x)))[0]

        for value in ("0.000123456789", "0.00012345678987912834", "0.0001220703125"):
            out = self._statef(value)
            self.assertEqual(as_float32(out), as_float32(value), value)


class WireLineTest(unittest.TestCase):
    """Every ERR code and each device line asserted as an exact wire line (detail not semantic)."""

    def test_error_codes_exact_wire_lines(self):
        self.assertEqual(_run("errline", "parse").strip(), "ERR parse")
        self.assertEqual(_run("errline", "parse", "line-too-long").strip(), "ERR parse line-too-long")
        self.assertEqual(
            _run("errline", "unknown-entity", "switch/x").strip(), "ERR unknown-entity switch/x"
        )
        self.assertEqual(
            _run("errline", "unsupported-type", "lock/door").strip(), "ERR unsupported-type lock/door"
        )
        self.assertEqual(_run("errline", "denied", "system_restart").strip(), "ERR denied system_restart")
        self.assertEqual(_run("errline", "no-state", "button/reboot").strip(), "ERR no-state button/reboot")
        self.assertEqual(_run("errline", "bad-value").strip(), "ERR bad-value")
        # read-only is in the closed set and its wire form is frozen here; SER-1 never emits it (the
        # write path in AIOT-133 does), but the contract SER-2 builds on is asserted now.
        self.assertEqual(_run("errline", "read-only", "sensor/temp").strip(), "ERR read-only sensor/temp")

    def test_hello_banner(self):
        out = _run("hello", b"serial-api-testdev".hex(), b"1.2.3".hex()).strip()
        self.assertEqual(out, "HELLO serial_api 1 serial-api-testdev 1.2.3")

    def test_ent_plain(self):
        out = _run("ent", "switch", "relay", "rw", b"Relay".hex()).strip()
        self.assertEqual(out, 'ENT switch relay rw "Relay"')

    def test_ent_read_only_unsupported_has_no_domain(self):
        out = _run("ent", "lock", "door", "ro", b"Door Lock".hex()).strip()
        self.assertEqual(out, 'ENT lock door ro "Door Lock"')

    def test_ent_number_domain(self):
        domain = _run("numdomain", "0", "100", "5").strip()
        out = _run("ent", "number", "volume", "rw", b"Volume".hex(), *domain.split()).strip()
        self.assertEqual(out, 'ENT number volume rw "Volume" 0 100 5')

    def test_number_domain_formatting(self):
        self.assertEqual(_run("numdomain", "0", "100", "5").strip(), "0 100 5")
        self.assertEqual(_run("numdomain", "0.5", "2.5", "0.1").strip(), "0.5 2.5 0.1")

    def test_text_domain_formatting(self):
        self.assertEqual(_run("textdomain", "0", "32").strip(), "0 32")

    def test_state_line(self):
        self.assertEqual(_run("state", "switch/relay", b"ON".hex()).strip(), "STATE switch/relay ON")
        # A raw string value with a space survives verbatim.
        self.assertEqual(_run("state", "text/label", b"a b".hex()).strip(), "STATE text/label a b")


class SwitchWriteTest(unittest.TestCase):
    """SET switch/<id> ON|OFF; every other token is ERR bad-value (no write)."""

    def test_on_and_off_are_accepted(self):
        self.assertEqual(_setswitch(b"ON"), "on")
        self.assertEqual(_setswitch(b"OFF"), "off")

    def test_everything_else_is_bad_value(self):
        # Case, numeric aliases, booleans, empty and a trailing/leading space are all rejected: the
        # vocabulary is exactly the two tokens the read path emits.
        for bad in (b"on", b"Off", b"1", b"0", b"true", b"", b"ON ", b" ON", b"ONOFF"):
            self.assertEqual(_setswitch(bad), "bad", bad)


class NumberWriteTest(unittest.TestCase):
    """SET number/<id> <v>: finite decimal within [min,max] inclusive; anything else bad-value."""

    def test_in_range_value_parses(self):
        self.assertEqual(_setnumber(b"50", "0", "100"), "ok=50")
        self.assertEqual(_setnumber(b"3.5", "0", "100"), "ok=3.5")

    def test_inclusive_boundaries_are_accepted(self):
        self.assertEqual(_setnumber(b"0", "0", "100"), "ok=0")
        self.assertEqual(_setnumber(b"100", "0", "100"), "ok=100")

    def test_out_of_range_is_bad_value(self):
        # Just outside either bound, and far outside, on a symmetric and an asymmetric range.
        self.assertEqual(_setnumber(b"-1", "0", "100"), "bad")
        self.assertEqual(_setnumber(b"101", "0", "100"), "bad")
        self.assertEqual(_setnumber(b"-11", "-10", "10"), "bad")
        self.assertEqual(_setnumber(b"-10", "-10", "10"), "ok=-10")

    def test_non_numeric_or_malformed_is_bad_value(self):
        # Empty, alphabetic, trailing bytes the number did not consume, a leading space strtof would
        # skip, and the non-finite tokens strtof accepts but a bounded actuator must not.
        for bad in (b"", b"abc", b"5x", b"1 2", b" 5", b"NaN", b"nan", b"inf", b"-inf"):
            self.assertEqual(_setnumber(bad, "-100", "100"), "bad", bad)


class TextWriteTest(unittest.TestCase):
    """SET text/<id> <v>: BYTE length within [min_length,max_length] inclusive, prevalidated."""

    def test_length_within_bounds_is_accepted(self):
        self.assertEqual(_settext(b"abc", 0, 5), "ok")

    def test_empty_value_accepted_when_min_length_zero(self):
        # The empty-value line form (`SET text/x`) reaches here as an empty string; min_length 0
        # accepts it.
        self.assertEqual(_settext(b"", 0, 5), "ok")

    def test_empty_value_rejected_when_min_length_positive(self):
        self.assertEqual(_settext(b"", 1, 5), "bad")

    def test_inclusive_boundaries(self):
        self.assertEqual(_settext(b"ab", 2, 5), "ok")  # exactly min
        self.assertEqual(_settext(b"abcde", 2, 5), "ok")  # exactly max
        self.assertEqual(_settext(b"a", 2, 5), "bad")  # one short of min
        self.assertEqual(_settext(b"abcdef", 2, 5), "bad")  # one over max

    def test_length_is_bytes_not_code_points(self):
        # "café" is 4 code points but 5 UTF-8 bytes; the bound is bytes, matching TextCall::validate_.
        cafe = "café".encode("utf-8")
        self.assertEqual(len(cafe), 5)
        self.assertEqual(_settext(cafe, 0, 5), "ok")
        self.assertEqual(_settext(cafe, 0, 4), "bad")


class SelectWriteTest(unittest.TestCase):
    """SET select/<id> <v>: value must be one of the declared options exactly."""

    OPTS = (b"Easy", b"Hard Mode")

    def test_declared_option_is_accepted(self):
        self.assertEqual(_setselect(b"Easy", *self.OPTS), "ok")

    def test_option_containing_a_space_is_accepted(self):
        self.assertEqual(_setselect(b"Hard Mode", *self.OPTS), "ok")

    def test_option_outside_the_list_is_bad_value(self):
        for bad in (b"hard mode", b"Medium", b"", b"Easy "):
            self.assertEqual(_setselect(bad, *self.OPTS), "bad", bad)

    def test_no_options_declared_rejects_everything(self):
        self.assertEqual(_setselect(b"Easy"), "bad")


class ButtonWriteTest(unittest.TestCase):
    """SET button/<id> PRESS presses; every other token is bad-value."""

    def test_press_is_accepted(self):
        self.assertEqual(_setbutton(b"PRESS"), "ok")

    def test_everything_else_is_bad_value(self):
        for bad in (b"press", b"", b"PRESS ", b"PUSH", b"1", b"ON"):
            self.assertEqual(_setbutton(bad), "bad", bad)


if __name__ == "__main__":
    unittest.main()
