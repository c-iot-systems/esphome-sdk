#include "serial_api_protocol.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace esphome {
namespace serial_api {
namespace protocol {

namespace {

constexpr char TERMINATOR = '\n';
constexpr char CR = '\r';

bool starts_with_ci(const std::string &s, const char *prefix) {
  size_t n = std::strlen(prefix);
  if (s.size() < n)
    return false;
  for (size_t i = 0; i < n; i++) {
    char a = s[i];
    if (a >= 'A' && a <= 'Z')
      a = static_cast<char>(a - 'A' + 'a');
    char b = prefix[i];
    if (b >= 'A' && b <= 'Z')
      b = static_cast<char>(b - 'A' + 'a');
    if (a != b)
      return false;
  }
  return true;
}

bool starts_with(const std::string &s, const char *prefix) {
  size_t n = std::strlen(prefix);
  return s.size() >= n && std::memcmp(s.data(), prefix, n) == 0;
}

// Split the address "<type>/<object_id>" into its segments. Rejects a missing slash, an empty type
// and an empty object_id. A '/' inside the object_id is rejected too: object_id is exactly one MQTT
// topic segment, which never contains a slash.
bool parse_address(const std::string &addr, Command &cmd) {
  // The address is part of the UTF-8 line; a malformed-encoding address is a parse error, not a
  // lookup that happens to miss. (The verb is matched against ASCII literals, so a malformed verb
  // already falls through to "unknown-verb".)
  if (!is_valid_utf8(addr))
    return false;
  size_t slash = addr.find('/');
  if (slash == std::string::npos || slash == 0 || slash + 1 >= addr.size())
    return false;
  if (addr.find('/', slash + 1) != std::string::npos)
    return false;
  cmd.type.assign(addr, 0, slash);
  cmd.object_id.assign(addr, slash + 1, std::string::npos);
  return true;
}

}  // namespace

LineAssembler::Status LineAssembler::feed(uint8_t byte) {
  if (byte == TERMINATOR) {
    if (this->overflow_) {
      // The over-long line already reported TOO_LONG; this terminator ends the discard window.
      this->reset();
      return Status::NONE;
    }
    if (!this->line_.empty() && this->line_.back() == CR)
      this->line_.pop_back();
    return Status::LINE_READY;
  }
  if (this->overflow_)
    return Status::NONE;
  this->line_.push_back(static_cast<char>(byte));
  // The terminator counts toward the 256-byte budget, so the content limit is MAX_LINE_BYTES - 1.
  if (this->line_.size() >= MAX_LINE_BYTES) {
    this->overflow_ = true;
    this->line_.clear();
    return Status::TOO_LONG;
  }
  return Status::NONE;
}

void LineAssembler::reset() {
  this->line_.clear();
  this->overflow_ = false;
}

Command parse_line(const std::string &raw) {
  Command cmd;

  // A single leading space is ignored; fields are otherwise separated by exactly one space.
  size_t start = (!raw.empty() && raw[0] == ' ') ? 1 : 0;
  size_t verb_end = raw.find(' ', start);
  std::string verb = raw.substr(start, verb_end == std::string::npos ? std::string::npos : verb_end - start);
  bool has_rest = verb_end != std::string::npos;
  size_t rest = has_rest ? verb_end + 1 : raw.size();  // first byte after the separating space

  auto reject = [&](const char *code, const char *detail) {
    cmd.ok = false;
    cmd.error_code = code;
    cmd.error_detail = detail;
    return cmd;
  };

  // The nullary verbs take no field. Under the single-space grammar, any trailing separator or
  // payload (`LIST x`, `PING `) is malformed, not ignored.
  auto nullary = [&](Verb v) {
    cmd.verb = v;
    if (has_rest)
      return reject(err::PARSE, "no-args-expected");
    cmd.ok = true;
    return cmd;
  };
  if (verb == "LIST")
    return nullary(Verb::LIST);
  if (verb == "SUB")
    return nullary(Verb::SUB);
  if (verb == "UNSUB")
    return nullary(Verb::UNSUB);
  if (verb == "PING")
    return nullary(Verb::PING);
  if (verb == "HELLO")
    return nullary(Verb::HELLO);

  if (verb == "GET") {
    cmd.verb = Verb::GET;
    if (!has_rest)
      return reject(err::PARSE, "get-needs-address");
    std::string arg = raw.substr(rest);
    if (arg.find(' ') != std::string::npos)
      return reject(err::PARSE, "get-extra-args");
    if (arg == "*") {
      cmd.wildcard = true;
      cmd.ok = true;
      return cmd;
    }
    if (!parse_address(arg, cmd))
      return reject(err::PARSE, "bad-address");
    cmd.ok = true;
    return cmd;
  }

  if (verb == "SET") {
    cmd.verb = Verb::SET;
    if (!has_rest)
      return reject(err::PARSE, "set-needs-address");
    // The address runs to the next space; the value is everything after that single space, taken
    // verbatim to the end of the line. `SET <addr>` (no space) and `SET <addr> ` (trailing space,
    // nothing after) both mean the empty value, and nothing else does.
    std::string remainder = raw.substr(rest);
    size_t addr_end = remainder.find(' ');
    std::string addr = (addr_end == std::string::npos) ? remainder : remainder.substr(0, addr_end);
    if (!parse_address(addr, cmd))
      return reject(err::PARSE, "bad-address");
    cmd.has_value = true;
    cmd.value = (addr_end == std::string::npos) ? std::string() : remainder.substr(addr_end + 1);
    // The value is a UTF-8 string with no control bytes; both are rejected lexically, before any
    // write is attempted.
    if (has_control_byte(cmd.value))
      return reject(err::BAD_VALUE, "control-byte");
    if (!is_valid_utf8(cmd.value))
      return reject(err::BAD_VALUE, "bad-utf8");
    cmd.ok = true;
    return cmd;
  }

  cmd.verb = Verb::UNKNOWN;
  return reject(err::PARSE, "unknown-verb");
}

std::string quote(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 2);
  out.push_back('"');
  for (char c : s) {
    if (c == '\\' || c == '"')
      out.push_back('\\');
    out.push_back(c);
  }
  out.push_back('"');
  return out;
}

bool has_control_byte(const std::string &s) {
  for (unsigned char c : s) {
    if (c < 0x20)
      return true;
  }
  return false;
}

bool is_valid_utf8(const std::string &s) {
  size_t i = 0;
  size_t n = s.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t extra;
    if (c < 0x80) {
      i++;
      continue;
    } else if ((c & 0xE0) == 0xC0) {
      if (c < 0xC2)  // overlong two-byte (C0/C1)
        return false;
      extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
      extra = 2;
    } else if ((c & 0xF8) == 0xF0) {
      if (c > 0xF4)  // beyond U+10FFFF
        return false;
      extra = 3;
    } else {
      return false;  // stray continuation byte or 5/6-byte lead
    }
    if (i + extra >= n)
      return false;  // truncated sequence
    for (size_t k = 1; k <= extra; k++) {
      if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80)
        return false;
    }
    unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
    if (extra == 2) {
      if (c == 0xE0 && c1 < 0xA0)  // overlong three-byte
        return false;
      if (c == 0xED && c1 > 0x9F)  // UTF-16 surrogate half
        return false;
    } else if (extra == 3) {
      if (c == 0xF0 && c1 < 0x90)  // overlong four-byte
        return false;
      if (c == 0xF4 && c1 > 0x8F)  // beyond U+10FFFF
        return false;
    }
    i += extra + 1;
  }
  return true;
}

bool is_denied(const std::string &object_id, bool internal) {
  if (internal)
    return true;
  if (starts_with_ci(object_id, "system_"))
    return true;
  if (starts_with(object_id, "ota_"))
    return true;
  if (object_id == "secret_ota")
    return true;
  return false;
}

ValueCheck check_switch_value(const std::string &value, bool &on) {
  if (value == "ON") {
    on = true;
    return ValueCheck::OK;
  }
  if (value == "OFF") {
    on = false;
    return ValueCheck::OK;
  }
  return ValueCheck::BAD_VALUE;
}

ValueCheck check_number_value(const std::string &value, float min_value, float max_value, float &out) {
  if (value.empty())
    return ValueCheck::BAD_VALUE;
  // strtof skips leading whitespace and accepts "inf"/"nan"; the wire value is a bare decimal, so a
  // leading space or a non-finite token is a bad value, not a number that happens to parse.
  if (value.front() == ' ')
    return ValueCheck::BAD_VALUE;
  // strtof also accepts C hexadecimal-float syntax ("0x1p2", "0x10"), which the wire contract does
  // not define — the value is a decimal (optionally scientific). Every hex form carries the 0x/0X
  // marker, so rejecting 'x'/'X' rejects them all while leaving decimal and scientific notation
  // untouched (neither ever contains 'x').
  if (value.find('x') != std::string::npos || value.find('X') != std::string::npos)
    return ValueCheck::BAD_VALUE;
  const char *begin = value.c_str();
  char *end = nullptr;
  float parsed = std::strtof(begin, &end);
  if (end != begin + value.size())  // bytes the number did not consume: "5x", "1 2", ""
    return ValueCheck::BAD_VALUE;
  if (!std::isfinite(parsed))
    return ValueCheck::BAD_VALUE;
  // Inclusive, mirroring NumberCall::perform which declines target < min or target > max. When a
  // bound is NaN (an undeclared limit) both comparisons are false, so the value passes exactly as
  // NumberCall would let it.
  if (parsed < min_value || parsed > max_value)
    return ValueCheck::BAD_VALUE;
  out = parsed;
  return ValueCheck::OK;
}

ValueCheck check_text_value(const std::string &value, int min_length, int max_length) {
  int sz = static_cast<int>(value.size());
  if (sz < min_length || sz > max_length)
    return ValueCheck::BAD_VALUE;
  return ValueCheck::OK;
}

ValueCheck check_select_value(const std::string &value, const std::vector<std::string> &options) {
  for (const std::string &option : options) {
    if (option == value)
      return ValueCheck::OK;
  }
  return ValueCheck::BAD_VALUE;
}

ValueCheck check_button_value(const std::string &value) {
  return value == "PRESS" ? ValueCheck::OK : ValueCheck::BAD_VALUE;
}

std::string format_set_response(SetOutcome outcome, const std::string &address) {
  switch (outcome) {
    case SetOutcome::OK:
      return "OK";
    case SetOutcome::BAD_VALUE:
      return format_err(err::BAD_VALUE, address);
    case SetOutcome::READ_ONLY:
      return format_err(err::READ_ONLY, address);
    case SetOutcome::UNSUPPORTED:
      return format_err(err::UNSUPPORTED_TYPE, address);
  }
  return format_err(err::BAD_VALUE, address);  // unreachable; the enum is exhaustive
}

std::string format_err(const char *code, const std::string &detail) {
  std::string out = "ERR ";
  out += code;
  if (!detail.empty()) {
    out.push_back(' ');
    out += detail;
  }
  return out;
}

std::string format_err(const char *code) { return format_err(code, std::string()); }

std::string format_hello(const std::string &device_name, const std::string &firmware_version) {
  std::string out = "HELLO serial_api ";
  out += std::to_string(PROTOCOL_VERSION);
  out.push_back(' ');
  out += device_name;
  out.push_back(' ');
  out += firmware_version;
  return out;
}

std::string format_state(const std::string &address, const std::string &value) {
  std::string out = "STATE ";
  out += address;
  out.push_back(' ');
  out += value;
  return out;
}

std::string format_evt(const std::string &address, const std::string &value) {
  std::string out = "EVT ";
  out += address;
  out.push_back(' ');
  out += value;
  return out;
}

std::string format_ent(const std::string &type, const std::string &object_id, bool writable,
                       const std::string &name, const std::string &domain) {
  std::string out = "ENT ";
  out += type;
  out.push_back(' ');
  out += object_id;
  out += writable ? " rw " : " ro ";
  out += quote(name);
  if (!domain.empty()) {
    out.push_back(' ');
    out += domain;
  }
  return out;
}

std::string format_state_float(float value, bool has_state) {
  if (!has_state || std::isnan(value))
    return "NaN";
  if (value == 0.0f)
    return "0";  // normalise -0
  if (std::isinf(value))
    return value < 0 ? "-inf" : "inf";

  // The value printed is the shortest decimal that parses back to this exact float — found by
  // raising the digit count until strtof round-trips — so no precision is lost (0 and 4e-7 differ)
  // and no spurious digits appear (0.1, not 0.100000001). Because the last digit kept is always
  // significant, there are never trailing zeros to trim.
  char buf[64];
  float magnitude = std::fabs(value);
  bool done = false;
  if (magnitude >= 1e-4f && magnitude < 1e16f) {
    // Normal magnitude: fixed notation, so an integer reads as "100", not "1e+02". A value with a
    // small magnitude needs leading zeros before its significant digits, so allow enough fractional
    // digits to carry a float's ~9 significant figures even at the low end of this window.
    for (int frac = 0; frac <= 20; frac++) {
      std::snprintf(buf, sizeof(buf), "%.*f", frac, static_cast<double>(value));
      if (std::strtof(buf, nullptr) == value) {
        done = true;
        break;
      }
    }
  }
  if (!done) {
    // Tiny, huge, or a fixed form that could not round-trip: an exponent is the compact form, and
    // %g at 9 significant digits (float max_digits10) always round-trips, so this never falls
    // through with a lossy value.
    for (int precision = 1; precision <= 9; precision++) {
      std::snprintf(buf, sizeof(buf), "%.*g", precision, static_cast<double>(value));
      if (std::strtof(buf, nullptr) == value)
        break;
    }
  }
  return std::string(buf);
}

std::string format_number_domain(float min_value, float max_value, float step) {
  std::string out = format_state_float(min_value, true);
  out.push_back(' ');
  out += format_state_float(max_value, true);
  out.push_back(' ');
  out += format_state_float(step, true);
  return out;
}

std::string format_text_domain(int min_length, int max_length) {
  std::string out = std::to_string(min_length);
  out.push_back(' ');
  out += std::to_string(max_length);
  return out;
}

std::string format_select_domain(const std::vector<std::string> &options) {
  std::string out;
  for (size_t i = 0; i < options.size(); i++) {
    if (i != 0)
      out.push_back(' ');
    out += quote(options[i]);
  }
  return out;
}

}  // namespace protocol
}  // namespace serial_api
}  // namespace esphome
