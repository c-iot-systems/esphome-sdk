"""ESPHome component for the Serial API — USB TX/RX control of SDK devices (AIOT-131).

Exposes every non-denied entity of the device on a UART with a self-describing line protocol, so an
integrator can read sensors and (via the SER-2 write path) drive actuators without speaking MQTT.
Opt-in: no device is changed until a room imports the module. The pins are chosen per room, so this
component takes a `uart:` and never defaults one.
"""

from typing import Any

import esphome.codegen as cg
import esphome.config_validation as cv
import esphome.final_validate as fv
from esphome.components import uart
from esphome.const import (
    CONF_BINARY_SENSOR,
    CONF_ID,
    CONF_NUMBER,
    CONF_PIN,
    CONF_RX_PIN,
    CONF_TX_PIN,
    CONF_UART_ID,
)
from esphome.core import CORE

CODEOWNERS = ["Arthur Komatsu"]
DEPENDENCIES = ["uart"]

CONF_FIRMWARE_VERSION = "firmware_version"

serial_api_ns = cg.esphome_ns.namespace("serial_api")
SerialAPI = serial_api_ns.class_("SerialAPI", uart.UARTDevice, cg.Component)

CONFIG_SCHEMA = (
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(SerialAPI),
            # The version the HELLO banner reports. SDK rooms carry their revision in a substitution,
            # so the module threads it in as `${firmware_version}`. Optional so the component still
            # compiles standalone; when omitted the banner reports the ESPHome framework version.
            cv.Optional(CONF_FIRMWARE_VERSION): cv.string,
        }
    )
    .extend(cv.COMPONENT_SCHEMA)
    .extend(uart.UART_DEVICE_SCHEMA)
)

# Top-level config keys that are not in esphome.const. `uart` is the bus platform list; `canbus` is
# the CAN platform list — both are read from the fully-resolved config in FINAL_VALIDATE_SCHEMA.
CONF_UART = "uart"
CONF_CANBUS = "canbus"

# GPIO1 is the ESP32 UART0 TX line, which the HDS board also wires to the SW1 button. A room that puts
# the serial API on UART0 (a legal choice — modules/core.yaml frees it with logger_baud_rate 0) must
# first disable SW1, or the two fight over GPIO1. The board carries that toggle as the
# hds_v1_1_sw1_enabled substitution; when it is left enabled the SW1 binary_sensor stays on GPIO1.
_UART0_TX_GPIO = 1
_SW1_FLAG = "hds_v1_1_sw1_enabled"


def _pin_number(pin: Any) -> int | None:
    """The GPIO number of a resolved pin config. UART and gpio binary_sensor pins are pin-schema
    dicts (number under CONF_NUMBER); esp32_can's tx_pin/rx_pin resolve to a bare int."""
    if isinstance(pin, dict):
        return pin.get(CONF_NUMBER)
    if isinstance(pin, int):
        return pin
    return None


def _serial_api_uart_pins(config: dict[str, Any], full_config: Any) -> set[int]:
    """The GPIO numbers this serial_api's UART bus drives. At final-validate the uart_id reference is
    resolved to the UART hub config itself (a dict carrying tx_pin/rx_pin); the ID-lookup branch is a
    fallback for the un-resolved form. Empty if no bus is found."""
    uart_ref = config.get(CONF_UART_ID)
    hub = uart_ref if isinstance(uart_ref, dict) else None
    if hub is None:
        for candidate in full_config.get(CONF_UART, []):
            if candidate.get(CONF_ID) == uart_ref:
                hub = candidate
                break
    if hub is None:
        return set()
    return {
        n
        for n in (_pin_number(hub.get(CONF_TX_PIN)), _pin_number(hub.get(CONF_RX_PIN)))
        if n is not None
    }


def _validate_pin_conflicts(config: dict[str, Any]) -> dict[str, Any]:
    """Fail `esphome config` when the serial API's UART pins collide with a peripheral that owns them.

    Enforced here, in the component, rather than in an SDK shell script: a room in another repository
    imports the module by URL and never runs the SDK's scripts, so only the component's own validation
    reaches every consumer. Two collisions matter on the HDS board — SW1 on GPIO1, and the CAN
    transceiver — and both compare the ACTUAL configured pins, never the board name.
    """
    full_config = fv.full_config.get()
    serial_pins = _serial_api_uart_pins(config, full_config)
    if not serial_pins:
        return config

    # SW1: GPIO1 cannot serve both UART0 TX and the SW1 button.
    if _UART0_TX_GPIO in serial_pins:
        for bin_sensor in full_config.get(CONF_BINARY_SENSOR, []):
            if _pin_number(bin_sensor.get(CONF_PIN)) == _UART0_TX_GPIO:
                raise cv.Invalid(
                    f"serial_api drives GPIO{_UART0_TX_GPIO}, but a binary_sensor (SW1) is already on "
                    f"GPIO{_UART0_TX_GPIO}. GPIO{_UART0_TX_GPIO} is UART0 TX; SW1 and the serial API "
                    f"cannot share it. Disable SW1 with `{_SW1_FLAG}: false`, or move the serial API "
                    f"to the room's slot UART pins."
                )

    # CAN: the transceiver owns its pins; the serial API moves, CAN never does.
    can_pins: set[int] = set()
    for can in full_config.get(CONF_CANBUS, []):
        for opt in (CONF_TX_PIN, CONF_RX_PIN):
            n = _pin_number(can.get(opt))
            if n is not None:
                can_pins.add(n)
    collision = serial_pins & can_pins
    if collision:
        pin = sorted(collision)[0]
        raise cv.Invalid(
            f"serial_api drives GPIO{pin}, but a canbus: block already uses GPIO{pin}. CAN owns its "
            f"pins; move the serial API to free pins (typically the room's slot UART). This compares "
            f"the configured CAN tx_pin/rx_pin, not the board name."
        )
    return config


# The protocol needs both a TX line (to answer) and an RX line (to receive commands); on top of that,
# its pins must not collide with SW1 or the CAN bus (see _validate_pin_conflicts).
FINAL_VALIDATE_SCHEMA = cv.All(
    uart.final_validate_device_schema("serial_api", require_tx=True, require_rx=True),
    _validate_pin_conflicts,
)


async def to_code(config: dict[str, Any]) -> None:
    """Generate component code."""
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    await uart.register_uart_device(var, config)

    if CONF_FIRMWARE_VERSION in config:
        cg.add(var.set_firmware_version(config[CONF_FIRMWARE_VERSION]))

    # Size the ControllerRegistry StaticVector so this component can receive entity state changes,
    # mirroring components/api/__init__.py. MQTT is not a Controller, so serial_api is typically the
    # first registrant and this is what turns USE_CONTROLLER_REGISTRY on.
    CORE.register_controller()
