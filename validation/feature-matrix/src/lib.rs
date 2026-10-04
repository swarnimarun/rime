//! Feature-matrix fixture: every cfg/feature combination must parse.

/// Serialize a value when the `json` feature is on.
#[cfg(feature = "json")]
pub fn to_json(value: &serde_json::Value) -> String {
    value.to_string()
}

/// Fallback when `json` is off so the crate builds in all configs.
#[cfg(not(feature = "json"))]
pub fn to_json(_opaque: &str) -> String {
    String::from("{}")
}

/// Plain helper that is always available.
pub fn ping() -> &'static str {
    "pong"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_works() {
        assert_eq!(ping(), "pong");
    }
}
