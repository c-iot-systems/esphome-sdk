"""ESPHome component for the Serial API — USB TX/RX control of SDK devices (AIOT-131).

Exposes every non-denied entity of the device on a UART with a self-describing line protocol, so an
integrator can read sensors and (via the SER-2 write path) drive actuators without speaking MQTT.
Opt-in: no device is changed until a room imports the module. The pins are chosen per room, so this
component takes a `uart:` and never defaults one.
"""

from typing import Any

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import uart
from esphome.const import CONF_ID
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

# The protocol needs both a TX line (to answer) and an RX line (to receive commands).
FINAL_VALIDATE_SCHEMA = uart.final_validate_device_schema(
    "serial_api", require_tx=True, require_rx=True
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
