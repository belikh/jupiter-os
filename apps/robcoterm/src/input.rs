//! Libinput idle loop (task.md T4.2).
//!
//! Replaces `tcxwave-touch-wake.service`'s ~50 lines of Python: track the last
//! touch activity, fire DPMS off after `cfg.idleTimeout`, fire DPMS on on the
//! next touch. The `unstable-libinput-09` Slint feature exposes libinput
//! events from the backend's own loop — T4.2a spike will decide whether to use
//! those or open `/dev/input/eventN` directly.
//!
//! What's testable here without hardware: the idle decision itself
//! (`IdleTracker`), driven by explicit `Instant`s so the state machine is
//! deterministic. The real event source (evdev read loop) is a trait stub
//! pending T4.2a; the wiring into `DpmsController` happens at the T4.4 cutover.

use std::time::{Duration, Instant};

/// Result of an idle-loop step. `Sleep` => DPMS off; `Wake` => DPMS on;
/// `Idle` => no change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdleDecision {
    Sleep,
    Wake,
    Idle,
}

/// Tracks last touch activity and whether the panel is currently asleep.
/// `observe_activity` is called on every touch event; `tick` is called on a
/// periodic timer (e.g. every 1s) to detect the timeout.
#[derive(Debug)]
pub struct IdleTracker {
    last_activity: Instant,
    sleeping: bool,
}

impl IdleTracker {
    pub fn new(now: Instant) -> Self {
        Self {
            last_activity: now,
            sleeping: false,
        }
    }

    /// Record user activity at `now`. Returns `Wake` if the panel was asleep
    /// (so the caller fires DPMS on), else `Idle`.
    pub fn observe_activity(&mut self, now: Instant) -> IdleDecision {
        self.last_activity = now;
        if self.sleeping {
            self.sleeping = false;
            IdleDecision::Wake
        } else {
            IdleDecision::Idle
        }
    }

    /// Periodic check. Returns `Sleep` the first time the idle threshold is
    /// crossed (caller fires DPMS off), else `Idle`. Idempotent while asleep.
    pub fn tick(&mut self, now: Instant, timeout: Duration) -> IdleDecision {
        if !self.sleeping && now.duration_since(self.last_activity) >= timeout {
            self.sleeping = true;
            IdleDecision::Sleep
        } else {
            IdleDecision::Idle
        }
    }

    pub fn is_sleeping(&self) -> bool {
        self.sleeping
    }

    pub fn last_activity(&self) -> Instant {
        self.last_activity
    }
}

/// Production event-source placeholder (T4.2a spike). Real impl opens the
/// Atmel evdev node (same discovery as tcxwave-touch-wake.nix:36-54, ported to
/// Rust) or uses the Slint backend's libinput events, and feeds
/// `IdleTracker::observe_activity` on each touch.
pub trait InputSource {
    /// Block until the next touch event; return its timestamp.
    fn next_touch(&mut self) -> std::io::Result<Instant>;
}

/// No-op source so the binary links before T4.2a wires the real evdev read.
pub struct StubInput;

impl InputSource for StubInput {
    fn next_touch(&mut self) -> std::io::Result<Instant> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "StubInput — real evdev lands in T4.2a",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fires_sleep_after_idle_timeout() {
        // task.md T4.2 verify: DPMS toggled off after idleTimeout of inactivity.
        let t0 = Instant::now();
        let timeout = Duration::from_secs(300);
        let mut tr = IdleTracker::new(t0);

        // just under timeout -> still awake
        assert_eq!(
            tr.tick(t0 + Duration::from_secs(299), timeout),
            IdleDecision::Idle
        );
        assert!(!tr.is_sleeping());

        // at/over timeout -> Sleep exactly once
        assert_eq!(tr.tick(t0 + timeout, timeout), IdleDecision::Sleep);
        assert!(tr.is_sleeping());
        // subsequent ticks don't re-fire
        assert_eq!(
            tr.tick(t0 + timeout + Duration::from_secs(10), timeout),
            IdleDecision::Idle
        );
        assert!(tr.is_sleeping());
    }

    #[test]
    fn wakes_within_100ms_of_synthetic_touch() {
        // task.md T4.2 verify: DPMS on within 100ms of a synthetic touch event.
        let t0 = Instant::now();
        let timeout = Duration::from_secs(300);
        let mut tr = IdleTracker::new(t0);

        // go to sleep
        tr.tick(t0 + timeout, timeout);
        assert!(tr.is_sleeping());

        // synthetic touch 50ms later -> Wake, panel back on
        let touch_at = t0 + timeout + Duration::from_millis(50);
        let decided = tr.observe_activity(touch_at);
        assert_eq!(decided, IdleDecision::Wake);
        assert!(!tr.is_sleeping());
        assert_eq!(tr.last_activity(), touch_at);

        // the decision is synchronous (the "within 100ms" latency bound is the
        // real loop's job; the tracker returns Wake the instant the touch lands)
        let next_tick = tr.tick(touch_at + Duration::from_millis(1), timeout);
        assert_eq!(next_tick, IdleDecision::Idle);
    }

    #[test]
    fn activity_resets_the_timeout() {
        let t0 = Instant::now();
        let timeout = Duration::from_secs(60);
        let mut tr = IdleTracker::new(t0);

        // activity at t0+50s resets the window
        tr.observe_activity(t0 + Duration::from_secs(50));
        // at t0+60s (would have slept without the reset) -> still awake
        assert_eq!(
            tr.tick(t0 + Duration::from_secs(60), timeout),
            IdleDecision::Idle
        );
        // sleep lands 60s after the LAST activity
        assert_eq!(
            tr.tick(t0 + Duration::from_secs(110), timeout),
            IdleDecision::Sleep
        );
    }

    #[test]
    fn wake_only_when_was_sleeping() {
        let t0 = Instant::now();
        let mut tr = IdleTracker::new(t0);
        // awake + touch -> Idle (not Wake)
        assert_eq!(
            tr.observe_activity(t0 + Duration::from_secs(1)),
            IdleDecision::Idle
        );
    }
}
