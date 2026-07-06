// Instantiate the Slint UI and run the event loop. On amalthea this drives the
// backend-linuxkms-noseat backend: it opens /dev/dri/cardN, claims DRM master,
// modesets the eDP connector, and renders the placeholder. Returns
// slint::PlatformError (printed by Rust's default Termination) if DRM/master
// setup fails — that error string is the diagnostic for the smoke test.
slint::include_modules!();

fn main() -> Result<(), slint::PlatformError> {
    App::new()?.run()
}
