#include "phone.h"

#include "esphome/core/application.h"
#include "esphome/core/log.h"

namespace esphome {
namespace phone {

static const char* const TAG = "phone";

void Phone::setup() {
  for (auto* pin : this->rows_) {
    pin->setup();
    pin->digital_write(true);
  }
  for (auto* pin : this->columns_) {
    pin->setup();
  }
  ESP_LOGD(TAG, "Setup: %d rows, %d columns, mode=%s", this->rows_.size(),
           this->columns_.size(),
           this->rows_.empty() ? "individual" : "matrix");
  if (this->hook_sensor_ != nullptr) {
    this->hook_state_ = this->hook_sensor_->state;
    this->hook_sensor_->add_on_state_callback([this](bool state) {
      this->hook_state_ = state;
      if (state) {
        ESP_LOGD(TAG, "Hook pressed (on-hook)");
        this->clear_input_();
        this->on_hook_press_.call();
      } else {
        ESP_LOGD(TAG, "Hook released (off-hook)");
        this->on_hook_release_.call();
      }
    });
  }
}

void Phone::loop() {
  uint32_t now = App.get_loop_component_start_time();

  // Only scan the keypad every 20ms to reduce I2C bus traffic.
  // Frequent I2C transactions can cause RMT buffer underruns on ESP32,
  // leading to WS2812 LED flickering.
  if (now - this->last_scan_time_ < 20) {
    this->check_timeout_();
    return;
  }
  this->last_scan_time_ = now;

  int key = this->scan_keypad_();

  if (key != this->active_key_) {
    if ((this->active_key_ != -1) &&
        (this->pressed_key_ == this->active_key_)) {
      this->pressed_key_ = -1;
    }
    this->active_key_ = key;
    if (key == -1) goto check_timeout;
    this->active_start_ = now;
  }

  if ((this->pressed_key_ == key) ||
      (now - this->active_start_ < this->debounce_time_))
    goto check_timeout;

  {
    uint8_t keycode = this->keys_[key];
    ESP_LOGD(TAG, "Key '%c' pressed", keycode);
    this->process_key_(keycode);
    this->pressed_key_ = key;
  }

check_timeout:
  this->check_timeout_();
}

void Phone::dump_config() {
  ESP_LOGCONFIG(TAG, "Phone:");
  ESP_LOGCONFIG(TAG, "  Rows: %d", this->rows_.size());
  ESP_LOGCONFIG(TAG, "  Columns: %d", this->columns_.size());
  ESP_LOGCONFIG(TAG, "  Keys: %s", this->keys_.c_str());
  ESP_LOGCONFIG(TAG, "  Debounce: %u ms", this->debounce_time_);
  ESP_LOGCONFIG(TAG, "  Hook sensor: %s",
                this->hook_sensor_ != nullptr ? "configured" : "none");
  ESP_LOGCONFIG(TAG, "  Sequence timeout: %u ms", this->sequence_timeout_);
  if (!this->enter_keys_.empty())
    ESP_LOGCONFIG(TAG, "  Enter keys: %s", this->enter_keys_.c_str());
  if (!this->clear_keys_.empty())
    ESP_LOGCONFIG(TAG, "  Clear keys: %s", this->clear_keys_.c_str());
  ESP_LOGCONFIG(TAG, "  Passwords: %d", this->passwords_.size());
}

float Phone::get_setup_priority() const { return setup_priority::DATA; }

int Phone::scan_keypad_() {
  int key = -1;
  bool error = false;
  int pos = 0;

  if (this->rows_.empty()) {
    // Individual buttons mode: just read each column pin directly.
    // Take the first LOW pin and ignore the rest (noise).
    for (auto* col : this->columns_) {
      bool val = col->digital_read();
      if (!val && key == -1) {
        key = pos;
      }
      pos++;
    }
  } else {
    // Matrix scanning mode: drive one row LOW at a time, read columns.
    // Pin modes are set once at boot (rows=OUTPUT HIGH, cols=INPUT_PULLUP).
    for (auto* row : this->rows_) {
      row->digital_write(false);
      for (auto* col : this->columns_) {
        bool val = col->digital_read();
        if (!val) {
          if (key != -1) {
            error = true;
          } else {
            key = pos;
          }
        }
        pos++;
      }
      row->digital_write(true);
    }
  }

  if (error) return -1;
  return key;
}

void Phone::process_key_(uint8_t key) {
  if (this->hook_sensor_ != nullptr && this->hook_state_) {
    ESP_LOGD(TAG, "Key ignored (on-hook)");
    return;
  }

  char ch = static_cast<char>(key);

  this->on_key_press_.call(key);

  if (!this->clear_keys_.empty() &&
      this->clear_keys_.find(ch) != std::string::npos) {
    ESP_LOGD(TAG, "Clear key pressed");
    this->clear_input_();
    return;
  }

  if (!this->enter_keys_.empty() &&
      this->enter_keys_.find(ch) != std::string::npos) {
    ESP_LOGD(TAG, "Enter key pressed");
    if (!this->input_.empty()) {
      this->validate_input_();  // clears before dispatching
    }
    return;
  }

  this->input_ += ch;
  this->last_key_time_ = millis();
  this->publish_input_();
}

void Phone::check_timeout_() {
  if (this->input_.empty()) return;
  // 0 disables the timeout: the input then stands until it is submitted or
  // cleared explicitly. Without this a 0 would mean "every keypress is already
  // overdue" and validate on the very first digit, which is never what a caller
  // asking for no timeout wants. A prop whose enter button drives phone.submit
  // needs this — a player typing an 8-digit code slowly must not have it
  // submitted out from under them mid-entry.
  if (this->sequence_timeout_ == 0) return;
  if (millis() - this->last_key_time_ < this->sequence_timeout_) return;

  // Do not log the accumulated input: it is matched against configured passwords, so it is
  // sensitive. Log only its length as a non-secret diagnostic (no-secrets-in-logs).
  ESP_LOGD(TAG, "Sequence timeout after %u character(s)",
           static_cast<unsigned>(this->input_.length()));
  this->validate_input_();  // clears before dispatching
}

void Phone::validate_input_() {
  // A callback may reach straight back into this component: phone.clear and
  // phone.submit are public actions, and a password's on_right routinely starts
  // a room-reset sequence that clears the keypad. So settle all state FIRST and
  // match against an immutable snapshot.
  //
  // Reading this->input_ across the loop instead would let a callback that
  // clears it make every later password compare against "" -- rejecting a valid
  // alternative and handing on_no_match the wrong value -- and re-entering
  // submit() from a callback would recurse until the stack gave out.
  if (this->validating_) {
    ESP_LOGW(TAG, "Ignoring submission re-entered from a callback");
    return;
  }
  const std::string submitted = this->input_;
  this->validating_ = true;
  this->clear_input_();

  bool matched = false;
  for (auto& entry : this->passwords_) {
    if (submitted == entry.password.value()) {
      ESP_LOGD(TAG, "Password correct");
      matched = true;
      entry.on_right.call(submitted);
    } else {
      ESP_LOGD(TAG, "Password wrong");
      entry.on_wrong.call(submitted);
    }
  }
  if (!matched) {
    ESP_LOGD(TAG, "No password matched");
    this->on_no_match_.call(submitted);
  }
  this->validating_ = false;
}

void Phone::clear_input_() {
  this->input_.clear();
  this->publish_input_();
}

void Phone::publish_input_() {
#ifdef USE_TEXT_SENSOR
  // Publish the current input to every configured text sensor, INCLUDING when it is empty:
  // clear_input_() (clear key, enter key, timeout, on-hook) empties input_ and calls this to
  // reflect the cleared state. Returning early on an empty value would leave the previous input
  // (a password attempt) displayed indefinitely, contradicting the in-progress-input behaviour
  // and retaining sensitive data.
  for (auto& entry : this->passwords_) {
    if (entry.text_sensor != nullptr) {
      entry.text_sensor->publish_state(this->input_);
    }
  }
#endif
}

}  // namespace phone
}  // namespace esphome
