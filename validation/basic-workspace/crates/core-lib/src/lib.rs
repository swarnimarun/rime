//! Core library member: shared types for the workspace.

use serde::{Deserialize, Serialize};

/// A shared record used by the bin and util members.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub name: String,
    pub value: i64,
}

impl Record {
    /// Build a record from parts.
    pub fn new(name: impl Into<String>, value: i64) -> Self {
        Self {
            name: name.into(),
            value,
        }
    }

    /// Describe the record (also exercises the `util` path dependency).
    pub fn describe(&self) -> String {
        util::summarize(&self.name, self.value)
    }
}
