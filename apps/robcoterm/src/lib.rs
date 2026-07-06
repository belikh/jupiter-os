//! robcoterm library crate — UI-agnostic, testable logic.
//!
//! The binary in `src/main.rs` owns the Slint event loop (main thread); this
//! crate holds everything that must be unit/integration-testable without a
//! DRM scanout:
//!   - `ha`     — Home Assistant WebSocket client (Phase 2)
//!   - `state`  — typed entity state cache (Phase 2)
//!
//! Phase 3 adds `dispatch` and Phase 4 add `display`/`input` here.

pub mod ha;
pub mod state;
pub mod theme;
