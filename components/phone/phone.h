#pragma once

#include <string>
#include <vector>

#include "esphome/components/binary_sensor/binary_sensor.h"
#include "esphome/core/automation.h"
#include "esphome/core/component.h"
#include "esphome/core/hal.h"
#include "esphome/core/helpers.h"

#ifdef USE_TEXT_SENSOR
#include "esphome/components/text_sensor/text_sensor.h"
#endif

namespace esphome {
namespace phone {

struct PasswordEntry {
  // Templatable rather than a plain string so a password can be read at match
  // time from another entity — typically a `text:` the operator edits from the
  // platform. A literal in YAML still compiles to a constant, so the cost is
  // only paid by configs that ask for it.
  TemplatableValue<std::string> password;
#ifdef USE_TEXT_SENSOR
  text_sensor::TextSensor* text_sensor{nullptr};
#endif
  CallbackManager<void(std::string)> on_right;
  CallbackManager<void(std::string)> on_wrong;
};

class Phone : public Component {
 public:
  void setup() override;
  void loop() override;
  void dump_config() override;
  float get_setup_priority() const override;

  void set_rows(std::vector<GPIOPin*> pins) { rows_ = std::move(pins); }
  void set_columns(std::vector<GPIOPin*> pins) { columns_ = std::move(pins); }
  void set_keys(std::string keys) { keys_ = std::move(keys); }
  void set_debounce_time(uint32_t debounce_time) {
    debounce_time_ = debounce_time;
  }
  void set_hook_sensor(binary_sensor::BinarySensor* sensor) {
    hook_sensor_ = sensor;
  }
  void set_sequence_timeout(uint32_t timeout) { sequence_timeout_ = timeout; }
  void set_enter_keys(std::string keys) { enter_keys_ = std::move(keys); }
  void set_clear_keys(std::string keys) { clear_keys_ = std::move(keys); }

  void add_password(TemplatableValue<std::string> password) {
    // PasswordEntry holds CallbackManagers, which are move-only, so the entry
    // must be constructed in place instead of copied in.
    passwords_.emplace_back();
    passwords_.back().password = std::move(password);
  }

  // Submit and clear the accumulated input from outside the keypad. `enter_keys`
  // and `clear_keys` only cover keys on the phone's own matrix; a device whose
  // enter button is a separate GPIO (or whose reset is driven by an automation)
  // has no key to name, and validate_input_() / clear_input_() are protected.
  // submit() matches the enter-key path exactly, including ignoring empty input.
  void submit() {
    if (this->input_.empty()) {
      return;
    }
    this->validate_input_();
    this->clear_input_();
  }
  void clear() { this->clear_input_(); }
#ifdef USE_TEXT_SENSOR
  void set_password_text_sensor(int index, text_sensor::TextSensor* ts) {
    passwords_[index].text_sensor = ts;
  }
#endif

  void add_on_hook_press_callback(std::function<void()>&& callback) {
    on_hook_press_.add(std::move(callback));
  }
  void add_on_hook_release_callback(std::function<void()>&& callback) {
    on_hook_release_.add(std::move(callback));
  }
  void add_on_key_press_callback(std::function<void(uint8_t)>&& callback) {
    on_key_press_.add(std::move(callback));
  }
  void add_on_password_right_callback(
      int index, std::function<void(std::string)>&& callback) {
    passwords_[index].on_right.add(std::move(callback));
  }
  void add_on_password_wrong_callback(
      int index, std::function<void(std::string)>&& callback) {
    passwords_[index].on_wrong.add(std::move(callback));
  }
  void add_on_no_match_callback(std::function<void(std::string)>&& callback) {
    on_no_match_.add(std::move(callback));
  }

 protected:
  int scan_keypad_();
  void process_key_(uint8_t key);
  void check_timeout_();
  void validate_input_();
  void clear_input_();
  void publish_input_();

  std::vector<GPIOPin*> rows_;
  std::vector<GPIOPin*> columns_;
  std::string keys_;
  uint32_t debounce_time_{1};

  int pressed_key_{-1};
  int active_key_{-1};
  uint32_t active_start_{0};
  uint32_t last_scan_time_{0};

  binary_sensor::BinarySensor* hook_sensor_{nullptr};
  bool hook_state_{true};

  std::string input_;
  uint32_t last_key_time_{0};
  uint32_t sequence_timeout_{3000};
  std::string enter_keys_;
  std::string clear_keys_;

  std::vector<PasswordEntry> passwords_;

  CallbackManager<void()> on_hook_press_;
  CallbackManager<void()> on_hook_release_;
  CallbackManager<void(uint8_t)> on_key_press_;
  CallbackManager<void(std::string)> on_no_match_;
};

class HookPressTrigger : public Trigger<> {
 public:
  explicit HookPressTrigger(Phone* phone) {
    phone->add_on_hook_press_callback([this]() { this->trigger(); });
  }
};

class HookReleaseTrigger : public Trigger<> {
 public:
  explicit HookReleaseTrigger(Phone* phone) {
    phone->add_on_hook_release_callback([this]() { this->trigger(); });
  }
};

class KeyPressTrigger : public Trigger<uint8_t> {
 public:
  explicit KeyPressTrigger(Phone* phone) {
    phone->add_on_key_press_callback(
        [this](uint8_t key) { this->trigger(key); });
  }
};

class PasswordRightTrigger : public Trigger<std::string> {
 public:
  PasswordRightTrigger(Phone* phone, int index) {
    phone->add_on_password_right_callback(
        index, [this](std::string input) { this->trigger(std::move(input)); });
  }
};

class PasswordWrongTrigger : public Trigger<std::string> {
 public:
  PasswordWrongTrigger(Phone* phone, int index) {
    phone->add_on_password_wrong_callback(
        index, [this](std::string input) { this->trigger(std::move(input)); });
  }
};

// Fires once per submission that matched no password at all. The per-entry
// PasswordWrongTrigger fires once for every entry the input did not match, so
// with N passwords configured a single wrong code fires it N times — rarely
// what a caller wants when the passwords are alternatives rather than
// independent locks.
class NoMatchTrigger : public Trigger<std::string> {
 public:
  explicit NoMatchTrigger(Phone* phone) {
    phone->add_on_no_match_callback(
        [this](std::string input) { this->trigger(std::move(input)); });
  }
};

template <typename... Ts>
class SubmitAction : public Action<Ts...>, public Parented<Phone> {
 public:
  void play(Ts... x) override { this->parent_->submit(); }
};

template <typename... Ts>
class ClearAction : public Action<Ts...>, public Parented<Phone> {
 public:
  void play(Ts... x) override { this->parent_->clear(); }
};

}  // namespace phone
}  // namespace esphome
