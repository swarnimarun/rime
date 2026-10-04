//! Path-only leaf member: no registry deps of its own.

/// Format a one-line summary for a named value.
pub fn summarize(name: &str, value: i64) -> String {
    format!("{name}={value}")
}
