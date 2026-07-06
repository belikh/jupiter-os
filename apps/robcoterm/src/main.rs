//! robcoterm binary — owns the Slint event loop on the main thread and drives
//! the HA worker on a single-thread tokio runtime (implementation_plan.md §1,
//! slint_layout_spec.md §4).
//!
//! Threading rule (load-bearing): all component handles live on this thread.
//! The worker never touches a handle directly — it sends `HaEvent`s that we
//! forward through `slint::invoke_from_event_loop`, which wakes this loop and
//! runs the closure here. UI -> worker service calls go through a tokio mpsc
//! `Sender` (Send-safe) captured in `on_<callback>` (wired in Phase 3.5).

use robcoterm::dispatch::{self, Air, Occ, UiUpdate};
use robcoterm::ha::{self, Connection, HaEvent};
use robcoterm::theme::{room_color, Room};
use std::time::Duration;

slint::include_modules!();

/// CLI args (the systemd unit passes --ha-url / --ha-token-file / --room).
struct Args {
    room: Option<String>,
    ha_url: Option<String>,
    ha_token_file: Option<String>,
}

fn parse_args() -> Args {
    let mut args = Args {
        room: None,
        ha_url: None,
        ha_token_file: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--room" => args.room = it.next(),
            "--ha-url" => args.ha_url = it.next(),
            "--ha-token-file" => args.ha_token_file = it.next(),
            _ => {}
        }
    }
    args
}

fn main() -> Result<(), slint::PlatformError> {
    // rustls 0.23 needs a process-level CryptoProvider before any TLS. We use
    // tokio-tungstenite's rustls backend for wss://; without this the first
    // connect_async panics ("Could not automatically determine the process-level
    // CryptoProvider"). Install ring once — idempotent across reconnects.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let args = parse_args();
    let room = args
        .room
        .as_deref()
        .and_then(Room::parse)
        .unwrap_or(Room::Bedroom);

    let ui = App::new()?;
    Theme::get(&ui).set_primary(room_color(room));

    // Best-effort HA wiring: the UI runs even if HA is unreachable — the
    // ReconnectBanner overlay (quarters.slint) shows LINK DOWN / RECONNECTING.
    let ha_cfg = match (&args.ha_url, &args.ha_token_file) {
        (Some(url), Some(tf)) => {
            // Read once, trim, never log. Errors here just mean "no token" ->
            // the worker will fail the handshake and reconnect-loop.
            let token = std::fs::read_to_string(tf)
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            Some(ha::HaConfig {
                url: url.clone(),
                token,
                backoff_start: Duration::from_secs(1),
                backoff_cap: Duration::from_secs(30),
            })
        }
        _ => None,
    };

    if let Some(cfg) = ha_cfg {
        // One-worker tokio runtime for the WS link. `enter()` is required so
        // the `tokio::spawn` inside ha::spawn registers on THIS runtime; both
        // the guard and the runtime must outlive ui.run() below.
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(1)
            .build()
            .expect("failed to build tokio runtime");
        let _enter = rt.enter();

        let link = ha::spawn(cfg);
        // The worker's calls_rx must never see all senders drop (that would
        // gracefully shut it down), so the original Sender is held for the
        // process lifetime. Clones captured by the UI callbacks below also
        // keep the channel open; together they cover the two ways UI input
        // becomes a ServiceCall: tap -> Toggle, slider -> Light{brightness}.
        let calls_tx = link.calls;

        // UI -> worker: lights page round-trip (task.md T3.5). The entity_id
        // arrives on the callback from Slint (the row owns it per the YAML) and
        // is forwarded verbatim — no UI-identity -> entity mapping in Rust.
        {
            let tx = calls_tx.clone();
            ui.on_light_toggled(move |entity: slint::SharedString| {
                let _ = tx.try_send(ha::ServiceCall::Toggle {
                    entity: entity.to_string(),
                });
            });
        }
        {
            let tx = calls_tx.clone();
            ui.on_brightness_changed(move |entity: slint::SharedString, brightness: i32| {
                let pct = brightness.clamp(0, 100) as u8;
                let _ = tx.try_send(ha::ServiceCall::Light {
                    entity: entity.to_string(),
                    brightness_pct: Some(pct),
                });
            });
        }
        // Keep the original Sender alive for the process lifetime (see above).
        std::mem::forget(calls_tx);

        // Drain worker events on the runtime and forward each to the Slint
        // main thread. invoke_from_event_loop is the only legal way to touch
        // the component from off-main.
        let ui_weak = ui.as_weak();
        let mut events_rx = link.events;
        rt.spawn(async move {
            while let Some(ev) = events_rx.recv().await {
                let w = ui_weak.clone();
                if slint::invoke_from_event_loop(move || {
                    if let Some(ui) = w.upgrade() {
                        apply_ha_event(&ui, ev);
                    }
                })
                .is_err()
                {
                    // Slint event loop has exited — we're shutting down.
                    break;
                }
            }
        });
        // `rt` is dropped when main returns (after ui.run()); the worker tasks
        // abort then. ui.run() below blocks the main thread in the meantime.
        std::mem::forget(rt);
    }

    ui.run()
}

/// Apply one worker event to the UI on the main thread. Connection transitions
/// map to the banner string; State events run through dispatch_plan and set the
/// matching overview property. Unknown entities -> dispatch_plan returns None
/// (the cache still holds them for a future detail page).
fn apply_ha_event(ui: &App, ev: HaEvent) {
    match ev {
        HaEvent::Connection(c) => {
            let s = match c {
                Connection::Connected => "connected",
                Connection::Connecting => "connecting",
                Connection::Disconnected => "disconnected",
            };
            ui.set_connection(s.into());
        }
        HaEvent::State {
            entity_id,
            new_state,
        } => match dispatch::dispatch_plan(&entity_id, &new_state) {
            Some(UiUpdate::AirQuality(Air::Breathable)) => ui.set_air_quality("BREATHABLE".into()),
            Some(UiUpdate::AirQuality(Air::Contaminated)) => {
                ui.set_air_quality("CONTAMINATED".into())
            }
            Some(UiUpdate::Occupancy(Occ::Occupied)) => ui.set_occupancy("OCCUPIED".into()),
            Some(UiUpdate::Occupancy(Occ::Vacant)) => ui.set_occupancy("VACANT".into()),
            Some(UiUpdate::RoomLightsOn(b)) => ui.set_room_lights_on(b),
            Some(UiUpdate::Temperature(t)) => ui.set_temperature(t.into()),
            Some(UiUpdate::PrinterState(p)) => ui.set_printer_state(p.label().into()),
            Some(UiUpdate::CeilingLight { on, brightness_pct }) => {
                ui.set_ceiling_on(on);
                ui.set_ceiling_brightness(brightness_pct.unwrap_or(0) as i32);
            }
            Some(UiUpdate::FanLight { on, brightness_pct }) => {
                ui.set_fan_on(on);
                ui.set_fan_brightness(brightness_pct.unwrap_or(0) as i32);
            }
            Some(UiUpdate::BedLight { on, brightness_pct }) => {
                ui.set_bed_on(on);
                ui.set_bed_brightness(brightness_pct.unwrap_or(0) as i32);
            }
            Some(UiUpdate::EnviroSensor { which, value }) => match which {
                dispatch::EnviroSensor::Co2 => ui.set_enviro_co2(value),
                dispatch::EnviroSensor::Pm25 => ui.set_enviro_pm25(value),
                dispatch::EnviroSensor::Temp => ui.set_enviro_temp(value),
                dispatch::EnviroSensor::Humidity => ui.set_enviro_hum(value),
            },
            Some(UiUpdate::Weight(w)) => ui.set_stat_weight(w),
            Some(UiUpdate::Bmi(b)) => ui.set_stat_bmi(b),
            Some(UiUpdate::BodyMetric { which, value }) => match which {
                dispatch::BodyMetric::BodyFat => ui.set_stat_body_fat(value),
                dispatch::BodyMetric::Muscle => ui.set_stat_muscle(value),
                dispatch::BodyMetric::Water => ui.set_stat_water(value),
                dispatch::BodyMetric::LeanMass => ui.set_stat_lean(value),
                dispatch::BodyMetric::FatMass => ui.set_stat_fat_mass(value),
                dispatch::BodyMetric::BoneMass => ui.set_stat_bone(value),
                dispatch::BodyMetric::Bmr => ui.set_stat_bmr(value),
                dispatch::BodyMetric::MetabolicAge => ui.set_stat_metabolic_age(value),
                dispatch::BodyMetric::VisceralFat => ui.set_stat_visceral(value),
            },
            Some(UiUpdate::Shift {
                starts,
                day,
                date,
                start,
                end,
                duration,
                location,
                week_count,
                week_hours,
            }) => {
                ui.set_shift_starts(starts.into());
                ui.set_shift_day(day.into());
                ui.set_shift_date(date.into());
                ui.set_shift_start(start.into());
                ui.set_shift_end(end.into());
                ui.set_shift_duration(duration.into());
                ui.set_shift_location(location.into());
                ui.set_shift_week_count(week_count.into());
                ui.set_shift_week_hours(week_hours.into());
            }
            Some(UiUpdate::PayField { which, value }) => match which {
                dispatch::PayField::Period => ui.set_pay_period(value.into()),
                dispatch::PayField::Net => ui.set_pay_net(value.into()),
                dispatch::PayField::Annual => ui.set_pay_annual(value.into()),
                dispatch::PayField::Sick => ui.set_pay_sick(value.into()),
            },
            None => {}
        },
    }
}
