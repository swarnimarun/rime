//! Integration test target for the breadth fixture.
#[test]
fn adds() {
    assert_eq!(full_manifest::add(40, 2), 42);
}
