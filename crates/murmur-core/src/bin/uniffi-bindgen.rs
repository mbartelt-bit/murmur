//! `cargo run -p murmur-core --features cli --bin uniffi-bindgen -- generate ...`
//! Pinned to the same uniffi version as the library, so bindings can never drift
//! from the scaffolding.
fn main() {
    uniffi::uniffi_bindgen_main()
}
