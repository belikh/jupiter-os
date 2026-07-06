//! Entity -> UI mutation plan for the bedroom quarters overview
//! (task.md T3.3 / T3.4, slint_layout_spec.md §4).
//!
//! `dispatch_plan` is the pure, renderer-free core of `dispatch_state`. Given
//! an entity_id and its typed `EntityState`, it yields the abstract UI update
//! the main thread should apply. main.rs is the thin adapter that turns a
//! `UiUpdate` into the matching `ui.set_<prop>(...)` inside
//! `slint::invoke_from_event_loop`. Splitting routing from the Slint handle
//! is what lets the mapping run under `cargo test` without a GPU scanout;
//! the live round-trip (tap -> ServiceCall -> state_changed -> set_prop) is
//! the Phase 3.4 verify, run against a headless render harness.
//!
//! Entity IDs are the real ones from `/home/io/Documents/fallout/dashboards/
//! jupiter-room.yaml` — the port invents nothing (implementation_plan §6.2).

use crate::state::EntityState;

// ---- bedroom overview entity IDs (jupiter-room.yaml) ----------------------

/// Header AIR cell. YAML maps state "off" -> BREATHABLE, "on" -> CONTAMINATED.
pub const AIR_CONTAMINATION: &str =
    "binary_sensor.jupiter_bedroom_bedroom_jupiter_air_contamination";
/// Header OCCUPANCY cell + overview OCCUPANCY cell. "on" -> OCCUPIED,
/// "off" -> VACANT.
pub const AREA_STATE: &str =
    "binary_sensor.magic_areas_presence_tracking_jupiter_bedroom_area_state";
/// ROOM LIGHTS overview cell.
pub const ROOM_LIGHTS: &str = "light.jupiter_quarters_lights";
/// TEMPERATURE overview cell (climate domain; typed as Raw in EntityState).
pub const CLIMATE: &str = "climate.smart_thermostat_jupiter";
/// 3D PRINTER overview cell. YAML: "ready" -> STANDBY.
pub const PRINTER: &str = "sensor.living_room_kobra_printer_state";

// ---- lights detail page entity IDs (jupiter-room.yaml `lights` view) -------

/// CEILING fixture. YAML `lights` view: light.jupiter_room (brightness + color_temp).
pub const CEILING_LIGHT: &str = "light.jupiter_room";
/// FAN LIGHT fixture. YAML: light.fanlight (brightness + color_temp).
pub const FAN_LIGHT: &str = "light.fanlight";
/// BED LED strip. YAML: light.bed (brightness + color).
pub const BED_LIGHT: &str = "light.bed";

// ---- enviro page entity IDs (jupiter-room.yaml `environment` view) ---------

/// CO2 gauge. ALPSTUGA monitor, 400..2000 ppm.
pub const CO2: &str = "sensor.alpstuga_air_quality_monitor_carbon_dioxide";
/// PM2.5 gauge. ALPSTUGA monitor, 0..150 µg/m³.
pub const PM25: &str = "sensor.alpstuga_air_quality_monitor_pm2_5";
/// Air temperature gauge. ALPSTUGA monitor, 10..35 °C.
pub const ENVIRO_TEMP: &str = "sensor.alpstuga_air_quality_monitor_temperature";
/// Relative humidity gauge. ALPSTUGA monitor, 0..100 %.
pub const HUMIDITY: &str = "sensor.alpstuga_air_quality_monitor_humidity";

// ---- typed UI values ------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Air {
    Breathable,
    Contaminated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Occ {
    Occupied,
    Vacant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Printer {
    Standby,
    Printing,
    Ready,
    Unknown,
}

impl Printer {
    pub fn label(self) -> &'static str {
        match self {
            Printer::Standby => "STANDBY",
            Printer::Printing => "PRINTING",
            Printer::Ready => "READY",
            Printer::Unknown => "---",
        }
    }
}

/// Which fixture a lights-page update targets. One variant per row so main.rs
/// can `set_<fixture>_on` / `set_<fixture>_brightness` without a string match.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WhichLight {
    Ceiling,
    Fan,
    Bed,
}

/// Abstract UI mutation. Each variant maps 1:1 to a `ui.set_<prop>(...)` call
/// in main.rs. `None` from `dispatch_plan` means "entity not rendered here"
/// — the state cache still records it for a detail page that may need it.
#[derive(Debug, Clone, PartialEq)]
pub enum UiUpdate {
    AirQuality(Air),
    Occupancy(Occ),
    RoomLightsOn(bool),
    Temperature(String),
    PrinterState(Printer),
    // Lights detail page — per fixture on/off + brightness.
    CeilingLight {
        on: bool,
        brightness_pct: Option<u8>,
    },
    FanLight {
        on: bool,
        brightness_pct: Option<u8>,
    },
    BedLight {
        on: bool,
        brightness_pct: Option<u8>,
    },
    // Enviro page — one float per gauge.
    EnviroSensor {
        which: EnviroSensor,
        value: f32,
    },
}

/// Which enviro gauge a sensor update targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnviroSensor {
    Co2,
    Pm25,
    Temp,
    Humidity,
}

/// Parse a sensor's string state into f32. Returns None on a non-numeric
/// payload (keeps the last known value rather than forcing a 0.0 onto the gauge).
fn sensor_to_f32(state: &EntityState) -> Option<f32> {
    match state {
        EntityState::Sensor { value, .. } => value.parse::<f32>().ok(),
        _ => None,
    }
}

/// Package a light fixture update for the given fixture.
fn light_update(
    which: WhichLight,
    on: bool,
    brightness_pct: Option<u8>,
) -> UiUpdate {
    match which {
        WhichLight::Ceiling => UiUpdate::CeilingLight {
            on,
            brightness_pct,
        },
        WhichLight::Fan => UiUpdate::FanLight {
            on,
            brightness_pct,
        },
        WhichLight::Bed => UiUpdate::BedLight {
            on,
            brightness_pct,
        },
    }
}

/// Lift an EntityState::Light into a fixture UI update. Non-light payload
/// (e.g. a malformed Raw push) -> None (keep the last known value).
fn light_from_state(which: WhichLight, state: &EntityState) -> Option<UiUpdate> {
    match state {
        EntityState::Light {
            on,
            brightness_pct,
        } => Some(light_update(which, *on, *brightness_pct)),
        _ => None,
    }
}

/// Parse the Kobra printer's `sensor.*_state` string. The YAML only defines
/// "ready" -> STANDBY; we treat "printing" as Printing and everything else as
/// Standby (the safe default — a printer we don't understand is assumed idle).
fn parse_printer(value: &str) -> Printer {
    match value {
        "printing" => Printer::Printing,
        "ready" | "idle" | "standby" | "operational" => Printer::Standby,
        _ if value.is_empty() => Printer::Unknown,
        _ => Printer::Standby,
    }
}

/// Route one entity's typed state to the UI mutation it drives, or `None` if
/// this entity isn't part of the bedroom overview. Unknown entities must NOT
/// error — the worker subscribes to all `state_changed` events.
pub fn dispatch_plan(entity_id: &str, state: &EntityState) -> Option<UiUpdate> {
    match entity_id {
        AIR_CONTAMINATION => match state {
            EntityState::BinarySensor { on } => Some(UiUpdate::AirQuality(if *on {
                Air::Contaminated
            } else {
                Air::Breathable
            })),
            // A non-binary payload for a binary_sensor is a bad push; ignore.
            _ => None,
        },
        AREA_STATE => match state {
            EntityState::BinarySensor { on } => Some(UiUpdate::Occupancy(if *on {
                Occ::Occupied
            } else {
                Occ::Vacant
            })),
            _ => None,
        },
        ROOM_LIGHTS => match state {
            // Brightness is irrelevant on the overview cell — only on/off.
            EntityState::Light { on, .. } => Some(UiUpdate::RoomLightsOn(*on)),
            _ => None,
        },
        // Lights detail page — per-fixture on/off + brightness.
        CEILING_LIGHT => light_from_state(WhichLight::Ceiling, state),
        FAN_LIGHT => light_from_state(WhichLight::Fan, state),
        BED_LIGHT => light_from_state(WhichLight::Bed, state),
        // Enviro page — parse the sensor's numeric state into a gauge float.
        CO2 => sensor_to_f32(state).map(|v| UiUpdate::EnviroSensor {
            which: EnviroSensor::Co2,
            value: v,
        }),
        PM25 => sensor_to_f32(state).map(|v| UiUpdate::EnviroSensor {
            which: EnviroSensor::Pm25,
            value: v,
        }),
        ENVIRO_TEMP => sensor_to_f32(state).map(|v| UiUpdate::EnviroSensor {
            which: EnviroSensor::Temp,
            value: v,
        }),
        HUMIDITY => sensor_to_f32(state).map(|v| UiUpdate::EnviroSensor {
            which: EnviroSensor::Humidity,
            value: v,
        }),
        PRINTER => match state {
            EntityState::Sensor { value, .. } => Some(UiUpdate::PrinterState(parse_printer(value))),
            _ => None,
        },
        CLIMATE => {
            // climate.* is not a typed EntityState variant; from_ha stored the
            // full object as Raw. Read its top-level "state" (current temp) and
            // surface it as a string. Absent state -> no update.
            if let EntityState::Raw(v) = state {
                v.get("state")
                    .and_then(|s| s.as_str())
                    .map(|s| UiUpdate::Temperature(s.to_string()))
            } else {
                None
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn air_off_is_breathable_on_is_contaminated() {
        // task.md T3.3 verify: AIR shows BREATHABLE / CONTAMINATED per the YAML map.
        let off = EntityState::from_ha(AIR_CONTAMINATION, &json!({ "state": "off" }));
        let on = EntityState::from_ha(AIR_CONTAMINATION, &json!({ "state": "on" }));
        assert_eq!(
            dispatch_plan(AIR_CONTAMINATION, &off),
            Some(UiUpdate::AirQuality(Air::Breathable))
        );
        assert_eq!(
            dispatch_plan(AIR_CONTAMINATION, &on),
            Some(UiUpdate::AirQuality(Air::Contaminated))
        );
    }

    #[test]
    fn occupancy_on_is_occupied_off_is_vacant() {
        let on = EntityState::from_ha(AREA_STATE, &json!({ "state": "on" }));
        let off = EntityState::from_ha(AREA_STATE, &json!({ "state": "off" }));
        assert_eq!(
            dispatch_plan(AREA_STATE, &on),
            Some(UiUpdate::Occupancy(Occ::Occupied))
        );
        assert_eq!(
            dispatch_plan(AREA_STATE, &off),
            Some(UiUpdate::Occupancy(Occ::Vacant))
        );
    }

    #[test]
    fn room_lights_maps_on_off() {
        let lit = EntityState::from_ha(
            ROOM_LIGHTS,
            &json!({ "state": "on", "attributes": { "brightness_pct": 100 } }),
        );
        let dark = EntityState::from_ha(ROOM_LIGHTS, &json!({ "state": "off" }));
        assert_eq!(
            dispatch_plan(ROOM_LIGHTS, &lit),
            Some(UiUpdate::RoomLightsOn(true))
        );
        assert_eq!(
            dispatch_plan(ROOM_LIGHTS, &dark),
            Some(UiUpdate::RoomLightsOn(false))
        );
    }

    #[test]
    fn printer_ready_is_standby_printing_is_printing() {
        let ready = EntityState::from_ha(PRINTER, &json!({ "state": "ready" }));
        let printing = EntityState::from_ha(PRINTER, &json!({ "state": "printing" }));
        assert_eq!(
            dispatch_plan(PRINTER, &ready),
            Some(UiUpdate::PrinterState(Printer::Standby))
        );
        assert_eq!(
            dispatch_plan(PRINTER, &printing),
            Some(UiUpdate::PrinterState(Printer::Printing))
        );
    }

    #[test]
    fn climate_temperature_surfaces_state_string() {
        let climate = EntityState::from_ha(
            CLIMATE,
            &json!({ "state": "23.3", "attributes": { "current_temperature": 23.3 } }),
        );
        assert_eq!(
            dispatch_plan(CLIMATE, &climate),
            Some(UiUpdate::Temperature("23.3".into()))
        );
    }

    #[test]
    fn unknown_entity_is_none_not_an_error() {
        // load-bearing: worker subscribes to ALL state_changed; unknowns must not error.
        let s = EntityState::from_ha("sensor.some_other_thing", &json!({ "state": "42" }));
        assert_eq!(dispatch_plan("sensor.some_other_thing", &s), None);
    }

    #[test]
    fn wrong_typed_payload_for_known_entity_is_none() {
        // e.g. a binary_sensor push that parsed as Raw (bad payload) -> ignore, keep last value.
        let raw = EntityState::Raw(json!({ "state": "indeterminate" }));
        assert_eq!(dispatch_plan(AIR_CONTAMINATION, &raw), None);
    }

    #[test]
    fn printer_label_strings() {
        assert_eq!(Printer::Standby.label(), "STANDBY");
        assert_eq!(Printer::Printing.label(), "PRINTING");
        assert_eq!(Printer::Unknown.label(), "---");
    }

    // ---- lights detail page (jupiter-room.yaml `lights` view) ---------------

    #[test]
    fn ceiling_light_maps_on_and_brightness() {
        let lit = EntityState::from_ha(
            CEILING_LIGHT,
            &json!({ "state": "on", "attributes": { "brightness_pct": 70 } }),
        );
        let dark = EntityState::from_ha(CEILING_LIGHT, &json!({ "state": "off" }));
        assert_eq!(
            dispatch_plan(CEILING_LIGHT, &lit),
            Some(UiUpdate::CeilingLight {
                on: true,
                brightness_pct: Some(70)
            })
        );
        assert_eq!(
            dispatch_plan(CEILING_LIGHT, &dark),
            Some(UiUpdate::CeilingLight {
                on: false,
                brightness_pct: None,
            })
        );
    }

    #[test]
    fn fan_and_bed_light_route_to_their_own_variants() {
        // load-bearing: each fixture must land in its OWN UiUpdate variant so
        // main.rs hits the right set_<fixture>_* property — never cross-talk.
        let fan = EntityState::from_ha(
            FAN_LIGHT,
            &json!({ "state": "on", "attributes": { "brightness_pct": 40 } }),
        );
        let bed = EntityState::from_ha(
            BED_LIGHT,
            &json!({ "state": "on", "attributes": { "brightness_pct": 100 } }),
        );
        assert_eq!(
            dispatch_plan(FAN_LIGHT, &fan),
            Some(UiUpdate::FanLight {
                on: true,
                brightness_pct: Some(40)
            })
        );
        assert_eq!(
            dispatch_plan(BED_LIGHT, &bed),
            Some(UiUpdate::BedLight {
                on: true,
                brightness_pct: Some(100)
            })
        );
    }

    #[test]
    fn fixtures_never_cross_route_into_room_lights_or_each_other() {
        // The overview's ROOM_LIGHTS (light.jupiter_quarters_lights) is a
        // DIFFERENT entity from the three fixtures — confirm it still routes
        // to RoomLightsOn, not to a fixture variant.
        let group = EntityState::from_ha(ROOM_LIGHTS, &json!({ "state": "on" }));
        assert_eq!(
            dispatch_plan(ROOM_LIGHTS, &group),
            Some(UiUpdate::RoomLightsOn(true))
        );
    }

    // ---- enviro page (jupiter-room.yaml `environment` view) -----------------

    #[test]
    fn enviro_sensors_parse_to_their_own_gauge() {
        let co2 = EntityState::from_ha(CO2, &json!({ "state": "823.4", "attributes": { "unit_of_measurement": "ppm" } }));
        let pm = EntityState::from_ha(PM25, &json!({ "state": "12" }));
        let temp = EntityState::from_ha(ENVIRO_TEMP, &json!({ "state": "21.5" }));
        let hum = EntityState::from_ha(HUMIDITY, &json!({ "state": "48" }));

        assert_eq!(
            dispatch_plan(CO2, &co2),
            Some(UiUpdate::EnviroSensor {
                which: EnviroSensor::Co2,
                value: 823.4
            })
        );
        assert_eq!(
            dispatch_plan(PM25, &pm),
            Some(UiUpdate::EnviroSensor {
                which: EnviroSensor::Pm25,
                value: 12.0
            })
        );
        assert_eq!(
            dispatch_plan(ENVIRO_TEMP, &temp),
            Some(UiUpdate::EnviroSensor {
                which: EnviroSensor::Temp,
                value: 21.5
            })
        );
        assert_eq!(
            dispatch_plan(HUMIDITY, &hum),
            Some(UiUpdate::EnviroSensor {
                which: EnviroSensor::Humidity,
                value: 48.0
            })
        );
    }

    #[test]
    fn enviro_non_numeric_sensor_is_none_keeps_last_value() {
        // A garbage push must NOT force 0.0 onto a gauge — return None so the
        // UI keeps the last good reading (matches the lights Raw-payload rule).
        let bad = EntityState::from_ha(CO2, &json!({ "state": "unavailable" }));
        assert_eq!(dispatch_plan(CO2, &bad), None);
    }
}
