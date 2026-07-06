//! Room -> phosphor colour mapping (task.md T3.1).
//!
//! Kept as pure Rust (not inside the Slint global) so it is unit-testable
//! without a graphics backend. `main.rs` calls `room_color()` once at startup
//! and writes it into the Slint `Theme.primary` via `Theme::get(&ui).set_primary(...)`,
//! matching the four `fallout_retro_{amber,green,blue,purple}` web themes
//! (implementation_plan.md §6.1).

use slint::Color;

/// The four rooms a TCx Wave kiosk can render. Mirrors the
/// `robcotermKiosk.room` NixOS option enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Room {
    Bedroom,
    Kitchen,
    Office,
    Robbie,
}

impl Room {
    /// Parse the `--room` / `robcotermKiosk.room` value.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "bedroom" => Some(Self::Bedroom),
            "kitchen" => Some(Self::Kitchen),
            "office" => Some(Self::Office),
            "robbie" => Some(Self::Robbie),
            _ => None,
        }
    }
}

/// Room -> phosphor colour. Locked values from implementation_plan.md §6.1:
/// bedroom→amber #ffb642, kitchen→green #1aff1a, office→blue #3399ff,
/// robbie→purple #b366ff.
pub fn room_color(room: Room) -> Color {
    match room {
        Room::Bedroom => Color::from_rgb_u8(0xff, 0xb6, 0x42),
        Room::Kitchen => Color::from_rgb_u8(0x1a, 0xff, 0x1a),
        Room::Office => Color::from_rgb_u8(0x33, 0x99, 0xff),
        Room::Robbie => Color::from_rgb_u8(0xb3, 0x66, 0xff),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(c: Color) -> u32 {
        // slint::Color::to_argb_u8 returns a RgbaColor<u8> struct (red/green/blue/alpha fields).
        let c = c.to_argb_u8();
        (u32::from(c.red) << 16) | (u32::from(c.green) << 8) | u32::from(c.blue)
    }

    #[test]
    fn office_is_blue_3399ff() {
        // task.md T3.1 verify: --room office -> primary == #3399ff
        assert_eq!(hex(room_color(Room::Office)), 0x3399ff);
    }

    #[test]
    fn bedroom_is_amber_ffb642() {
        assert_eq!(hex(room_color(Room::Bedroom)), 0xffb642);
    }

    #[test]
    fn kitchen_is_green_1aff1a() {
        assert_eq!(hex(room_color(Room::Kitchen)), 0x1aff1a);
    }

    #[test]
    fn robbie_is_purple_b366ff() {
        assert_eq!(hex(room_color(Room::Robbie)), 0xb366ff);
    }

    #[test]
    fn parse_round_trips_all_four_rooms() {
        for s in ["bedroom", "kitchen", "office", "robbie"] {
            assert!(Room::parse(s).is_some(), "{s} should parse");
        }
        assert!(Room::parse("garage").is_none());
        assert!(Room::parse("").is_none());
    }
}
