#pragma once

#include "esphome/components/gpio_expander/cached_gpio.h"
#include "esphome/components/i2c/i2c.h"
#include "esphome/core/component.h"
#include "esphome/core/hal.h"

namespace esphome {
namespace tca8418 {

// TCA8418 register offsets
static const uint8_t REG_CFG = 0x01;
static const uint8_t CFG_AI = 0x80;  // Auto-Increment for multi-byte read/write
static const uint8_t REG_INT_STAT = 0x02;
static const uint8_t REG_GPIO_DAT_STAT1 = 0x14;
static const uint8_t REG_GPIO_DAT_OUT1 = 0x17;
static const uint8_t REG_KP_GPIO1 = 0x1D;
static const uint8_t REG_GPIO_DIR1 = 0x23;
static const uint8_t REG_GPIO_PULL1 = 0x2C;
static const uint8_t REG_DEBOUNCE_DIS1 = 0x29;

// TCA8418 has 18 pins: ROW0-ROW7 (0-7), COL0-COL9 (8-17)
// We use uint32_t banks with 32 total slots so 18 pins fit in one bank
class TCA8418Component
    : public Component,
      public i2c::I2CDevice,
      public gpio_expander::CachedGpioExpander<uint32_t, 32> {
 public:
  TCA8418Component() = default;

  void setup() override;
  void loop() override;
  void dump_config() override;

  float get_setup_priority() const override;

  void pin_mode(uint8_t pin, gpio::Flags flags);

 protected:
  bool digital_read_hw(uint8_t pin) override;
  bool digital_read_cache(uint8_t pin) override;
  void digital_write_hw(uint8_t pin, bool value) override;

  bool read_gpio_();
  bool write_gpio_();
  bool write_pin_modes_();
  bool write_pullups_();

  /// Direction mask: 1 = output, 0 = input (matches TCA8418 GPIO_DIR register)
  uint32_t mode_mask_{0x00};
  /// Output state mask
  uint32_t output_mask_{0x00};
  /// Input state mask (read from hardware)
  uint32_t input_mask_{0x00};
  /// Pull-up resistor mask: 1 = enabled, 0 = disabled (TCA8418 register is
  /// inverted: 0=enabled, 1=disabled)
  uint32_t pullup_mask_{0x00};
};

class TCA8418GPIOPin : public GPIOPin {
 public:
  void setup() override;
  void pin_mode(gpio::Flags flags) override;
  bool digital_read() override;
  void digital_write(bool value) override;
  size_t dump_summary(char* buffer, size_t len) const override;

  void set_parent(TCA8418Component* parent) { parent_ = parent; }
  void set_pin(uint8_t pin) { pin_ = pin; }
  void set_inverted(bool inverted) { inverted_ = inverted; }
  void set_flags(gpio::Flags flags) { flags_ = flags; }

  gpio::Flags get_flags() const override { return this->flags_; }

 protected:
  TCA8418Component* parent_;
  uint8_t pin_;
  bool inverted_;
  gpio::Flags flags_;
};

}  // namespace tca8418
}  // namespace esphome
