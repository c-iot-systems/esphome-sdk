"""ESPHome phone component for matrix keypad with hook and password."""

from typing import Any

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome import automation, pins
from esphome.components import binary_sensor, text_sensor
from esphome.const import CONF_ID, CONF_PIN, CONF_TRIGGER_ID

CODEOWNERS = ["Arthur Komatsu"]
# phone.h unconditionally includes binary_sensor.h and holds a binary_sensor::BinarySensor*
# member (the optional hook sensor), so binary_sensor's C++ must be built whenever phone is used —
# even when no hook_sensor is configured. Importing the Python module for the schema does not load
# its C++ resources, so AUTO_LOAD it, or a phone with no hook sensor fails to compile. (text_sensor
# stays optional: it is guarded by #ifdef USE_TEXT_SENSOR and only referenced when configured.)
AUTO_LOAD = ["binary_sensor"]
MULTI_CONF = True

CONF_ROWS = "rows"
CONF_COLUMNS = "columns"
CONF_KEYS = "keys"
CONF_DEBOUNCE_TIME = "debounce_time"
CONF_HOOK_SENSOR = "hook_sensor"
CONF_SEQUENCE_TIMEOUT = "sequence_timeout"
CONF_ON_HOOK_PRESS = "on_hook_press"
CONF_ON_HOOK_RELEASE = "on_hook_release"
CONF_ON_KEY_PRESS = "on_key_press"
CONF_ENTER_KEYS = "enter_keys"
CONF_CLEAR_KEYS = "clear_keys"
CONF_PASSWORDS = "passwords"
CONF_PASSWORD = "password"  # noqa: S105  # nosec B105
CONF_TEXT_SENSOR = "text_sensor"
CONF_ON_PASSWORD_RIGHT = "on_password_right"  # noqa: S105  # nosec B105
CONF_ON_PASSWORD_WRONG = "on_password_wrong"  # noqa: S105  # nosec B105

phone_ns = cg.esphome_ns.namespace("phone")
Phone = phone_ns.class_("Phone", cg.Component)

HookPressTrigger = phone_ns.class_(
    "HookPressTrigger",
    automation.Trigger.template(),
)
HookReleaseTrigger = phone_ns.class_(
    "HookReleaseTrigger",
    automation.Trigger.template(),
)
KeyPressTrigger = phone_ns.class_(
    "KeyPressTrigger",
    automation.Trigger.template(cg.uint8),
)
PasswordRightTrigger = phone_ns.class_(
    "PasswordRightTrigger",
    automation.Trigger.template(cg.std_string),
)
PasswordWrongTrigger = phone_ns.class_(
    "PasswordWrongTrigger",
    automation.Trigger.template(cg.std_string),
)


def check_keys(obj: dict[str, Any]) -> dict[str, Any]:
    """Validate that the number of keys matches rows * columns."""
    if CONF_KEYS in obj:
        n_rows = len(obj[CONF_ROWS]) if CONF_ROWS in obj else 0
        n_cols = len(obj[CONF_COLUMNS])
        expected = n_rows * n_cols if n_rows > 0 else n_cols
        if len(obj[CONF_KEYS]) != expected:
            n_keys = len(obj[CONF_KEYS])
            msg = f"Number of keys ({n_keys}) must equal {expected}"
            raise cv.Invalid(msg)
    return obj


PASSWORD_SCHEMA = cv.Schema(
    {
        cv.Required(CONF_PASSWORD): cv.string,
        cv.Optional(CONF_TEXT_SENSOR): cv.use_id(text_sensor.TextSensor),
        cv.Optional(CONF_ON_PASSWORD_RIGHT): automation.validate_automation(
            {
                cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(PasswordRightTrigger),
            },
        ),
        cv.Optional(CONF_ON_PASSWORD_WRONG): automation.validate_automation(
            {
                cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(PasswordWrongTrigger),
            },
        ),
    },
)

CONFIG_SCHEMA = cv.All(
    cv.COMPONENT_SCHEMA.extend(
        {
            cv.GenerateID(): cv.declare_id(Phone),
            cv.Optional(CONF_ROWS): cv.All(
                cv.ensure_list({cv.Required(CONF_PIN): pins.gpio_output_pin_schema}),
                cv.Length(min=1),
            ),
            cv.Required(CONF_COLUMNS): cv.All(
                cv.ensure_list({cv.Required(CONF_PIN): pins.gpio_input_pin_schema}),
                cv.Length(min=1),
            ),
            cv.Required(CONF_KEYS): cv.string,
            cv.Optional(
                CONF_DEBOUNCE_TIME,
                default="1ms",
            ): cv.positive_time_period_milliseconds,
            cv.Optional(CONF_HOOK_SENSOR): cv.use_id(binary_sensor.BinarySensor),
            cv.Optional(
                CONF_SEQUENCE_TIMEOUT,
                default="3s",
            ): cv.positive_time_period_milliseconds,
            cv.Optional(CONF_ON_HOOK_PRESS): automation.validate_automation(
                {
                    cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(HookPressTrigger),
                },
            ),
            cv.Optional(CONF_ON_HOOK_RELEASE): automation.validate_automation(
                {
                    cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(HookReleaseTrigger),
                },
            ),
            cv.Optional(CONF_ON_KEY_PRESS): automation.validate_automation(
                {
                    cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(KeyPressTrigger),
                },
            ),
            cv.Optional(CONF_ENTER_KEYS): cv.string,
            cv.Optional(CONF_CLEAR_KEYS): cv.string,
            cv.Optional(CONF_PASSWORDS): cv.ensure_list(PASSWORD_SCHEMA),
        },
    ),
    check_keys,
)


async def _generate_password_code(
    var: cg.Pvariable,
    i: int,
    pwd_conf: dict[str, Any],
) -> None:
    """Generate code for a single password entry."""
    cg.add(var.add_password(pwd_conf[CONF_PASSWORD]))

    if CONF_TEXT_SENSOR in pwd_conf:
        ts = await cg.get_variable(pwd_conf[CONF_TEXT_SENSOR])
        cg.add(var.set_password_text_sensor(i, ts))

    for conf in pwd_conf.get(CONF_ON_PASSWORD_RIGHT, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var, i)
        await automation.build_automation(
            trigger,
            [(cg.std_string, "x")],
            conf,
        )

    for conf in pwd_conf.get(CONF_ON_PASSWORD_WRONG, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var, i)
        await automation.build_automation(
            trigger,
            [(cg.std_string, "x")],
            conf,
        )


async def _generate_optional_settings(
    var: cg.Pvariable,
    config: dict[str, Any],
) -> None:
    """Generate code for optional phone settings."""
    if CONF_HOOK_SENSOR in config:
        hook_sensor = await cg.get_variable(config[CONF_HOOK_SENSOR])
        cg.add(var.set_hook_sensor(hook_sensor))

    cg.add(var.set_sequence_timeout(config[CONF_SEQUENCE_TIMEOUT]))

    if CONF_ENTER_KEYS in config:
        cg.add(var.set_enter_keys(config[CONF_ENTER_KEYS]))

    if CONF_CLEAR_KEYS in config:
        cg.add(var.set_clear_keys(config[CONF_CLEAR_KEYS]))


async def to_code(config: dict[str, Any]) -> None:
    """Generate component code."""
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)

    if CONF_ROWS in config:
        row_pins = []
        for conf in config[CONF_ROWS]:
            pin = await cg.gpio_pin_expression(conf[CONF_PIN])
            row_pins.append(pin)
        cg.add(var.set_rows(row_pins))

    col_pins = []
    for conf in config[CONF_COLUMNS]:
        pin = await cg.gpio_pin_expression(conf[CONF_PIN])
        col_pins.append(pin)
    cg.add(var.set_columns(col_pins))

    cg.add(var.set_keys(config[CONF_KEYS]))
    cg.add(var.set_debounce_time(config[CONF_DEBOUNCE_TIME]))

    await _generate_optional_settings(var, config)

    for conf in config.get(CONF_ON_HOOK_PRESS, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(trigger, [], conf)

    for conf in config.get(CONF_ON_HOOK_RELEASE, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(trigger, [], conf)

    for conf in config.get(CONF_ON_KEY_PRESS, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(
            trigger,
            [(cg.uint8, "x")],
            conf,
        )

    for i, pwd_conf in enumerate(config.get(CONF_PASSWORDS, [])):
        await _generate_password_code(var, i, pwd_conf)
