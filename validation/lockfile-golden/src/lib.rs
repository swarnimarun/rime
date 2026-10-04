//! Lockfile golden fixture: exercises several real crates.io deps.

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// A record that round-trips through serde_json.
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Record {
    pub name: String,
}

/// Parse a record from JSON.
pub fn parse(input: &str) -> Result<Record> {
    Ok(serde_json::from_str(input)?)
}

/// Report the current process id via libc (unix only).
#[cfg(unix)]
pub fn current_pid() -> i32 {
    // SAFETY: getpid has no preconditions.
    unsafe { libc::getpid() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let record = parse(r#"{"name":"rime"}"#).unwrap();
        assert_eq!(record.name, "rime");
    }
}
