"""TCA8418 I2C GPIO expander component for ESPHome."""

from typing import Any

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome import pins
from esphome.components import i2c
from esphome.const import (
    CONF_ID,
    CONF_INPUT,
    CONF_INVERTED,
    CONF_MODE,
    CONF_NUMBER,
    CONF_OUTPUT,
    CONF_PULLUP,
)

AUTO_LOAD = ["gpio_expander"]
DEPENDENCIES = ["i2c"]
MULTI_CONF = True

tca8418_ns = cg.esphome_ns.namespace("tca8418")

TCA8418Component = tca8418_ns.class_("TCA8418Component", cg.Component, i2c.I2CDevice)
TCA8418GPIOPin = tca8418_ns.class_("TCA8418GPIOPin", cg.GPIOPin)

CONF_TCA8418 = "tca8418"
CONF_POLL_INTERVAL = "poll_interval"
CONFIG_SCHEMA = (
    cv.Schema(
        {
            cv.Required(CONF_ID): cv.declare_id(TCA8418Component),
            # How often loop() may invalidate the read cache. Before this
            # existed the expander was read every loop pass (~62Hz), which cost
            # 8.7% of main-loop time on an idle bench and gave a network stall
            # 62 chances a second to land on an I2C read. Rooms debounce these
            # inputs by 120-150ms, so the default 50ms is still 6x faster than
            # anything downstream can resolve.
            cv.Optional(
                CONF_POLL_INTERVAL, default="50ms"
            ): cv.positive_time_period_milliseconds,
        },
    )
    .extend(cv.COMPONENT_SCHEMA)
    .extend(i2c.i2c_device_schema(0x34))
)


async def to_code(config: dict[str, Any]) -> None:
    """Generate code for TCA8418 component."""
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    await i2c.register_i2c_device(var, config)
    cg.add(var.set_poll_interval(config[CONF_POLL_INTERVAL]))


def validate_mode(value: dict[str, Any]) -> dict[str, Any]:
    """Validate TCA8418 pin mode configuration."""
    if not (value[CONF_INPUT] or value[CONF_OUTPUT]):
        msg = "Mode must be either input or output"
        raise cv.Invalid(msg)
    if value[CONF_INPUT] and value[CONF_OUTPUT]:
        msg = "Mode must be either input or output"
        raise cv.Invalid(msg)
    if value[CONF_PULLUP] and not value[CONF_INPUT]:
        msg = "Pullup only available with input"
        raise cv.Invalid(msg)
    return value


TCA8418_PIN_SCHEMA = pins.gpio_base_schema(
    TCA8418GPIOPin,
    cv.int_range(min=0, max=17),
    modes=[CONF_INPUT, CONF_OUTPUT, CONF_PULLUP],
    mode_validator=validate_mode,
    invertible=True,
).extend(
    {
        cv.Required(CONF_TCA8418): cv.use_id(TCA8418Component),
    },
)


@pins.PIN_SCHEMA_REGISTRY.register(CONF_TCA8418, TCA8418_PIN_SCHEMA)  # type: ignore[untyped-decorator]
async def tca8418_pin_to_code(config: dict[str, Any]) -> Any:
    """Generate code for TCA8418 GPIO pin."""
    var = cg.new_Pvariable(config[CONF_ID])
    parent = await cg.get_variable(config[CONF_TCA8418])

    cg.add(var.set_parent(parent))

    num = config[CONF_NUMBER]
    cg.add(var.set_pin(num))
    cg.add(var.set_inverted(config[CONF_INVERTED]))
    cg.add(var.set_flags(pins.gpio_flags_expr(config[CONF_MODE])))
    return var
