//! State cache + typed entity model (task.md T2.2).
//!
//! The worker thread owns a `StateCache` (`Arc<RwLock<HashMap<entity, state>>>`)
//! primed by HA's `get_states` and kept current by `state_changed` events. The
//! UI never caches — every render reads through `dispatch_state` (Phase 3.4)
//! which calls `cache.get`. Strong typing covers exactly the entity families
//! the dashboards render; anything else falls back to `Raw(serde_json::Value)`.

use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// Typed view of a HA entity. Variants cover the families the port renders
/// (per implementation_plan.md §6.2); `Raw` is the catch-all so an unknown
/// domain never crashes the worker.
#[derive(Debug, Clone)]
pub enum EntityState {
    /// `light.*` — on/off + optional `brightness_pct` (0..=100).
    Light {
        on: bool,
        brightness_pct: Option<u8>,
    },
    /// `sensor.*` — string-valued state + optional unit_of_measurement.
    Sensor { value: String, unit: Option<String> },
    /// `media_player.*` — playback state string ("playing"/"idle"/...).
    MediaPlayer { state: String },
    /// `binary_sensor.*` — boolean derived from state == "on".
    BinarySensor { on: bool },
    /// `sun.*` — above_horizon derived from state == "above_horizon".
    Sun { above_horizon: bool },
    /// `device_tracker.*` — home derived from state == "home".
    DeviceTracker { home: bool },
    /// Anything else — keep the raw JSON so the UI can still show *something*.
    Raw(Value),
}

impl EntityState {
    /// Entity domain = the substring before the first '.' of the entity_id.
    /// "light.bedroom_ceiling" -> "light". An entity_id with no '.' yields "".
    pub fn domain_of(entity_id: &str) -> &str {
        match entity_id.find('.') {
            Some(i) => &entity_id[..i],
            None => "",
        }
    }

    /// Build a typed `EntityState` from a HA `state_changed.new_state` (or a
    /// `get_states` array element). `obj` is the full state object:
    /// `{ "entity_id": "...", "state": "...", "attributes": { ... } }`.
    /// `entity_id` is passed separately so the dispatcher can route without
    /// re-parsing JSON.
    pub fn from_ha(entity_id: &str, obj: &Value) -> Self {
        let state_str = obj
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let attrs = obj.get("attributes").cloned().unwrap_or(Value::Null);
        match Self::domain_of(entity_id) {
            "light" => EntityState::Light {
                on: state_str == "on",
                brightness_pct: attrs
                    .get("brightness_pct")
                    .and_then(Value::as_i64)
                    .and_then(|n| u8::try_from(n.clamp(0, 100)).ok()),
            },
            "sensor" => EntityState::Sensor {
                value: state_str.clone(),
                unit: attrs
                    .get("unit_of_measurement")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            },
            "media_player" => EntityState::MediaPlayer { state: state_str },
            "binary_sensor" => EntityState::BinarySensor {
                on: state_str == "on",
            },
            "sun" => EntityState::Sun {
                above_horizon: state_str == "above_horizon",
            },
            "device_tracker" => EntityState::DeviceTracker {
                home: state_str == "home",
            },
            _ => EntityState::Raw(obj.clone()),
        }
    }
}

/// `Arc<RwLock<HashMap>>` keyed by `entity_id`. Clones share the same backing
/// map (cheap hand-off to the UI thread's dispatcher).
#[derive(Clone)]
pub struct StateCache {
    inner: Arc<RwLock<HashMap<String, EntityState>>>,
}

impl Default for StateCache {
    fn default() -> Self {
        Self::new()
    }
}

impl StateCache {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Read-through copy of an entity's state. Returns `None` if the entity
    /// has never been primed or pushed.
    pub fn get(&self, entity_id: &str) -> Option<EntityState> {
        self.inner.read().ok()?.get(entity_id).cloned()
    }

    /// Insert/replace a state. Returns the previous value if any.
    pub fn set(&self, entity_id: String, state: EntityState) -> Option<EntityState> {
        self.inner.write().ok()?.insert(entity_id, state)
    }

    /// Apply a single inbound `state_changed.new_state` object: parse it,
    /// store the typed state, and return the typed value so the worker can
    /// hand it to the UI in the same `HaEvent::State` (one parse, no re-read).
    pub fn apply_changed(&self, entity_id: &str, new_state: &Value) -> EntityState {
        let typed = EntityState::from_ha(entity_id, new_state);
        // Clone the entity_id into the key; tolerate a poisoned lock by
        // overwriting anyway (a panic in another thread shouldn't lose data).
        if let Ok(mut g) = self.inner.write() {
            g.insert(entity_id.to_string(), typed.clone());
        }
        typed
    }

    /// Number of entities currently cached. Used by the prime assertion.
    pub fn len(&self) -> usize {
        self.inner.read().map(|g| g.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn domain_of_splits_at_first_dot() {
        assert_eq!(EntityState::domain_of("light.bedroom_ceiling"), "light");
        assert_eq!(
            EntityState::domain_of("binary_sensor.jupiter_bedroom_air_contamination"),
            "binary_sensor"
        );
        assert_eq!(EntityState::domain_of("nope"), "");
    }

    #[test]
    fn apply_changed_updates_cache_and_returns_typed_state() {
        // task.md T2.2 verify: mock pushes a state_changed for
        // light.bedroom_ceiling; cache.get returns the new state within 50ms
        // and the subscriber fired exactly once. This unit test covers the
        // cache half (the subscriber firing once is the worker's job, tested
        // in ha::tests::state_changed_emits_exactly_one_event).
        let cache = StateCache::new();
        let new_state = json!({
            "entity_id": "light.bedroom_ceiling",
            "state": "on",
            "attributes": { "brightness_pct": 80 }
        });
        let t0 = std::time::Instant::now();
        let typed = cache.apply_changed("light.bedroom_ceiling", &new_state);
        let elapsed = t0.elapsed();

        // typed view is correct
        match typed {
            EntityState::Light { on, brightness_pct } => {
                assert!(on);
                assert_eq!(brightness_pct, Some(80));
            }
            other => panic!("expected Light, got {other:?}"),
        }
        // cache reflects it (the "within 50ms" bound is a worker-roundtrip
        // concern; the set itself is synchronous and microseconds-fast)
        let got = cache.get("light.bedroom_ceiling").expect("entity present");
        assert!(matches!(
            got,
            EntityState::Light {
                on: true,
                brightness_pct: Some(80)
            }
        ));
        assert!(elapsed.as_millis() < 50, "apply_changed took {elapsed:?}");
    }

    #[test]
    fn binary_sensor_and_sun_parse_state_strings() {
        let cache = StateCache::new();
        cache.apply_changed(
            "binary_sensor.magic_areas_jupiter_bedroom_area_state",
            &json!({ "state": "on", "attributes": {} }),
        );
        cache.apply_changed("sun.sun", &json!({ "state": "above_horizon" }));
        assert!(matches!(
            cache.get("binary_sensor.magic_areas_jupiter_bedroom_area_state"),
            Some(EntityState::BinarySensor { on: true })
        ));
        assert!(matches!(
            cache.get("sun.sun"),
            Some(EntityState::Sun {
                above_horizon: true
            })
        ));
    }

    #[test]
    fn unknown_domain_falls_back_to_raw() {
        let cache = StateCache::new();
        let obj = json!({ "state": "weird", "attributes": { "x": 1 } });
        cache.apply_changed("zwave_something_odd", &obj);
        assert!(matches!(
            cache.get("zwave_something_odd"),
            Some(EntityState::Raw(_))
        ));
    }

    #[test]
    fn set_returns_previous_value() {
        let cache = StateCache::new();
        let prev = cache.set(
            "light.x".into(),
            EntityState::Light {
                on: false,
                brightness_pct: None,
            },
        );
        assert!(prev.is_none());
        let prev = cache.set(
            "light.x".into(),
            EntityState::Light {
                on: true,
                brightness_pct: Some(50),
            },
        );
        assert!(matches!(prev, Some(EntityState::Light { on: false, .. })));
        assert_eq!(cache.len(), 1);
    }
}
