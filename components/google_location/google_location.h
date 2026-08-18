#pragma once

#include <string>

#include "esphome.h"
#include "esphome/components/json/json_util.h"
#include "esphome/components/text_sensor/text_sensor.h"
#include "esphome/components/wifi/wifi_component.h"
#include "esphome/core/component.h"
#include "esphome/core/helpers.h"
#include "esphome/core/log.h"

#ifdef USE_MQTT
#include "esphome/components/mqtt/mqtt_client.h"
#endif

namespace esphome {
namespace google_location {

static const char *const TAG = "google_location";

class GoogleLocation : public PollingComponent, public text_sensor::TextSensor {
 public:
  /// Configure the legacy JSON system-command topic.
  ///
  /// Deprecated: remote callers should press the discovered Location Request
  /// ack_button instead. Kept through the 0.3 line as a compatibility bridge.
  void set_system_command_topic(const std::string &topic) { this->system_command_topic_ = topic; }

  float get_setup_priority() const override {
    return setup_priority::AFTER_WIFI;
  };

  void setup() override {
#ifdef USE_MQTT
    // Compatibility only. New callers use the Location Request ack_button,
    // which acknowledges PRESS before its automation calls update(). Remove
    // this subscription in the next breaking SDK release.
    mqtt::global_mqtt_client->subscribe_json(
        this->system_command_topic_,
        [this](const std::string &topic, JsonObject root) {
          const char *command = root["command"];
          if (command != nullptr && std::string(command) == "fetch_location") {
            ESP_LOGW(TAG,
                     "Deprecated JSON fetch_location command received on '%s'; publish PRESS to the discovered "
                     "Location Request ack_button command topic instead.",
                     topic.c_str());
            this->update();
          }
        },
        1);
#endif
  }

  void update() override {
    const std::string payload = json::build_json([=](JsonObject root) {
      JsonObject location = root["location_parameters"].to<JsonObject>();
      location["considerIp"] = false;
      JsonArray access_points = location["wifiAccessPoints"].to<JsonArray>();
      int i = 0;
      for (auto& scan : wifi::global_wifi_component->get_scan_result()) {
        if (i == 10) {  // That's enough....
          break;
        }
        if (scan.get_is_hidden()) continue;
        // Convert bssid to mac string
        auto bssid = scan.get_bssid();
        char macStr[18] = {0};
        sprintf(macStr, "%02X:%02X:%02X:%02X:%02X:%02X", bssid[0], bssid[1],
                bssid[2], bssid[3], bssid[4], bssid[5]);
        JsonObject access_point = access_points.add<JsonObject>();
        access_point["macAddress"] = macStr;
        access_point["signalStrength"] = scan.get_rssi();
        access_point["channel"] = scan.get_channel();
        i++;
      }
    });

    this->publish_state(payload);

#ifdef USE_MQTT
    std::string telemetry_topic = mqtt::global_mqtt_client->get_topic_prefix();
    if (!telemetry_topic.empty())
      telemetry_topic += "/";
    telemetry_topic += "telemetry";
    mqtt::global_mqtt_client->publish(telemetry_topic, payload, 1, false);
#endif
  }

 protected:
  std::string system_command_topic_{"command"};
};

}  // namespace google_location
}  // namespace esphome
