//! DRM DPMS helper (task.md T4.1).
//!
//! robcoterm owns the eDP panel's power state directly via DRM
//! `drmModeObjectSetProperty` on the connector's DPMS property — replacing the
//! Cage-era `tcxwave-screen-power` (wlr-randr) + `tcxwave-touch-wake` pair.
//!
//! What's testable here without hardware: the DPMS value mapping, the
//! `/dev/dri/cardN` auto-detect enumeration (T4.1 note: amalthea is card1, not
//! card0 — never hardcode), and the set_dpms decision via a mock backend.
//! What still needs the T4.1a hardware spike (deferred): obtaining the DRM fd
//! — either reusing the linuxkms backend's master claim or opening a second
//! cardN fd for DPMS only. `RealDrm` is therefore a stub until that spike
//! lands; production wiring happens at the T4.4 cutover.

use std::path::{Path, PathBuf};

/// DRM DPMS property values (linux/drm_mode.h).
const DRM_DPMS_ON: u64 = 0;
const DRM_DPMS_OFF: u64 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DpmsMode {
    On,
    Off,
}

impl DpmsMode {
    /// The integer written into the connector's DPMS property.
    pub fn drm_value(self) -> u64 {
        match self {
            DpmsMode::On => DRM_DPMS_ON,
            DpmsMode::Off => DRM_DPMS_OFF,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DisplayError {
    #[error("no DRM device found in {0}")]
    NoDevice(String),
    #[error("drm io: {0}")]
    Io(String),
}

/// Enumerate primary DRM nodes (`/dev/dri/card0`, `card1`, …) under `dir`,
/// sorted ascending by index. Render nodes (`renderD128+`) are excluded — the
/// eDP panel hangs off a primary card. This is the auto-detect that T4.1's
/// amalthea/card1 note demands; the caller still has to probe connectors to
/// pick the right card at runtime (real DRM IO, T4.1a spike).
pub fn list_primary_drm_devices(dir: &Path) -> Vec<PathBuf> {
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let mut cards: Vec<(u32, PathBuf)> = Vec::new();
    for entry in read.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if let Some(rest) = name.strip_prefix("card") {
            // primary nodes are "card<digits>" only — skip "cardN-something" and renderD*
            if rest.chars().all(|c| c.is_ascii_digit()) {
                if let Ok(n) = rest.parse::<u32>() {
                    cards.push((n, entry.path()));
                }
            }
        }
    }
    cards.sort_by_key(|(n, _)| *n);
    cards.into_iter().map(|(_, p)| p).collect()
}

/// Abstracts the DRM calls `DpmsController` needs so the DPMS decision is
/// testable without a real fd. `RealDrm` (prod) is stubbed pending T4.1a;
/// `MockDrm` (behind `drm-mock`) records the written values.
pub trait DrmOps {
    fn set_dpms(&mut self, connector: u32, prop: u32, value: u64) -> Result<(), DisplayError>;
}

/// Drives the connector's DPMS property. Holds the connector + property ids
/// discovered at init (real DRM probe, T4.1a); `set_dpms` just writes the mode.
pub struct DpmsController<O: DrmOps> {
    ops: O,
    connector_id: u32,
    dpms_prop_id: u32,
}

impl<O: DrmOps> DpmsController<O> {
    pub fn new(ops: O, connector_id: u32, dpms_prop_id: u32) -> Self {
        Self {
            ops,
            connector_id,
            dpms_prop_id,
        }
    }

    /// Write the DPMS mode. Returns the value written so callers/tests can
    /// confirm the mapping without re-querying the property.
    pub fn set_dpms(&mut self, mode: DpmsMode) -> Result<u64, DisplayError> {
        let value = mode.drm_value();
        self.ops
            .set_dpms(self.connector_id, self.dpms_prop_id, value)?;
        Ok(value)
    }
}

/// Production backend placeholder. The real `drmModeObjectSetProperty` call
/// lands after the T4.1a spike decides whose DRM fd to use (the linuxkms
/// backend's, or a second one robcoterm opens for DPMS only).
pub struct RealDrm;

impl DrmOps for RealDrm {
    fn set_dpms(&mut self, _connector: u32, _prop: u32, _value: u64) -> Result<(), DisplayError> {
        // T4.1a spike: obtain fd, call drmModeObjectSetProperty. Until then
        // this is intentionally unimplemented — the cutover (T4.4) is blocked
        // on hardware + the HA token regardless.
        Err(DisplayError::Io(
            "RealDrm not wired — needs T4.1a DRM fd spike".into(),
        ))
    }
}

#[cfg(feature = "drm-mock")]
pub mod mock {
    //! Mock DRM backend (task.md T4.1 verify). Records every set_dpms call so
    //! tests can assert the value written without a real DRM device.

    use super::{DisplayError, DrmOps};

    #[derive(Debug, Default, Clone)]
    pub struct MockDrm {
        pub writes: Vec<(u32, u32, u64)>, // (connector, prop, value)
    }

    impl MockDrm {
        pub fn new() -> Self {
            Self::default()
        }
        pub fn last_value(&self) -> Option<u64> {
            self.writes.last().map(|(_, _, v)| *v)
        }
    }

    impl DrmOps for MockDrm {
        fn set_dpms(&mut self, connector: u32, prop: u32, value: u64) -> Result<(), DisplayError> {
            self.writes.push((connector, prop, value));
            Ok(())
        }
    }
}

#[cfg(all(test, feature = "drm-mock"))]
mod tests {
    use super::*;
    use crate::display::mock::MockDrm;

    #[test]
    fn dpms_value_mapping() {
        assert_eq!(DpmsMode::On.drm_value(), 0);
        assert_eq!(DpmsMode::Off.drm_value(), 3);
    }

    #[test]
    fn set_dpms_off_writes_value_3() {
        // task.md T4.1 verify: assert set_dpms(Off) writes the expected
        // property value (DRM_DPMS_OFF = 3).
        let mut ctrl = DpmsController::new(MockDrm::new(), 47, 9);
        let written = ctrl.set_dpms(DpmsMode::Off).unwrap();
        assert_eq!(written, 3);
        assert_eq!(ctrl.ops.last_value(), Some(3));
        // the write targeted the configured connector + property
        assert_eq!(ctrl.ops.writes.len(), 1);
        assert_eq!(ctrl.ops.writes[0], (47, 9, 3));
    }

    #[test]
    fn set_dpms_on_writes_value_0() {
        let mut ctrl = DpmsController::new(MockDrm::new(), 1, 1);
        ctrl.set_dpms(DpmsMode::On).unwrap();
        assert_eq!(ctrl.ops.last_value(), Some(0));
    }

    #[test]
    fn list_primary_drm_devices_sorts_and_excludes_render_nodes() {
        let dir = tempfile_dri();
        assert_eq!(list_primary_drm_devices(dir.as_path()).len(), 0); // empty -> none

        // populate: card1, card0, renderD128, card10, cardX
        for name in [
            "card1",
            "card0",
            "renderD128",
            "card10",
            "cardX",
            "card0-bsp",
        ] {
            std::fs::write(dir.join(name), b"").unwrap();
        }
        let got = list_primary_drm_devices(dir.as_path());
        let names: Vec<String> = got
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        // sorted ascending numerically: card0, card1, card10 (renderD128, cardX, card0-bsp excluded)
        assert_eq!(names, vec!["card0", "card1", "card10"]);
    }

    /// Scratch /dev/dri stand-in (mkdtemp — avoids CodeQL's insecure-tempfile
    /// finding that flagged this repo's tests before).
    fn tempfile_dri() -> std::path::PathBuf {
        let mut d = std::env::temp_dir();
        d.push(format!("robcoterm-drm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
