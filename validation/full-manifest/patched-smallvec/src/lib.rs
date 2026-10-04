//! Minimal stand-in for the patched `smallvec` crate.
//!
//! It only needs to satisfy the patched dependency graph; the API
//! surface is intentionally tiny.

/// A minimal vector stand-in backed by `Vec`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SmallVec<T>(pub Vec<T>);

impl<T> SmallVec<T> {
    /// Create an empty collection.
    pub fn new() -> Self {
        Self(Vec::new())
    }

    /// Push a value.
    pub fn push(&mut self, value: T) {
        self.0.push(value);
    }

    /// Number of elements.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Whether the collection is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}
