#pragma once

#include "esphome/components/uart/uart.h"
#include "esphome/core/automation.h"
#include "esphome/core/component.h"
#include "esphome/core/hal.h"
#include "esphome/core/helpers.h"

namespace esphome {
namespace medeawiz {

// Serial command bytes for the MedeaWiz Sprite 4K (DV-S4). See the
// "Serial Port Control Commands" table in the Sprite 4K User Manual v4.00.
// File-play commands are a single byte equal to the file number: 0x00 plays
// file 000, 0x01 plays 001, ... up to 0xC8 which plays file 200.
static const uint8_t MEDEAWIZ_FILE_MAX = 0xC8;  // file 200, highest playable
static const uint8_t MEDEAWIZ_CMD_SLEEP = 0xC9;
static const uint8_t MEDEAWIZ_CMD_WAKE = 0xCA;
static const uint8_t MEDEAWIZ_CMD_REQUEST_FILE_COUNT = 0xCB;
static const uint8_t MEDEAWIZ_CMD_REQUEST_CURRENT_FILE = 0xCC;
static const uint8_t MEDEAWIZ_ADDR_MIN = 0xE0;  // 0xE0 = broadcast
static const uint8_t MEDEAWIZ_ADDR_MAX = 0xEF;
static const uint8_t MEDEAWIZ_CMD_FULL_VOLUME = 0xE7;
static const uint8_t MEDEAWIZ_CMD_MUTE = 0xE8;
static const uint8_t MEDEAWIZ_CMD_VOLUME_UP = 0xE9;
static const uint8_t MEDEAWIZ_CMD_VOLUME_DOWN = 0xEA;
static const uint8_t MEDEAWIZ_FEEDBACK_END_OF_FILE = 0xEE;
static const uint8_t MEDEAWIZ_CMD_PLAY = 0xEF;
static const uint8_t MEDEAWIZ_CMD_PAUSE = 0xF0;
static const uint8_t MEDEAWIZ_CMD_FAST_REWIND = 0xF1;
static const uint8_t MEDEAWIZ_CMD_FAST_FORWARD = 0xF2;
static const uint8_t MEDEAWIZ_CMD_PREVIOUS = 0xF3;
static const uint8_t MEDEAWIZ_CMD_NEXT = 0xF4;
static const uint8_t MEDEAWIZ_CMD_REQUEST_POSITION = 0xF5;
static const uint8_t MEDEAWIZ_CMD_SEEK = 0xF6;
static const uint8_t MEDEAWIZ_CMD_GET_DURATION = 0xF7;
static const uint8_t MEDEAWIZ_CMD_SELECT_LOOP_FILE = 0xFC;

// How long (ms) to keep expecting the echo of a written byte in Full Reporting.
// Echoes return within a few ms at any baud; after this the queue is dropped so
// an echo that never arrived cannot swallow a later genuine report.
static const uint32_t MEDEAWIZ_ECHO_WINDOW_MS = 250;

// Serial Feedback mode set in the Sprite's Setup Menu (page 15 of the manual).
// Only FULL reporting echoes every received command, so the parser uses this to
// discard the echo of a request command instead of parsing it as the reply.
enum MedeaWizFeedbackMode : uint8_t {
  MEDEAWIZ_REPORT_FULL = 0,
  MEDEAWIZ_REPORT_MINIMAL = 1,
  MEDEAWIZ_REPORT_COMMAND_REQUEST = 2,
};

class MedeaWiz : public uart::UARTDevice, public Component {
 public:
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override;

  // Optional multi-drop address (0xE0-0xEF). When set, it is sent before every
  // command so several Sprites can share one serial bus.
  void set_address(uint8_t address) {
    this->address_ = address;
    this->use_address_ = true;
  }

  // Must match the Sprite's "Serial Feedback" Setup Menu value (default Full).
  void set_feedback_mode(MedeaWizFeedbackMode mode) {
    this->feedback_mode_ = mode;
  }

  // Playback / transport commands. File numbers are validated against 0-200
  // (a wider type than uint8_t so an out-of-range templated value is rejected
  // instead of silently wrapping).
  void play_file(uint16_t file);
  void set_loop_file(uint16_t file);
  void seek(uint32_t position_ms);
  void play() { this->send_command(MEDEAWIZ_CMD_PLAY); }
  void pause() { this->send_command(MEDEAWIZ_CMD_PAUSE); }
  void next() { this->send_command(MEDEAWIZ_CMD_NEXT); }
  void previous() { this->send_command(MEDEAWIZ_CMD_PREVIOUS); }
  void fast_forward() { this->send_command(MEDEAWIZ_CMD_FAST_FORWARD); }
  void fast_rewind() { this->send_command(MEDEAWIZ_CMD_FAST_REWIND); }
  void sleep() { this->send_command(MEDEAWIZ_CMD_SLEEP); }
  void wake() { this->send_command(MEDEAWIZ_CMD_WAKE); }
  void mute() { this->send_command(MEDEAWIZ_CMD_MUTE); }
  void full_volume() { this->send_command(MEDEAWIZ_CMD_FULL_VOLUME); }
  void volume_up() { this->send_command(MEDEAWIZ_CMD_VOLUME_UP); }
  void volume_down() { this->send_command(MEDEAWIZ_CMD_VOLUME_DOWN); }

  // Status requests. The reply is parsed in loop() and stored; the *_ms /
  // count getters below are valid once the reply arrives.
  void request_position() { this->send_command(MEDEAWIZ_CMD_REQUEST_POSITION); }
  void request_duration() { this->send_command(MEDEAWIZ_CMD_GET_DURATION); }
  void request_file_count() {
    this->send_command(MEDEAWIZ_CMD_REQUEST_FILE_COUNT);
  }
  void request_current_file() {
    this->send_command(MEDEAWIZ_CMD_REQUEST_CURRENT_FILE);
  }

  // Send a single raw command byte (prefixed with the address if configured).
  // Useful for any command not covered by the helpers above.
  void send_command(uint8_t command);

  // Last values reported by the Sprite. current_file() is 0xFF until the Sprite
  // first reports a file number.
  uint8_t current_file() const { return this->current_file_; }
  uint8_t file_count() const { return this->file_count_; }
  uint32_t position_ms() const { return this->position_ms_; }
  uint32_t duration_ms() const { return this->duration_ms_; }

  void add_on_file_callback(std::function<void(uint8_t)>&& callback) {
    this->on_file_callback_.add(std::move(callback));
  }
  void add_on_end_of_file_callback(std::function<void()>&& callback) {
    this->on_end_of_file_callback_.add(std::move(callback));
  }

 protected:
  // Write a command sequence, prefixing the address byte when configured.
  void write_command_(const uint8_t* data, size_t len);
  // Feed one received byte through the feedback parser.
  void handle_byte_(uint8_t byte);
  // Remember one outgoing byte so its Full-Reporting echo can be discarded.
  void queue_echo_(uint8_t byte);

  // The Sprite replies to a few requests with a header byte followed by a fixed
  // number of payload bytes (high byte first). This is the parser state.
  enum class FeedbackState : uint8_t { IDLE, FILE_COUNT, POSITION, DURATION };
  FeedbackState state_{FeedbackState::IDLE};
  uint8_t payload_[4];
  uint8_t payload_pos_{0};
  uint8_t payload_len_{0};

  uint8_t address_{0};
  bool use_address_{false};

  MedeaWizFeedbackMode feedback_mode_{MEDEAWIZ_REPORT_FULL};
  // FIFO of every byte written while in Full Reporting whose echo we still
  // expect to discard (address prefix + opcode + operands of each command), so
  // operands are never parsed as file reports or reply headers. A queue, not a
  // single byte, so back-to-back commands don't clobber each other; entries are
  // dropped after MEDEAWIZ_ECHO_WINDOW_MS so a missing echo can't swallow a
  // later genuine report.
  static constexpr uint8_t PENDING_ECHO_CAPACITY = 16;
  uint8_t pending_echo_[PENDING_ECHO_CAPACITY]{};
  uint8_t pending_echo_head_{0};
  uint8_t pending_echo_count_{0};
  uint32_t pending_echo_time_{0};

  uint8_t current_file_{0xFF};
  uint8_t file_count_{0};
  uint32_t position_ms_{0};
  uint32_t duration_ms_{0};

  CallbackManager<void(uint8_t)> on_file_callback_;
  CallbackManager<void()> on_end_of_file_callback_;
};

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

#define MEDEAWIZ_SIMPLE_ACTION(ACTION_CLASS, ACTION_METHOD)                \
  template <typename... Ts>                                                \
  class ACTION_CLASS : /* NOLINT */                                        \
                       public Action<Ts...>,                               \
                       public Parented<MedeaWiz> {                         \
    void play(const Ts&... x) override { this->parent_->ACTION_METHOD(); } \
  };

MEDEAWIZ_SIMPLE_ACTION(PlayAction, play)
MEDEAWIZ_SIMPLE_ACTION(PauseAction, pause)
MEDEAWIZ_SIMPLE_ACTION(NextAction, next)
MEDEAWIZ_SIMPLE_ACTION(PreviousAction, previous)
MEDEAWIZ_SIMPLE_ACTION(FastForwardAction, fast_forward)
MEDEAWIZ_SIMPLE_ACTION(FastRewindAction, fast_rewind)
MEDEAWIZ_SIMPLE_ACTION(SleepAction, sleep)
MEDEAWIZ_SIMPLE_ACTION(WakeAction, wake)
MEDEAWIZ_SIMPLE_ACTION(MuteAction, mute)
MEDEAWIZ_SIMPLE_ACTION(FullVolumeAction, full_volume)
MEDEAWIZ_SIMPLE_ACTION(VolumeUpAction, volume_up)
MEDEAWIZ_SIMPLE_ACTION(VolumeDownAction, volume_down)
MEDEAWIZ_SIMPLE_ACTION(RequestPositionAction, request_position)
MEDEAWIZ_SIMPLE_ACTION(RequestDurationAction, request_duration)
MEDEAWIZ_SIMPLE_ACTION(RequestFileCountAction, request_file_count)
MEDEAWIZ_SIMPLE_ACTION(RequestCurrentFileAction, request_current_file)

template <typename... Ts>
class PlayFileAction : public Action<Ts...>, public Parented<MedeaWiz> {
 public:
  TEMPLATABLE_VALUE(uint16_t, file)
  void play(const Ts&... x) override {
    this->parent_->play_file(this->file_.value(x...));
  }
};

template <typename... Ts>
class SetLoopFileAction : public Action<Ts...>, public Parented<MedeaWiz> {
 public:
  TEMPLATABLE_VALUE(uint16_t, file)
  void play(const Ts&... x) override {
    this->parent_->set_loop_file(this->file_.value(x...));
  }
};

template <typename... Ts>
class SeekAction : public Action<Ts...>, public Parented<MedeaWiz> {
 public:
  TEMPLATABLE_VALUE(uint32_t, position)
  void play(const Ts&... x) override {
    this->parent_->seek(this->position_.value(x...));
  }
};

template <typename... Ts>
class SendCommandAction : public Action<Ts...>, public Parented<MedeaWiz> {
 public:
  TEMPLATABLE_VALUE(uint8_t, command)
  void play(const Ts&... x) override {
    this->parent_->send_command(this->command_.value(x...));
  }
};

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

class FileTrigger : public Trigger<uint8_t> {
 public:
  explicit FileTrigger(MedeaWiz* parent) {
    parent->add_on_file_callback([this](uint8_t file) { this->trigger(file); });
  }
};

class EndOfFileTrigger : public Trigger<> {
 public:
  explicit EndOfFileTrigger(MedeaWiz* parent) {
    parent->add_on_end_of_file_callback([this]() { this->trigger(); });
  }
};

}  // namespace medeawiz
}  // namespace esphome
