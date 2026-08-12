"""ESPHome component for the MedeaWiz Sprite 4K serial video player.

Controls a MedeaWiz Sprite (model DV-S4) over its 3.5mm 4-pole TTL serial
port. The Sprite must be set to "Serial Control" mode (Control Mode in the
on-screen Setup Menu) and the UART baud rate must match the Sprite's Baud Rate
setting (default 9600, 8N1). See the Sprite 4K User Manual v4.00.
"""

from typing import Any

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome import automation
from esphome.components import uart
from esphome.const import (
    CONF_ADDRESS,
    CONF_FILE,
    CONF_ID,
    CONF_POSITION,
    CONF_TRIGGER_ID,
)

CODEOWNERS = ["Arthur Komatsu"]
DEPENDENCIES = ["uart"]
MULTI_CONF = True

CONF_COMMAND = "command"
CONF_FEEDBACK = "feedback"
CONF_ON_FILE = "on_file"
CONF_ON_END_OF_FILE = "on_end_of_file"

medeawiz_ns = cg.esphome_ns.namespace("medeawiz")
MedeaWiz = medeawiz_ns.class_("MedeaWiz", uart.UARTDevice, cg.Component)

# Mirrors the Sprite's "Serial Feedback" Setup Menu value. Must match the
# Sprite so the parser knows whether commands are echoed back (Full Reporting).
MedeaWizFeedbackMode = medeawiz_ns.enum("MedeaWizFeedbackMode")
FEEDBACK_MODES = {
    "FULL_REPORTING": MedeaWizFeedbackMode.MEDEAWIZ_REPORT_FULL,
    "MINIMAL_REPORTING": MedeaWizFeedbackMode.MEDEAWIZ_REPORT_MINIMAL,
    "COMMAND_REQUEST_ONLY": MedeaWizFeedbackMode.MEDEAWIZ_REPORT_COMMAND_REQUEST,
}

# Triggers
FileTrigger = medeawiz_ns.class_("FileTrigger", automation.Trigger.template(cg.uint8))
EndOfFileTrigger = medeawiz_ns.class_(
    "EndOfFileTrigger",
    automation.Trigger.template(),
)

# Actions with arguments
PlayFileAction = medeawiz_ns.class_("PlayFileAction", automation.Action)
SetLoopFileAction = medeawiz_ns.class_("SetLoopFileAction", automation.Action)
SeekAction = medeawiz_ns.class_("SeekAction", automation.Action)
SendCommandAction = medeawiz_ns.class_("SendCommandAction", automation.Action)

# Simple (argument-less) actions: YAML action name -> C++ Action class
SIMPLE_ACTIONS = {
    "medeawiz.play": "PlayAction",
    "medeawiz.pause": "PauseAction",
    "medeawiz.next": "NextAction",
    "medeawiz.previous": "PreviousAction",
    "medeawiz.fast_forward": "FastForwardAction",
    "medeawiz.fast_rewind": "FastRewindAction",
    "medeawiz.sleep": "SleepAction",
    "medeawiz.wake": "WakeAction",
    "medeawiz.mute": "MuteAction",
    "medeawiz.full_volume": "FullVolumeAction",
    "medeawiz.volume_up": "VolumeUpAction",
    "medeawiz.volume_down": "VolumeDownAction",
    "medeawiz.request_position": "RequestPositionAction",
    "medeawiz.request_duration": "RequestDurationAction",
    "medeawiz.request_file_count": "RequestFileCountAction",
    "medeawiz.request_current_file": "RequestCurrentFileAction",
}

CONFIG_SCHEMA = (
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(MedeaWiz),
            # Optional multi-drop address 0xE0-0xEF. When set, every command is
            # prefixed with this byte so a single bus can address many Sprites.
            cv.Optional(CONF_ADDRESS): cv.All(
                cv.hex_int,
                cv.Range(min=0xE0, max=0xEF),
            ),
            # Default matches the Sprite's factory default (Full Reporting),
            # whose echoes the parser discards (assuming whole-command echo). For
            # fully echo-free, unambiguous on_file / request feedback, set the
            # Sprite -- and this -- to minimal_reporting or command_request_only.
            cv.Optional(CONF_FEEDBACK, default="FULL_REPORTING"): cv.enum(
                FEEDBACK_MODES,
                upper=True,
            ),
            cv.Optional(CONF_ON_FILE): automation.validate_automation(
                {cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(FileTrigger)},
            ),
            cv.Optional(CONF_ON_END_OF_FILE): automation.validate_automation(
                {cv.GenerateID(CONF_TRIGGER_ID): cv.declare_id(EndOfFileTrigger)},
            ),
        },
    )
    .extend(cv.COMPONENT_SCHEMA)
    .extend(uart.UART_DEVICE_SCHEMA)
)

# The Sprite needs the tx_pin to receive commands. The baud rate is configurable
# in the Sprite's Setup Menu, so it is not constrained here.
FINAL_VALIDATE_SCHEMA = uart.final_validate_device_schema("medeawiz", require_tx=True)


async def to_code(config: dict[str, Any]) -> None:
    """Generate component code."""
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    await uart.register_uart_device(var, config)

    if CONF_ADDRESS in config:
        cg.add(var.set_address(config[CONF_ADDRESS]))

    cg.add(var.set_feedback_mode(config[CONF_FEEDBACK]))

    for conf in config.get(CONF_ON_FILE, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(trigger, [(cg.uint8, "x")], conf)

    for conf in config.get(CONF_ON_END_OF_FILE, []):
        trigger = cg.new_Pvariable(conf[CONF_TRIGGER_ID], var)
        await automation.build_automation(trigger, [], conf)


def _register_simple_action(action_name: str, class_name: str) -> None:
    """Register an argument-less MedeaWiz action."""
    action_class = medeawiz_ns.class_(class_name, automation.Action)

    @automation.register_action(  # type: ignore[untyped-decorator]
        action_name,
        action_class,
        cv.Schema({cv.GenerateID(): cv.use_id(MedeaWiz)}),
        synchronous=True,
    )
    async def simple_action_to_code(
        config: dict[str, Any],
        action_id: Any,
        template_arg: Any,
        args: Any,  # noqa: ARG001
    ) -> Any:
        """Generate code for a simple MedeaWiz action."""
        var = cg.new_Pvariable(action_id, template_arg)
        await cg.register_parented(var, config[CONF_ID])
        return var


for _name, _class in SIMPLE_ACTIONS.items():
    _register_simple_action(_name, _class)


@automation.register_action(  # type: ignore[untyped-decorator]
    "medeawiz.play_file",
    PlayFileAction,
    cv.maybe_simple_value(
        {
            cv.GenerateID(): cv.use_id(MedeaWiz),
            cv.Required(CONF_FILE): cv.templatable(cv.int_range(min=0, max=200)),
        },
        key=CONF_FILE,
    ),
    synchronous=True,
)
async def medeawiz_play_file_to_code(
    config: dict[str, Any],
    action_id: Any,
    template_arg: Any,
    args: Any,
) -> Any:
    """Generate code for the play_file action."""
    var = cg.new_Pvariable(action_id, template_arg)
    await cg.register_parented(var, config[CONF_ID])
    template_ = await cg.templatable(config[CONF_FILE], args, cg.uint16)
    cg.add(var.set_file(template_))
    return var


@automation.register_action(  # type: ignore[untyped-decorator]
    "medeawiz.set_loop_file",
    SetLoopFileAction,
    cv.maybe_simple_value(
        {
            cv.GenerateID(): cv.use_id(MedeaWiz),
            cv.Required(CONF_FILE): cv.templatable(cv.int_range(min=0, max=200)),
        },
        key=CONF_FILE,
    ),
    synchronous=True,
)
async def medeawiz_set_loop_file_to_code(
    config: dict[str, Any],
    action_id: Any,
    template_arg: Any,
    args: Any,
) -> Any:
    """Generate code for the set_loop_file action."""
    var = cg.new_Pvariable(action_id, template_arg)
    await cg.register_parented(var, config[CONF_ID])
    template_ = await cg.templatable(config[CONF_FILE], args, cg.uint16)
    cg.add(var.set_file(template_))
    return var


@automation.register_action(  # type: ignore[untyped-decorator]
    "medeawiz.seek",
    SeekAction,
    cv.maybe_simple_value(
        {
            cv.GenerateID(): cv.use_id(MedeaWiz),
            cv.Required(CONF_POSITION): cv.templatable(cv.positive_int),
        },
        key=CONF_POSITION,
    ),
    synchronous=True,
)
async def medeawiz_seek_to_code(
    config: dict[str, Any],
    action_id: Any,
    template_arg: Any,
    args: Any,
) -> Any:
    """Generate code for the seek action."""
    var = cg.new_Pvariable(action_id, template_arg)
    await cg.register_parented(var, config[CONF_ID])
    template_ = await cg.templatable(config[CONF_POSITION], args, cg.uint32)
    cg.add(var.set_position(template_))
    return var


@automation.register_action(  # type: ignore[untyped-decorator]
    "medeawiz.send_command",
    SendCommandAction,
    cv.maybe_simple_value(
        {
            cv.GenerateID(): cv.use_id(MedeaWiz),
            cv.Required(CONF_COMMAND): cv.templatable(cv.uint8_t),
        },
        key=CONF_COMMAND,
    ),
    synchronous=True,
)
async def medeawiz_send_command_to_code(
    config: dict[str, Any],
    action_id: Any,
    template_arg: Any,
    args: Any,
) -> Any:
    """Generate code for the send_command action."""
    var = cg.new_Pvariable(action_id, template_arg)
    await cg.register_parented(var, config[CONF_ID])
    template_ = await cg.templatable(config[CONF_COMMAND], args, cg.uint8)
    cg.add(var.set_command(template_))
    return var
