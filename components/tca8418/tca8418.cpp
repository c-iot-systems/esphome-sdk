#include "tca8418.h"

#include "esphome/core/log.h"

namespace esphome {
namespace tca8418 {

static const char* const TAG = "tca8418";

void TCA8418Component::setup() {
  ESP_LOGCONFIG(TAG, "Setting up TCA8418...");

  // Enable auto-increment so multi-byte read/write access consecutive registers
  if (!this->write_byte(REG_CFG, CFG_AI)) {
    ESP_LOGE(TAG, "TCA8418 not available under 0x%02X", this->address_);
    this->mark_failed();
    return;
  }

  // Set all 18 pins to GPIO mode (KP_GPIO: 0=GPIO, 1=keypad)
  uint8_t zeros[3] = {0, 0, 0};
  if (!this->write_bytes(REG_KP_GPIO1, zeros, 3)) {
    this->mark_failed();
    return;
  }

  // Disable debouncing for all GPIO pins so GPIO_DAT_STAT returns real-time
  // values (DEBOUNCE_DIS: 0=debounce enabled [default], 1=debounce disabled)
  uint8_t all_ones[3] = {0xFF, 0xFF, 0xFF};
  if (!this->write_bytes(REG_DEBOUNCE_DIS1, all_ones, 3)) {
    this->mark_failed();
    return;
  }

  // Read initial output state
  uint8_t data[3] = {0, 0, 0};
  if (!this->read_bytes(REG_GPIO_DAT_OUT1, data, 3)) {
    this->mark_failed();
    return;
  }
  this->output_mask_ =
      (uint32_t(data[2]) << 16) | (uint32_t(data[1]) << 8) | uint32_t(data[0]);

  // Read initial direction
  if (!this->read_bytes(REG_GPIO_DIR1, data, 3)) {
    this->mark_failed();
    return;
  }
  // TCA8418 direction register: 0 = input, 1 = output (same as mode_mask_)
  this->mode_mask_ = ((uint32_t(data[2]) << 16) | (uint32_t(data[1]) << 8) |
                      uint32_t(data[0])) &
                     0x3FFFF;

  // Read initial pull-up state (register: 0=enabled, 1=disabled; invert for our
  // mask)
  if (!this->read_bytes(REG_GPIO_PULL1, data, 3)) {
    this->mark_failed();
    return;
  }
  this->pullup_mask_ = (~((uint32_t(data[2]) << 16) | (uint32_t(data[1]) << 8) |
                          uint32_t(data[0]))) &
                       0x3FFFF;

  // Read initial input state
  this->read_gpio_();
}

void TCA8418Component::loop() {
  // Invalidating the cache every pass made the next digital_read() go to the
  // bus, so the expander was read on every loop iteration -- about 62 times a
  // second. Measured on an idle bench that was 8.7% of all main-loop time at
  // the 50kHz default, and 62 chances a second for a read to be caught by a
  // network stall. Nothing downstream can use that rate: rooms debounce these
  // inputs by 120-150ms, so 20Hz is already 6x faster than the filters resolve.
  const uint32_t now = millis();
  if (now - this->last_poll_ms_ < this->poll_interval_ms_)
    return;
  this->last_poll_ms_ = now;
  this->reset_pin_cache_();
}

void TCA8418Component::dump_config() {
  ESP_LOGCONFIG(TAG, "TCA8418:");
  LOG_I2C_DEVICE(this)
  if (this->is_failed()) {
    ESP_LOGE(TAG, ESP_LOG_MSG_COMM_FAIL);
    return;
  }
  // Re-read registers to verify what's actually on the chip
  uint8_t data[3];
  this->read_bytes(REG_KP_GPIO1, data, 3);
  ESP_LOGCONFIG(TAG, "  KP_GPIO (0=GPIO,1=KP): %02X %02X %02X", data[0],
                data[1], data[2]);
  this->read_bytes(REG_GPIO_DIR1, data, 3);
  ESP_LOGCONFIG(TAG, "  GPIO_DIR (0=in,1=out): %02X %02X %02X", data[0],
                data[1], data[2]);
  this->read_bytes(REG_GPIO_PULL1, data, 3);
  ESP_LOGCONFIG(TAG, "  GPIO_PULL (0=en,1=dis): %02X %02X %02X", data[0],
                data[1], data[2]);
  this->read_bytes(REG_GPIO_DAT_STAT1, data, 3);
  ESP_LOGCONFIG(TAG, "  GPIO_DAT_STAT: %02X %02X %02X", data[0], data[1],
                data[2]);
  this->read_bytes(REG_GPIO_DAT_OUT1, data, 3);
  ESP_LOGCONFIG(TAG, "  GPIO_DAT_OUT: %02X %02X %02X", data[0], data[1],
                data[2]);
}

float TCA8418Component::get_setup_priority() const {
  return setup_priority::IO;
}

void TCA8418Component::pin_mode(uint8_t pin, gpio::Flags flags) {
  if (flags == gpio::FLAG_OUTPUT) {
    this->mode_mask_ |= (1 << pin);
    this->pullup_mask_ &= ~(1 << pin);
  } else {
    // Input mode
    this->mode_mask_ &= ~(1 << pin);
    if (flags & gpio::FLAG_PULLUP) {
      this->pullup_mask_ |= (1 << pin);
    } else {
      this->pullup_mask_ &= ~(1 << pin);
    }
  }
  this->write_pin_modes_();
  this->write_pullups_();
  this->reset_pin_cache_();
}

bool TCA8418Component::digital_read_hw(uint8_t pin) {
  return this->read_gpio_();
}

bool TCA8418Component::digital_read_cache(uint8_t pin) {
  return this->input_mask_ & (1 << pin);
}

void TCA8418Component::digital_write_hw(uint8_t pin, bool value) {
  if (value) {
    this->output_mask_ |= (1 << pin);
  } else {
    this->output_mask_ &= ~(1 << pin);
  }
  this->write_gpio_();
  // Invalidate read cache so the next digital_read() goes to hardware.
  // This is critical for manual matrix scanning: after driving a row LOW,
  // column reads must reflect the new output state, not stale cached data.
  this->reset_pin_cache_();
}

bool TCA8418Component::read_gpio_() {
  if (this->is_failed()) return false;
  uint8_t data[3];
  if (!this->read_bytes(REG_GPIO_DAT_STAT1, data, 3)) {
    this->status_set_warning();
    return false;
  }
  this->input_mask_ =
      (uint32_t(data[2]) << 16) | (uint32_t(data[1]) << 8) | uint32_t(data[0]);
  this->status_clear_warning();
  return true;
}

bool TCA8418Component::write_gpio_() {
  if (this->is_failed()) return false;
  uint8_t data[3];
  data[0] = this->output_mask_;
  data[1] = this->output_mask_ >> 8;
  data[2] = this->output_mask_ >> 16;
  if (!this->write_bytes(REG_GPIO_DAT_OUT1, data, 3)) {
    this->status_set_warning();
    return false;
  }
  this->status_clear_warning();
  return true;
}

bool TCA8418Component::write_pin_modes_() {
  if (this->is_failed()) return false;
  // TCA8418 direction register: 0 = input, 1 = output (same as mode_mask_)
  uint8_t data[3];
  data[0] = this->mode_mask_;
  data[1] = this->mode_mask_ >> 8;
  data[2] = this->mode_mask_ >> 16;
  if (!this->write_bytes(REG_GPIO_DIR1, data, 3)) {
    this->status_set_warning();
    return false;
  }
  this->status_clear_warning();
  return true;
}

bool TCA8418Component::write_pullups_() {
  if (this->is_failed()) return false;
  // TCA8418 pull-up register: 0 = pull-up enabled, 1 = pull-up disabled
  // Our pullup_mask_: 1 = enabled, 0 = disabled (inverted from register)
  uint32_t pull_reg = (~this->pullup_mask_) & 0x3FFFF;
  uint8_t data[3];
  data[0] = pull_reg;
  data[1] = pull_reg >> 8;
  data[2] = pull_reg >> 16;
  if (!this->write_bytes(REG_GPIO_PULL1, data, 3)) {
    this->status_set_warning();
    return false;
  }
  this->status_clear_warning();
  return true;
}

void TCA8418GPIOPin::setup() { this->pin_mode(this->flags_); }
void TCA8418GPIOPin::pin_mode(gpio::Flags flags) {
  this->parent_->pin_mode(this->pin_, flags);
}
bool TCA8418GPIOPin::digital_read() {
  return this->parent_->digital_read(this->pin_) != this->inverted_;
}
void TCA8418GPIOPin::digital_write(bool value) {
  this->parent_->digital_write(this->pin_, value != this->inverted_);
}
size_t TCA8418GPIOPin::dump_summary(char* buffer, size_t len) const {
  return buf_append_printf(buffer, len, 0, "%u via TCA8418", this->pin_);
}

}  // namespace tca8418
}  // namespace esphome
