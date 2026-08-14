"""ESPHome button that acknowledges its own press on the MQTT state topic.

A stock ESPHome button is deliberately stateless: `mqtt_button.cpp` sets
`SendDiscoveryConfig::state_topic = false` and never publishes, because Home
Assistant models a button as a write-only trigger.

The criotive platform confirms a command by reading telemetry back from the
component's state topic, so a button that publishes nothing can only ever time
out. `ack_button` is the stock button with that one difference: it keeps the
state topic in discovery and echoes `PRESS` there on every press.

Everything lives under `button/`, the way upstream keeps `template/button/`:
ESPHome collects a platform's C++ sources from the platform package, so a header
at this level would never be copied into the build. This module owns only the C++
namespace the platform shares with its MQTT companion.
"""

import esphome.codegen as cg

CODEOWNERS = ["Arthur Komatsu"]

ack_button_ns = cg.esphome_ns.namespace("ack_button")
