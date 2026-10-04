//! Build script for the breadth fixture.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_build_script)");
    println!("cargo::rustc-cfg=has_build_script");
}
