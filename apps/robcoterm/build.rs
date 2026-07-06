fn main() {
    // Compile the placeholder UI at build time — this is what proves the
    // slint-build toolchain works end to end (parser + codegen). The generated
    // bindings are only consumed once main.rs instantiates App (Phase 3).
    slint_build::compile("ui/main.slint").expect("slint build failed");
}
