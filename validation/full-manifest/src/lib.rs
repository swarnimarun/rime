//! Breadth fixture library: exercises lib + build script cfg.

/// Add two numbers.
pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

/// Report whether the build script ran (cfg set in build.rs).
pub fn build_script_ran() -> bool {
    cfg!(has_build_script)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds() {
        assert_eq!(add(2, 2), 4);
    }
}
