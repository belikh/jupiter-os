//! Home Assistant WebSocket client (task.md T2.1, T2.3, T2.4).
//!
//! The worker owns the tokio runtime side: it opens `wss://` (or `ws://` in
//! tests), does the HA `auth_required -> auth -> auth_ok` handshake, primes
//! the shared `StateCache` via `get_states`, subscribes to `state_changed`,
//! and drains UI-originated `ServiceCall`s into `call_service` frames.
//!
//! Thread bridge (implementation_plan.md §1, Phase 3.4):
//!   - worker -> UI : `events_rx` carries `HaEvent::{State, Connection}`. The
//!     UI side will forward via `slint::invoke_from_event_loop` in T3.4.
//!   - UI -> worker: `calls` (`mpsc::Sender<ServiceCall>`). The worker is the
//!     sole receiver.
//!
//! Reconnect (T2.4): exponential backoff capped at `backoff_cap`. Every
//! transition emits `HaEvent::Connection`, which is what the UI's
//! `ReconnectBanner` overlay listens for. The thebe wireless boot race is
//! handled here by retry, retiring the Chromium-era "wait for default route"
//! shell wrapper.

use crate::state::EntityState;
use crate::state::StateCache;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use thiserror::Error;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

/// Worker -> UI events. `State` carries the freshly-typed entity view (the
/// cache is already updated by the time this is emitted). `Connection` is the
/// reconnect lifecycle signal for the ReconnectBanner overlay (T3.4).
#[derive(Debug, Clone)]
pub enum HaEvent {
    State {
        entity_id: String,
        new_state: EntityState,
    },
    Connection(Connection),
}

/// Reconnect lifecycle. Emitted on every transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Connection {
    Connecting,
    Connected,
    Disconnected,
}

/// UI -> worker service calls (task.md T2.3). The `domain` for `Light` and
/// `Toggle` is derived from the entity_id (`light.x` -> `light`); `CallService`
/// is the escape hatch for anything not covered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServiceCall {
    /// `light.turn_on` with optional `brightness_pct` (0..=100). `None` =
    /// turn on at last brightness.
    Light {
        entity: String,
        brightness_pct: Option<u8>,
    },
    /// `<domain>.toggle` on the entity.
    Toggle { entity: String },
    /// Raw `call_service` — caller supplies domain/service/service_data.
    CallService {
        domain: String,
        service: String,
        payload: Value,
    },
}

impl ServiceCall {
    /// Render to a HA `call_service` websocket frame with the given id.
    pub fn to_frame(&self, id: u64) -> Value {
        match self {
            ServiceCall::Light {
                entity,
                brightness_pct,
            } => {
                let service_data = match brightness_pct {
                    Some(b) => json!({ "entity_id": entity, "brightness_pct": b }),
                    None => json!({ "entity_id": entity }),
                };
                json!({
                    "type": "call_service",
                    "domain": EntityState::domain_of(entity),
                    "service": "turn_on",
                    "service_data": service_data,
                    "id": id,
                })
            }
            ServiceCall::Toggle { entity } => json!({
                "type": "call_service",
                "domain": EntityState::domain_of(entity),
                "service": "toggle",
                "service_data": { "entity_id": entity },
                "id": id,
            }),
            ServiceCall::CallService {
                domain,
                service,
                payload,
            } => json!({
                "type": "call_service",
                "domain": domain,
                "service": service,
                "service_data": payload,
                "id": id,
            }),
        }
    }
}

#[derive(Debug, Error)]
pub enum HaError {
    #[error("transport: {0}")]
    Transport(String),
    #[error("handshake: {0}")]
    Handshake(String),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("url: {0}")]
    Url(#[from] url::ParseError),
}

impl From<tokio_tungstenite::tungstenite::Error> for HaError {
    fn from(e: tokio_tungstenite::tungstenite::Error) -> Self {
        HaError::Transport(e.to_string())
    }
}

/// Worker configuration. `backoff_start`/`backoff_cap` are parameterised so
/// tests can shrink them; production uses 1s -> 30s (per implementation_plan
/// §Phase 2.4).
pub struct HaConfig {
    pub url: String,
    pub token: String,
    pub backoff_start: Duration,
    pub backoff_cap: Duration,
}

/// Handle returned to the caller. Drop `calls` to gracefully shut the worker
/// down (it will not reconnect after that).
pub struct HaLink {
    pub calls: mpsc::Sender<ServiceCall>,
    pub events: mpsc::Receiver<HaEvent>,
}

/// Spawn the HA worker on the current runtime. Returns the two channel ends
/// the UI thread uses.
pub fn spawn(cfg: HaConfig) -> HaLink {
    let (calls_tx, calls_rx) = mpsc::channel::<ServiceCall>(16);
    let (events_tx, events_rx) = mpsc::channel::<HaEvent>(64);
    tokio::spawn(async move {
        run(cfg, calls_rx, events_tx).await;
    });
    HaLink {
        calls: calls_tx,
        events: events_rx,
    }
}

/// Top-level reconnect loop. Emits `Connecting` at the top of each attempt,
/// `Connected` once the handshake completes, and `Disconnected` + backoff on
/// any connection loss.
async fn run(
    cfg: HaConfig,
    mut calls_rx: mpsc::Receiver<ServiceCall>,
    events_tx: mpsc::Sender<HaEvent>,
) {
    let mut backoff = cfg.backoff_start;
    loop {
        let _ = events_tx
            .send(HaEvent::Connection(Connection::Connecting))
            .await;
        match connect_and_run(&cfg, &mut calls_rx, &events_tx).await {
            Ok(()) => return, // calls channel closed -> graceful shutdown
            Err(_e) => {
                let _ = events_tx
                    .send(HaEvent::Connection(Connection::Disconnected))
                    .await;
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(cfg.backoff_cap);
            }
        }
    }
}

/// One connection attempt: open, handshake, prime, subscribe, then run the
/// select loop until the connection drops or the calls channel closes.
async fn connect_and_run(
    cfg: &HaConfig,
    calls_rx: &mut mpsc::Receiver<ServiceCall>,
    events_tx: &mpsc::Sender<HaEvent>,
) -> Result<(), HaError> {
    let (ws, _resp) = tokio_tungstenite::connect_async(&cfg.url).await?;
    let mut ws = ws;
    do_handshake(&mut ws, &cfg.token).await?;
    let _ = events_tx
        .send(HaEvent::Connection(Connection::Connected))
        .await;

    // Prime + subscribe. HA assigns our commands ids; we just need them
    // unique within this connection.
    let mut next_id: u64 = 1;
    let cache = StateCache::new();
    let sub = json!({ "type": "subscribe_events", "event_type": "state_changed", "id": next_id });
    next_id += 1;
    let get_states = json!({ "type": "get_states", "id": next_id });
    next_id += 1;
    ws.send(Message::Text(sub.to_string().into())).await?;
    ws.send(Message::Text(get_states.to_string().into()))
        .await?;

    let (mut sink, mut stream) = ws.split();
    loop {
        tokio::select! {
            msg = stream.next() => match msg {
                Some(Ok(Message::Text(t))) => {
                    if let Err(_e) = handle_inbound(t.as_str(), &cache, events_tx).await {
                        // A single malformed frame shouldn't kill the link.
                    }
                }
                Some(Ok(_)) => {} // ignore Binary/Ping/Pong/Close frames
                Some(Err(_)) | None => return Err(HaError::Transport("connection lost".into())),
            },
            call = calls_rx.recv() => match call {
                Some(c) => {
                    let frame = c.to_frame(next_id);
                    next_id += 1;
                    sink.send(Message::Text(frame.to_string().into())).await?;
                }
                None => return Ok(()), // UI dropped the sender -> stop
            },
        }
    }
}

/// HA auth handshake (T2.1): wait for `auth_required`, send `auth`, expect
/// `auth_ok`. Generic over the underlying transport so the same code runs
/// against `ws://` (tests) and `wss://` (prod, via `MaybeTlsStream`).
async fn do_handshake<S>(ws: &mut WebSocketStream<S>, token: &str) -> Result<(), HaError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
{
    // 1. auth_required
    let msg = ws
        .next()
        .await
        .ok_or_else(|| HaError::Handshake("server closed before auth_required".into()))??;
    require_auth_required(&msg)?;

    // 2. auth{access_token}  -- token is never logged (only placed on the wire)
    let auth = json!({ "type": "auth", "access_token": token }).to_string();
    ws.send(Message::Text(auth.into())).await?;

    // 3. auth_ok | auth_invalid
    let msg = ws
        .next()
        .await
        .ok_or_else(|| HaError::Handshake("server closed before auth_ok".into()))??;
    match parse_type(&msg).as_deref() {
        Some("auth_ok") => Ok(()),
        Some("auth_invalid") => Err(HaError::Handshake("auth_invalid".into())),
        other => Err(HaError::Handshake(format!(
            "unexpected auth reply: {other:?}"
        ))),
    }
}

fn require_auth_required(msg: &Message) -> Result<(), HaError> {
    match parse_type(msg).as_deref() {
        Some("auth_required") => Ok(()),
        other => Err(HaError::Handshake(format!(
            "expected auth_required, got {other:?}"
        ))),
    }
}

/// Pull the HA frame's `"type"` string out of a Text message, else None.
/// Returns an owned `String` because the parsed `Value` is local; callers use
/// `.as_deref()` to compare against `'static` str literals cheaply.
fn parse_type(msg: &Message) -> Option<String> {
    let text = match msg {
        Message::Text(t) => t.as_str(),
        _ => return None,
    };
    let v: Value = serde_json::from_str(text).ok()?;
    v.get("type")?.as_str().map(str::to_owned)
}

/// Apply one inbound HA frame: `event` (state_changed) -> cache + emit;
/// `result` (get_states prime) -> bulk cache fill (no per-entity emit).
async fn handle_inbound(
    text: &str,
    cache: &StateCache,
    events_tx: &mpsc::Sender<HaEvent>,
) -> Result<(), HaError> {
    let v: Value =
        serde_json::from_str(text).map_err(|e| HaError::Protocol(format!("json: {e}")))?;
    let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
    match ty {
        "event" => {
            let data = &v["event"]["data"];
            if let (Some(entity), Some(new_state)) = (
                data.get("entity_id").and_then(|e| e.as_str()),
                data.get("new_state"),
            ) {
                if !new_state.is_null() {
                    let typed = cache.apply_changed(entity, new_state);
                    let _ = events_tx
                        .send(HaEvent::State {
                            entity_id: entity.to_string(),
                            new_state: typed,
                        })
                        .await;
                }
            }
        }
        "result" if v.get("success").and_then(|s| s.as_bool()) == Some(true) => {
            if let Some(arr) = v.get("result").and_then(|r| r.as_array()) {
                for elem in arr {
                    if let Some(eid) = elem.get("entity_id").and_then(|e| e.as_str()) {
                        let _ = cache.apply_changed(eid, elem);
                    }
                }
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::net::TcpListener;
    use tokio_tungstenite::accept_async;

    /// The token the mock expects the client to present.
    const MOCK_TOKEN: &str = "ABCD-long-lived-token-1234";

    /// Build a HaConfig pointing at the mock's ws:// URL with fast backoff.
    fn cfg_for(addr: &str) -> HaConfig {
        HaConfig {
            url: format!("ws://{addr}/api/websocket"),
            token: MOCK_TOKEN.to_string(),
            backoff_start: Duration::from_millis(50),
            backoff_cap: Duration::from_millis(100),
        }
    }

    /// Find the first Connection event in the slice, if any.
    fn first_conn(events: &[HaEvent]) -> Option<Connection> {
        events.iter().find_map(|e| match e {
            HaEvent::Connection(c) => Some(*c),
            _ => None,
        })
    }

    // ---- T2.1: handshake -------------------------------------------------

    #[tokio::test]
    async fn handshake_sends_auth_frame_within_2s() {
        // task.md T2.1 verify: mock receives {"type":"auth","access_token":"…"}
        // within 2s.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let token_seen = tokio::sync::oneshot::channel::<String>();
        let (tx_token, rx_token) = token_seen;

        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            // 1. send auth_required
            ws.send(Message::Text(
                json!({ "type": "auth_required" }).to_string().into(),
            ))
            .await
            .unwrap();
            // 2. read client's auth frame
            let msg = ws.next().await.unwrap().unwrap();
            let text = match msg {
                Message::Text(t) => t.as_str().to_owned(),
                _ => String::new(),
            };
            let v: Value = serde_json::from_str(&text).unwrap();
            let token = v
                .get("access_token")
                .and_then(|t| t.as_str())
                .unwrap()
                .to_owned();
            let _ = tx_token.send(token);
            // 3. auth_ok
            ws.send(Message::Text(
                json!({ "type": "auth_ok" }).to_string().into(),
            ))
            .await
            .unwrap();
            // linger so the client stays Connected
            tokio::time::sleep(Duration::from_secs(3)).await;
        });

        let mut link = spawn(cfg_for(&addr.to_string()));
        // The first event must be Connecting, then Connected.
        let mut saw_connected = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        let mut token = String::new();
        tokio::select! {
            _ = async {
                while let Some(ev) = link.events.recv().await {
                    if matches!(ev, HaEvent::Connection(Connection::Connected)) {
                        saw_connected = true;
                        break;
                    }
                }
            } => {}
            _ = tokio::time::sleep_until(deadline) => {}
        }
        tokio::select! {
            t = rx_token => token = t.unwrap(),
            _ = tokio::time::sleep(Duration::from_secs(2)) => {}
        }
        assert_eq!(token, MOCK_TOKEN, "mock must receive the access_token");
        assert!(saw_connected, "client must reach Connected after handshake");
        drop(link.calls);
    }

    // ---- T2.2: state_changed -> cache + exactly one emit -----------------

    #[tokio::test]
    async fn state_changed_emits_exactly_one_event() {
        // task.md T2.2 verify: mock pushes a state_changed for
        // light.bedroom_ceiling; subscriber fired exactly once and the typed
        // state matches.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            ws.send(Message::Text(
                json!({ "type": "auth_required" }).to_string().into(),
            ))
            .await
            .unwrap();
            let _ = ws.next().await; // client auth
            ws.send(Message::Text(
                json!({ "type": "auth_ok" }).to_string().into(),
            ))
            .await
            .unwrap();
            // drain the client's subscribe_events + get_states commands
            for _ in 0..2 {
                let _ = ws.next().await;
            }
            // push one state_changed
            let push = json!({
                "type": "event",
                "event": {
                    "event_type": "state_changed",
                    "data": {
                        "entity_id": "light.bedroom_ceiling",
                        "new_state": {
                            "entity_id": "light.bedroom_ceiling",
                            "state": "on",
                            "attributes": { "brightness_pct": 80 }
                        }
                    }
                },
                "id": 1
            });
            ws.send(Message::Text(push.to_string().into()))
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_secs(3)).await;
        });

        let mut link = spawn(cfg_for(&addr.to_string()));
        // Collect State events for light.bedroom_ceiling within a tight window.
        let mut state_events = 0usize;
        let mut got = None;
        let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
        loop {
            tokio::select! {
                ev = link.events.recv() => match ev {
                    Some(HaEvent::State { entity_id, new_state }) if entity_id == "light.bedroom_ceiling" => {
                        state_events += 1;
                        got = Some(new_state);
                    }
                    Some(_) => {}
                    None => break,
                },
                _ = tokio::time::sleep_until(deadline) => break,
            }
        }
        assert_eq!(state_events, 1, "subscriber must fire exactly once");
        match got {
            Some(EntityState::Light {
                on: true,
                brightness_pct: Some(80),
            }) => {}
            other => panic!("expected Light on/b80, got {other:?}"),
        }
        drop(link.calls);
    }

    // ---- T2.3: service call -> call_service frame ------------------------

    #[tokio::test]
    async fn service_call_writes_call_service_frame() {
        // task.md T2.3 verify: push a Light call; mock asserts it received
        // {"type":"call_service","domain":"light","service":"turn_on",
        //  "service_data":{"brightness_pct":…}}.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx_frame, rx_frame) = tokio::sync::oneshot::channel::<Value>();

        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            ws.send(Message::Text(
                json!({ "type": "auth_required" }).to_string().into(),
            ))
            .await
            .unwrap();
            let _ = ws.next().await; // auth
            ws.send(Message::Text(
                json!({ "type": "auth_ok" }).to_string().into(),
            ))
            .await
            .unwrap();
            // drain subscribe_events + get_states
            for _ in 0..2 {
                let _ = ws.next().await;
            }
            // read the call_service frame the client sends next
            while let Some(Ok(msg)) = ws.next().await {
                if let Message::Text(t) = msg {
                    if let Ok(v) = serde_json::from_str::<Value>(t.as_str()) {
                        if v.get("type").and_then(|x| x.as_str()) == Some("call_service") {
                            let _ = tx_frame.send(v);
                            break;
                        }
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        });

        let mut link = spawn(cfg_for(&addr.to_string()));
        // Wait for Connected so we don't race the handshake
        let mut connected = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            tokio::select! {
                ev = link.events.recv() => {
                    if matches!(ev, Some(HaEvent::Connection(Connection::Connected))) { connected = true; break; }
                    if ev.is_none() { break; }
                }
                _ = tokio::time::sleep_until(deadline) => break,
            }
        }
        assert!(connected, "must connect before sending a call");
        link.calls
            .send(ServiceCall::Light {
                entity: "light.bedroom_ceiling".into(),
                brightness_pct: Some(80),
            })
            .await
            .unwrap();

        let frame = tokio::time::timeout(Duration::from_secs(2), rx_frame)
            .await
            .expect("mock never received the call_service frame")
            .unwrap();
        assert_eq!(frame["type"], "call_service");
        assert_eq!(frame["domain"], "light");
        assert_eq!(frame["service"], "turn_on");
        assert_eq!(frame["service_data"]["brightness_pct"], 80);
        assert_eq!(frame["service_data"]["entity_id"], "light.bedroom_ceiling");
        drop(link.calls);
    }

    // ---- T2.4: reconnect with backoff -----------------------------------

    #[tokio::test]
    async fn reconnect_emits_disconnected_then_connecting_then_connected() {
        // task.md T2.4 verify: kill the mock mid-session; subscriber saw
        // Disconnected then Connecting; fresh mock starts, Connected fires
        // within 2x backoff.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // Mock: 1st connection -> handshake + drop; 2nd connection ->
        // handshake + linger. Both share the same listener (reconnect hits
        // the same port).
        tokio::spawn(async move {
            for round in 0..2u32 {
                let (stream, _) = listener.accept().await.unwrap();
                let mut ws = accept_async(stream).await.unwrap();
                ws.send(Message::Text(
                    json!({ "type": "auth_required" }).to_string().into(),
                ))
                .await
                .unwrap();
                let _ = ws.next().await; // auth
                ws.send(Message::Text(
                    json!({ "type": "auth_ok" }).to_string().into(),
                ))
                .await
                .unwrap();
                if round == 0 {
                    // drop immediately -> client sees connection lost
                    drop(ws);
                } else {
                    // linger so the client stays Connected
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        });

        let mut link = spawn(cfg_for(&addr.to_string()));
        let mut seq: Vec<Connection> = Vec::new();
        let start = tokio::time::Instant::now();
        loop {
            if start.elapsed() > Duration::from_secs(3) {
                break;
            }
            tokio::select! {
                ev = link.events.recv() => match ev {
                    Some(HaEvent::Connection(c)) => {
                        // collapse consecutive duplicates so the assertion is about
                        // transitions, not chatty repeats
                        if seq.last() != Some(&c) {
                            seq.push(c);
                        }
                        // once we've seen Connected AFTER a Disconnected, we're done
                        if seq.contains(&Connection::Disconnected) && seq.last() == Some(&Connection::Connected) && start.elapsed() > Duration::from_millis(100) {
                            break;
                        }
                    }
                    Some(_) => {}
                    None => break,
                },
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
        // Must have seen at least: Connected, Disconnected, Connecting, Connected
        let has = |c: Connection| seq.contains(&c);
        assert!(has(Connection::Connected), "saw initial Connected");
        assert!(has(Connection::Disconnected), "saw Disconnected after drop");
        assert!(
            has(Connection::Connecting),
            "saw Connecting (reconnect attempt)"
        );
        // final state must be Connected (the fresh mock)
        assert_eq!(
            seq.last(),
            Some(&Connection::Connected),
            "reconnected to fresh mock; seq={seq:?}"
        );
        // and it happened within 2x backoff cap (100ms * 2 = 200ms) plus tolerance
        // for the handshake round-trips; the loop budget of 3s is generous.
        drop(link.calls);
    }

    // ---- pure unit: ServiceCall::to_frame (no network) -------------------

    #[test]
    fn service_call_to_frame_light_with_brightness() {
        let f = ServiceCall::Light {
            entity: "light.kitchen_main".into(),
            brightness_pct: Some(42),
        }
        .to_frame(7);
        assert_eq!(f["type"], "call_service");
        assert_eq!(f["domain"], "light");
        assert_eq!(f["service"], "turn_on");
        assert_eq!(f["service_data"]["brightness_pct"], 42);
        assert_eq!(f["service_data"]["entity_id"], "light.kitchen_main");
        assert_eq!(f["id"], 7);
    }

    #[test]
    fn service_call_to_frame_toggle_derives_domain() {
        let f = ServiceCall::Toggle {
            entity: "media_player.kitchen".into(),
        }
        .to_frame(3);
        assert_eq!(f["domain"], "media_player");
        assert_eq!(f["service"], "toggle");
    }

    #[test]
    fn first_conn_extracts_first_connection_event() {
        let events = vec![
            HaEvent::Connection(Connection::Connecting),
            HaEvent::Connection(Connection::Connected),
        ];
        assert_eq!(first_conn(&events), Some(Connection::Connecting));
    }
}
