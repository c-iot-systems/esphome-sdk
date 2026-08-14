"""The `ack_button` button platform.

Everything a stock button accepts, this accepts: the schema, the entity
registration and the `button.press:` action all come from
`esphome.components.button` unmodified, so an ESPHome release that adds an
option to buttons adds it here on the same day.

The single override is the MQTT companion class. `button.setup_button_core_`
instantiates whatever type `CONF_MQTT_ID` was declared with, so swapping that
one key is enough to replace `mqtt::MQTTButtonComponent` with the ack-emitting
variant while leaving the rest of the button contract untouched.
"""

from typing import Any

import esphome.config_validation as cv
from esphome.components import button, mqtt
from esphome.const import CONF_COMMAND_TOPIC, CONF_MQTT_ID, CONF_STATE_TOPIC

from .. import ack_button_ns

AckButton = ack_button_ns.class_("AckButton", button.Button)
MQTTAckButtonComponent = ack_button_ns.class_(
    "MQTTAckButtonComponent",
    mqtt.MQTTComponent,
)


def _topic_filter_matches(topic: str, topic_filter: str) -> bool:
    """Does `topic` match the MQTT subscription filter `topic_filter`?

    MQTT 3.1.1 §4.7, the same rules the broker applies when deciding what to
    deliver back to us. `+` matches exactly one level, `#` matches the level it
    sits at and everything below, and neither wildcard may match a topic whose
    first level starts with `$`.
    """
    topic_levels = topic.split("/")
    filter_levels = topic_filter.split("/")
    is_dollar = topic_levels[0].startswith("$")

    for i, level in enumerate(filter_levels):
        if level == "#":
            return not (i == 0 and is_dollar)
        if i >= len(topic_levels):
            return False
        if level == "+":
            if i == 0 and is_dollar:
                return False
        elif level != topic_levels[i]:
            return False

    return len(filter_levels) == len(topic_levels)


def _reject_self_subscribing_topics(config: dict[str, Any]) -> dict[str, Any]:
    """Refuse a config whose acknowledgement lands back on its own subscription.

    Unique to this platform. A stock button publishes nothing, so pointing both
    keys at one topic is merely useless; here it is a live loop. The device
    subscribes to the command topic and acks on the state topic, and MQTT 3.1.1
    has no no-local option — so the broker hands each ack straight back as a
    fresh command, which presses the button, which acks. That runs the
    `on_press:` automation forever and floods the broker on real hardware.

    The command topic is a *filter* and may carry wildcards (`cv.subscribe_topic`
    allows them), so plain equality is not enough: `.../+` swallows the ack just
    as `.../state` would. The state topic is always literal — `cv.publish_topic`
    rejects wildcards — so matching runs in one direction only.

    Both defaults (`<prefix>/button/<id>/state` and `.../command`) are literal
    and differ, so an unconfigured button can never trip this. Two empty strings
    are left alone: that is the documented way to mark an MQTT entity internal,
    and an entity that publishes nothing cannot loop.

    Only literal topics can be compared. Either key may be a lambda, whose value
    is not known until runtime, and this cannot see through one — a device that
    computes both topics on device is trusted to keep them apart.
    """
    state = config.get(CONF_STATE_TOPIC)
    command = config.get(CONF_COMMAND_TOPIC)

    if not isinstance(state, str) or not isinstance(command, str) or state == "":
        return config

    if _topic_filter_matches(state, command):
        raise cv.Invalid(
            f"state_topic '{state}' matches command_topic '{command}', so this "
            "button would be subscribed to its own acknowledgement: the broker "
            "echoes every ack back as a new press and it loops forever. Give "
            "the two topics values that cannot match.",
            path=[CONF_STATE_TOPIC],
        )

    return config


CONFIG_SCHEMA = cv.All(
    button.button_schema(AckButton).extend(
        {
            # Same key, same `OnlyWith(..., "mqtt")` gate as the stock button schema —
            # only the declared C++ type differs. Without `mqtt:` in the config the key
            # never materializes and this degrades to an ordinary template-like button.
            cv.OnlyWith(CONF_MQTT_ID, "mqtt"): cv.declare_id(MQTTAckButtonComponent),
        },
    ),
    _reject_self_subscribing_topics,
)


async def to_code(config: dict[str, Any]) -> None:
    """Register the button through ESPHome's own button pipeline."""
    await button.new_button(config)
