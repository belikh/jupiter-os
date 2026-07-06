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
}
