#pragma once

#include <string>

#include "esphome/components/button/button.h"
#include "esphome/core/defines.h"

#ifdef USE_MQTT
#include "esphome/components/mqtt/mqtt_component.h"
#endif

namespace esphome {
namespace ack_button {

#ifdef USE_MQTT
class MQTTAckButtonComponent;
#endif

/// A stock ESPHome button that acknowledges its own press.
///
/// `press_action()` is the hook a button platform must implement, and this
/// button's action really is "acknowledge": `Button::press()` runs it *before*
/// the `on_press:` callbacks, so the PRESS is handed to the MQTT client ahead of
/// whatever the automation does, rather than behind it. That ordering is the
/// point — an automation that blocks, or never returns, cannot leave a press
/// unacknowledged.
///
/// It is ordering, not a delivery guarantee. `publish()` queues; the client
/// still has to reach the socket. An automation that reboots or cuts power in
/// the same loop iteration can cut the packet off in flight, so the
/// `- delay: 500ms` idiom `modules/controls.yaml` puts in front of every
/// shutdown and restart is still the right thing for destructive actions.
///
/// Without `mqtt:` in the config there is no companion and this is an ordinary
/// button, indistinguishable from `platform: template`.
class AckButton : public button::Button {
 public:
#ifdef USE_MQTT
  void set_mqtt_ack(MQTTAckButtonComponent *mqtt_ack) { this->mqtt_ack_ = mqtt_ack; }
#endif

 protected:
  void press_action() override;

#ifdef USE_MQTT
  MQTTAckButtonComponent *mqtt_ack_{nullptr};
#endif
};

#ifdef USE_MQTT

/// The MQTT companion, mirroring `mqtt::MQTTButtonComponent` with one change.
///
/// It is a mirror rather than a subclass because upstream marked
/// `MQTTButtonComponent` `final` in 2026.7. `MQTTComponent` is the documented
/// extension point and the four overrides below are its whole contract, so this
/// keeps working across releases in a way a subclass would not.
///
/// The change is `send_discovery()`: upstream turns the state topic OFF, since
/// Home Assistant treats a button as write-only. Keeping it on is what makes the
/// press observable — the criotive platform binds a discovered component to its
/// `state_topic` and confirms a command by reading telemetry back from it.
class MQTTAckButtonComponent : public mqtt::MQTTComponent {
 public:
  explicit MQTTAckButtonComponent(AckButton *button);

  void setup() override;
  void dump_config() override;

  /// Publish PRESS on the state topic. Called from `AckButton::press_action()`,
  /// so every press acknowledges however it arrived — the command topic, a
  /// physical input's `button.press:`, or an automation — the way a switch
  /// publishes its state whatever moved it. Silent for an internal entity, and
  /// for one `setup()` refused to arm.
  void publish_ack();

  /// A press is an event, not a state, so there is nothing to replay on
  /// reconnect. Returning true without publishing keeps the resend machinery
  /// satisfied, same as upstream.
  bool send_initial_state() override { return true; }

  void send_discovery(JsonObject root, mqtt::SendDiscoveryConfig &config) override;

 protected:
  const char *component_type() const override { return "button"; }
  const EntityBase *get_entity() const override { return this->button_; }

  AckButton *button_;

  /// The command filter `setup()` actually subscribed to. Held because the state
  /// topic may be a lambda, re-evaluated on every publish: the pair has to be
  /// re-checked when the ack is sent, not only when the subscription was made.
  /// Empty until `setup()` runs, and left empty when it refuses to arm.
  std::string subscribed_command_topic_;
};

#endif  // USE_MQTT

}  // namespace ack_button
}  // namespace esphome
