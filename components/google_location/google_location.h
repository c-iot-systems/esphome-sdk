#pragma once

#include <string>

#include "esphome.h"
#include "esphome/components/json/json_util.h"
#include "esphome/components/text_sensor/text_sensor.h"
#include "esphome/components/wifi/wifi_component.h"
#include "esphome/core/component.h"
#include "esphome/core/helpers.h"

namespace esphome {
namespace google_location {

class GoogleLocation : public PollingComponent, public text_sensor::TextSensor {
 public:
  float get_setup_priority() const override {
    return setup_priority::AFTER_WIFI;
  };

  void update() override {
    this->publish_state(json::build_json([=](JsonObject root) {
      // wifi::global_wifi_component->start_scanning();
      root["considerIp"] = false;
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
        const char* kWiFiAccessPoints = "wifiAccessPoints";
        root[kWiFiAccessPoints][i]["macAddress"] = macStr;
        root[kWiFiAccessPoints][i]["signalStrength"] = scan.get_rssi();
        root[kWiFiAccessPoints][i]["channel"] = scan.get_channel();
        i++;
      }
    }));
  }
};

}  // namespace google_location
}  // namespace esphome
