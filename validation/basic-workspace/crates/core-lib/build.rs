//! Build script: asserts build-deps resolve and emits a cfg flag.
fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_build_dep)");
    println!("cargo::rustc-cfg=has_build_dep");
}
