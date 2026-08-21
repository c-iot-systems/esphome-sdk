#pragma once

// Serial API wire protocol — the lexer, the response formatters and the exposure rule.
//
// This translation unit is deliberately free of every ESPHome dependency: it includes only the C++
// standard library. Two things follow from that. First, the firmware component links it directly.
// Second, the host unit tests (tests/unit/) compile it with a plain g++ and drive it, so the frozen
// grammar published to integrators is proven by CI without a device in the loop. Keep it that way —
// an `esphome/...` include here would break the unit-test build and is never necessary, because
// nothing about lexing a line or quoting a name needs the entity model.
//
// The grammar is the public contract from docs/specs/2026-08-20-serial-api-spec.md (AIOT-131).
// SER-1 owns it and SER-2 extends the write path on top of it; the shape here is what SER-2 builds
// against, so it lexes every verb — SET included — even though SER-1 performs no write.

#include <cstdint>
#include <string>
#include <vector>

namespace esphome {
namespace serial_api {
namespace protocol {

// The protocol version the HELLO banner reports. SER-4 publishes it as contract and SER-6 renders
// it; neither redefines it. Bump only on an incompatible grammar change.
static constexpr int PROTOCOL_VERSION = 1;

// Inbound line budget, terminator included (spec "Length: 256 bytes inbound").
static constexpr size_t MAX_LINE_BYTES = 256;

// The closed error-code set. detail (when present) is for a human at a terminal and carries no
// meaning a client may branch on.
namespace err {
static constexpr const char *PARSE = "parse";
static constexpr const char *UNKNOWN_ENTITY = "unknown-entity";
static constexpr const char *UNSUPPORTED_TYPE = "unsupported-type";
static constexpr const char *READ_ONLY = "read-only";
static constexpr const char *BAD_VALUE = "bad-value";
static constexpr const char *DENIED = "denied";
static constexpr const char *NO_STATE = "no-state";
}  // namespace err

enum class Verb : uint8_t { LIST, GET, SET, SUB, UNSUB, PING, HELLO, UNKNOWN };

// The result of lexing one assembled line (terminator and an optional trailing CR already removed).
struct Command {
  Verb verb{Verb::UNKNOWN};
  bool ok{false};              // false => reject with `error_code`
  const char *error_code{nullptr};
  const char *error_detail{nullptr};
  bool wildcard{false};        // GET *
  std::string type;            // address type segment (before '/')
  std::string object_id;       // address object_id segment (after '/')
  bool has_value{false};       // SET carries a value (possibly empty)
  std::string value;           // raw SET value, verbatim to end of line
};

// Assembles inbound bytes into lines. A line is terminated by '\n'; a single '\r' immediately
// before it is dropped so CRLF clients work unchanged. A line that reaches MAX_LINE_BYTES before
// its terminator is reported TOO_LONG once, then every further byte is discarded until the next
// '\n' — the resync the spec requires, so a truncated giant line cannot desynchronise the stream.
class LineAssembler {
 public:
  enum class Status : uint8_t { NONE, LINE_READY, TOO_LONG };

  // Feed one received byte. When this returns LINE_READY, line() holds the assembled line.
  Status feed(uint8_t byte);
  const std::string &line() const { return this->line_; }
  void reset();

 protected:
  std::string line_;
  bool overflow_{false};  // discarding the remainder of an over-long line until the next '\n'
};

// Lex one assembled line into a Command. Never allocates beyond the returned strings.
Command parse_line(const std::string &line);

// Wrap a field in double quotes, escaping '\' and '"' (the only two escapes the grammar defines).
// Used for the ENT name and each select option.
std::string quote(const std::string &s);

// True when a value contains a byte below 0x20 (any control char). The terminator never reaches
// here, so a rejected value is one a SET must answer ERR bad-value for.
bool has_control_byte(const std::string &s);

// True when a value is well-formed UTF-8 (the grammar's encoding). Rejects stray continuation
// bytes, truncated sequences, overlong encodings, UTF-16 surrogate halves and code points beyond
// U+10FFFF, so a SET value that is not UTF-8 answers ERR bad-value.
bool is_valid_utf8(const std::string &s);

// The exposure rule (spec "The exposure rule", ADR AIOT-131-serial-api-exposure-rule). An entity is
// denied — absent from LIST, ERR denied on GET — when it is internal, its object_id begins with
// `system_` (case-insensitive) or `ota_`, or is exactly `secret_ota`. reset_room is NOT denied.
bool is_denied(const std::string &object_id, bool internal);

// Per-type SET value validators (the write path, AIOT-131 SER-2). These are pure — no ESPHome type
// enters this translation unit — so the host unit tests drive every ERR bad-value boundary without a
// device. The component's write adapters call the matching validator BEFORE touching the entity's
// call API: ESPHome's number/text/select call APIs silently DECLINE a value outside their bounds
// (verified against ESPHome 2026.5.1: NumberCall::perform, TextCall::validate_, SelectCall::perform
// warn and return without writing), so validating here is what turns that silent no-op into an
// explicit ERR bad-value and guarantees no write happens on a rejected value.
enum class ValueCheck : uint8_t { OK, BAD_VALUE };

// switch: the value is exactly "ON" or "OFF" (the same vocabulary the read path emits). On OK, `on`
// is the target state.
ValueCheck check_switch_value(const std::string &value, bool &on);

// number: the value is a finite decimal within [min_value, max_value] INCLUSIVE — the bounds and the
// inclusive comparison mirror NumberCall::perform, which declines a value strictly below min or
// above max. On OK, `out` is the parsed value. A non-numeric token, trailing bytes, a leading space,
// NaN or an infinity are rejected.
ValueCheck check_number_value(const std::string &value, float min_value, float max_value, float &out);

// text: the value's BYTE length is within [min_length, max_length] INCLUSIVE — byte length and the
// inclusive bounds are exactly what TextCall::validate_() checks (`int sz = value.size()`, declines
// sz > max or sz < min). An empty value passes when min_length is 0.
ValueCheck check_text_value(const std::string &value, int min_length, int max_length);

// select: the value equals one of `options` exactly (byte-for-byte), the same membership test
// Select::index_of performs.
ValueCheck check_select_value(const std::string &value, const std::vector<std::string> &options);

// button: the value is exactly "PRESS".
ValueCheck check_button_value(const std::string &value);

// Response-line formatters. Each returns the exact wire line WITHOUT the trailing '\n'; the caller
// terminates. They take primitives so the host tests can assert byte-exact output.
std::string format_err(const char *code, const std::string &detail);
std::string format_err(const char *code);
std::string format_hello(const std::string &device_name, const std::string &firmware_version);
std::string format_state(const std::string &address, const std::string &value);
std::string format_evt(const std::string &address, const std::string &value);

// ENT line. `domain` is the already-formatted, type-specific suffix (empty for types without one).
std::string format_ent(const std::string &type, const std::string &object_id, bool writable,
                       const std::string &name, const std::string &domain);

// Type-specific ENT domain suffixes.
std::string format_number_domain(float min_value, float max_value, float step);
std::string format_text_domain(int min_length, int max_length);
std::string format_select_domain(const std::vector<std::string> &options);

// Render a state float: "NaN" when unpublished, otherwise a compact decimal with no exponent and no
// trailing zeros. Shared by sensor and number so both serialise identically.
std::string format_state_float(float value, bool has_state);

}  // namespace protocol
}  // namespace serial_api
}  // namespace esphome
