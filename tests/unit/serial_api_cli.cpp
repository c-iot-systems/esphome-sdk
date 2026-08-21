// Host test harness for the Serial API wire protocol.
//
// The protocol layer (components/serial_api/serial_api_protocol.*) is deliberately free of ESPHome
// dependencies, so it compiles with a plain g++ and the Python unit tests drive it through this
// CLI. Each invocation runs one mode and prints a deterministic result the test asserts on; bytes
// that could contain spaces, quotes or control characters cross the boundary hex-encoded, so the
// exact wire behaviour is testable without a device.
//
// Modes (argv[1]):
//   feed                 stdin = hex of a byte stream; drive the LineAssembler + parse each line
//   quote      <hexstr>  print quote(bytes) hex-encoded
//   errline    <code> [detail]        print format_err
//   expose     <object_id> <0|1>      print "denied" or "exposed"
//   numdomain  <min> <max> <step>     print format_number_domain
//   textdomain <min> <max>            print format_text_domain
//   seldomain  <hexopt>...            print format_select_domain (each option hex-encoded)
//   hello      <hexname> <hexver>     print format_hello
//   ent        <type> <oid> <rw|ro> <hexname> [domain...]   print format_ent
//   state      <address> <hexval>     print format_state

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "serial_api_protocol.h"

namespace proto = esphome::serial_api::protocol;

namespace {

std::string from_hex(const std::string &hex) {
  std::string out;
  std::string clean;
  for (char c : hex) {
    if (c != ' ' && c != '\n' && c != '\r' && c != '\t')
      clean.push_back(c);
  }
  for (size_t i = 0; i + 1 < clean.size(); i += 2) {
    out.push_back(static_cast<char>(std::stoi(clean.substr(i, 2), nullptr, 16)));
  }
  return out;
}

std::string to_hex(const std::string &s) {
  static const char *digits = "0123456789abcdef";
  std::string out;
  for (unsigned char c : s) {
    out.push_back(digits[c >> 4]);
    out.push_back(digits[c & 0x0f]);
  }
  return out;
}

std::string read_stdin() {
  std::string all;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), stdin)) > 0)
    all.append(buf, n);
  return all;
}

const char *verb_name(proto::Verb v) {
  switch (v) {
    case proto::Verb::LIST: return "LIST";
    case proto::Verb::GET: return "GET";
    case proto::Verb::SET: return "SET";
    case proto::Verb::SUB: return "SUB";
    case proto::Verb::UNSUB: return "UNSUB";
    case proto::Verb::PING: return "PING";
    case proto::Verb::HELLO: return "HELLO";
    default: return "UNKNOWN";
  }
}

int mode_feed() {
  std::string bytes = from_hex(read_stdin());
  proto::LineAssembler assembler;
  for (unsigned char c : bytes) {
    switch (assembler.feed(c)) {
      case proto::LineAssembler::Status::LINE_READY: {
        proto::Command cmd = proto::parse_line(assembler.line());
        std::printf("LINE\tverb=%s\tok=%d\tcode=%s\ttype=%s\toid=%s\twc=%d\thasval=%d\tval=%s\n",
                    verb_name(cmd.verb), cmd.ok ? 1 : 0, cmd.error_code ? cmd.error_code : "-",
                    cmd.type.empty() ? "-" : cmd.type.c_str(),
                    cmd.object_id.empty() ? "-" : cmd.object_id.c_str(), cmd.wildcard ? 1 : 0,
                    cmd.has_value ? 1 : 0, to_hex(cmd.value).c_str());
        assembler.reset();
        break;
      }
      case proto::LineAssembler::Status::TOO_LONG:
        std::printf("TOOLONG\n");
        break;
      case proto::LineAssembler::Status::NONE:
        break;
    }
  }
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: serial_api_cli <mode> [args]\n");
    return 2;
  }
  std::string mode = argv[1];

  if (mode == "feed")
    return mode_feed();

  if (mode == "quote") {
    std::printf("%s\n", to_hex(proto::quote(from_hex(argv[2]))).c_str());
    return 0;
  }
  if (mode == "errline") {
    if (argc >= 4)
      std::printf("%s\n", proto::format_err(argv[2], argv[3]).c_str());
    else
      std::printf("%s\n", proto::format_err(argv[2]).c_str());
    return 0;
  }
  if (mode == "expose") {
    bool internal = std::string(argv[3]) == "1";
    std::printf("%s\n", proto::is_denied(argv[2], internal) ? "denied" : "exposed");
    return 0;
  }
  if (mode == "numdomain") {
    std::printf("%s\n", proto::format_number_domain(std::stof(argv[2]), std::stof(argv[3]),
                                                    std::stof(argv[4]))
                            .c_str());
    return 0;
  }
  if (mode == "textdomain") {
    std::printf("%s\n", proto::format_text_domain(std::stoi(argv[2]), std::stoi(argv[3])).c_str());
    return 0;
  }
  if (mode == "seldomain") {
    std::vector<std::string> options;
    for (int i = 2; i < argc; i++)
      options.push_back(from_hex(argv[i]));
    std::printf("%s\n", proto::format_select_domain(options).c_str());
    return 0;
  }
  if (mode == "hello") {
    std::printf("%s\n", proto::format_hello(from_hex(argv[2]), from_hex(argv[3])).c_str());
    return 0;
  }
  if (mode == "ent") {
    bool writable = std::string(argv[4]) == "rw";
    std::string domain;
    for (int i = 6; i < argc; i++) {
      if (i > 6)
        domain.push_back(' ');
      domain += argv[i];
    }
    std::printf("%s\n", proto::format_ent(argv[2], argv[3], writable, from_hex(argv[5]), domain).c_str());
    return 0;
  }
  if (mode == "state") {
    std::printf("%s\n", proto::format_state(argv[2], from_hex(argv[3])).c_str());
    return 0;
  }
  if (mode == "statef") {
    // statef <float> <has_state 0|1> — exercises format_state_float directly.
    bool has_state = std::string(argv[3]) == "1";
    std::printf("%s\n", proto::format_state_float(std::strtof(argv[2], nullptr), has_state).c_str());
    return 0;
  }

  std::fprintf(stderr, "unknown mode: %s\n", mode.c_str());
  return 2;
}
