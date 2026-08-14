#include "ack_button.h"

#ifdef USE_MQTT
#include <string>
#include <vector>

#include "esphome/core/log.h"
#endif

namespace esphome {
namespace ack_button {

#ifdef USE_MQTT

static const char *const TAG = "ack_button";

// The one payload a Home Assistant button carries, in both directions: it is the
// default `payload_press` HA assumes when discovery omits one, and the value the
// criotive platform matches an acknowledgement against. Shared by the
// subscription and the ack so the two can never drift apart.
static const char *const PRESS_PAYLOAD = "PRESS";

namespace {

std::vector<std::string> split_topic_levels(const std::string &topic) {
  std::vector<std::string> levels;
  size_t start = 0;
  while (true) {
    const size_t separator = topic.find('/', start);
    if (separator == std::string::npos) {
      levels.push_back(topic.substr(start));
      return levels;
    }
    levels.push_back(topic.substr(start, separator - start));
    start = separator + 1;
  }
}

/// Would a broker deliver `topic` to a subscription on `filter`?
///
/// MQTT 3.1.1 §4.7: `+` matches exactly one level, `#` matches the level it sits
/// at and everything below it, and neither wildcard may match a topic whose first
/// level starts with `$`. ESPHome has this logic already, but as a file-static
/// helper in mqtt_client.cpp with no header, so it cannot be reused.
///
/// `_topic_filter_matches()` in this component's `button/__init__.py` is the same
/// function in Python. Change one and change the other: that one reports the
/// mistake at `esphome config` time, this one is the backstop for topics that are
/// not literals in the YAML.
bool topic_matches_filter(const std::string &topic, const std::string &filter) {
  const std::vector<std::string> topic_levels = split_topic_levels(topic);
  const std::vector<std::string> filter_levels = split_topic_levels(filter);
  const bool is_dollar = !topic_levels[0].empty() && topic_levels[0][0] == '$';

  for (size_t i = 0; i < filter_levels.size(); i++) {
    if (filter_levels[i] == "#")
      return !(i == 0 && is_dollar);
    if (i >= topic_levels.size())
      return false;
    if (filter_levels[i] == "+") {
      if (i == 0 && is_dollar)
        return false;
    } else if (filter_levels[i] != topic_levels[i]) {
      return false;
    }
  }

  return filter_levels.size() == topic_levels.size();
}

}  // namespace

MQTTAckButtonComponent::MQTTAckButtonComponent(AckButton *button) : button_(button) {
  // Both directions of the link are established here, before App.setup() runs:
  // codegen constructs the button first and hands it to this constructor.
  button->set_mqtt_ack(this);

  // MQTTComponent retains by default, which is right for a state and wrong for an
  // event: a retained PRESS is redelivered to every future subscriber, so the
  // platform would ingest a fresh "pressed" each time it reconnects. An explicit
  // `retain: true` in the YAML still wins — register_mqtt_component() applies it
  // after construction.
  this->set_retain(false);
}

void MQTTAckButtonComponent::setup() {
  const std::string command_topic = this->get_command_topic_();

  // Refuse to arm a button whose acknowledgement the broker would route back into
  // its own subscription: each ack returns as a press, which acks, forever — with
  // the on_press: automation running every lap against real hardware.
  //
  // The Python guard rejects this at `esphome config` time, but it only sees
  // topics written literally in the YAML. Here both are fully resolved — defaults
  // filled in, lambdas evaluated — so a config that overrode only one of the two,
  // or computed either, is caught. Discovery is disabled from inside setup(),
  // which call_setup() has not reached yet, so the entity is never advertised.
  const std::string state_topic = this->get_state_topic_();
  if (!command_topic.empty() && topic_matches_filter(state_topic, command_topic)) {
    ESP_LOGE(TAG, "'%s': state topic '%s' matches command topic '%s' — every acknowledgement would "
                  "come back as a new press. Button disabled.",
             this->friendly_name_().c_str(), state_topic.c_str(), command_topic.c_str());
    this->disable_discovery();
    this->mark_failed();
    return;
  }

  this->subscribed_command_topic_ = command_topic;
  this->subscribe(command_topic, [this](const std::string &topic, const std::string &payload) {
    if (payload == PRESS_PAYLOAD) {
      this->button_->press();
    } else {
      ESP_LOGW(TAG, "'%s': Received unknown button payload: %s", this->friendly_name_().c_str(), payload.c_str());
      this->status_momentary_warning("state", 5000);
    }
  });
}

void MQTTAckButtonComponent::publish_ack() {
  // call_setup() computes is_internal() and returns before setup() for an internal
  // entity, so this is the guard that keeps an internal button off the broker: it
  // has a state topic like any other, it just must not publish to it. A press can
  // only happen after setup, so the cached value is always resolved by now.
  //
  // is_failed() covers the self-subscribing topics setup() refused to arm. Nothing
  // will publish a command to it, but `button.press:` and physical inputs reach the
  // button directly, and the loop is just as real when it starts from one of those.
  if (this->is_internal() || this->is_failed())
    return;

  // Re-checked here, not just in setup(): a lambda state topic is evaluated afresh
  // on every publish, so one that was safe at boot can resolve into the filter this
  // button is subscribed to later on. Dropping the ack keeps a misbehaving lambda
  // from starting a loop that no config-time check could have seen.
  const std::string state_topic = this->get_state_topic_();
  if (topic_matches_filter(state_topic, this->subscribed_command_topic_)) {
    ESP_LOGE(TAG, "'%s': state topic '%s' now resolves into the subscribed command topic '%s'; "
                  "dropping the acknowledgement rather than looping.",
             this->friendly_name_().c_str(), state_topic.c_str(), this->subscribed_command_topic_.c_str());
    return;
  }

  this->publish(state_topic, PRESS_PAYLOAD);
}

void MQTTAckButtonComponent::send_discovery(JsonObject root, mqtt::SendDiscoveryConfig &config) {
  // Both are the framework defaults; stated rather than inherited because the
  // state topic is the entire reason this component exists, and a silent upstream
  // change to that default would otherwise drop it with no compile error.
  config.state_topic = true;
  config.command_topic = true;
}

void MQTTAckButtonComponent::dump_config() {
  ESP_LOGCONFIG(TAG, "MQTT Ack Button '%s': ", this->button_->get_name().c_str());
  LOG_MQTT_COMPONENT(true, true);
}

#endif  // USE_MQTT

void AckButton::press_action() {
#ifdef USE_MQTT
  if (this->mqtt_ack_ != nullptr)
    this->mqtt_ack_->publish_ack();
#endif
}

}  // namespace ack_button
}  // namespace esphome
