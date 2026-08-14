"""Google Location text sensor component."""

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import text_sensor
from esphome.const import (
    ENTITY_CATEGORY_DIAGNOSTIC,
)

DEPENDENCIES = ["wifi"]
# google_location.h unconditionally includes json/json_util.h to build the geolocation request
# body, so json's C++ must be in the build whenever this component is used. `esphome config` never
# compiles C++ and so cannot see this — only a real `esphome compile` does, which is how it was
# found. Same class of bug as the binary_sensor AUTO_LOAD in components/phone/__init__.py.
AUTO_LOAD = ["json"]
CONF_GOOGLE_LOCATION = "google_location"

google_location_ns = cg.esphome_ns.namespace(CONF_GOOGLE_LOCATION)
GoogleLocation = google_location_ns.class_(
    "GoogleLocation",
    text_sensor.TextSensor,
    cg.PollingComponent,
)

CONFIG_SCHEMA = text_sensor.text_sensor_schema(
    GoogleLocation,
    entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
).extend(
    cv.polling_component_schema("4294967295ms"),
)  # Infinite update interval


async def to_code(config: dict[str, str]) -> None:
    """Generate code for the Google Location text sensor."""
    var = await text_sensor.new_text_sensor(config)
    await cg.register_component(var, config)
