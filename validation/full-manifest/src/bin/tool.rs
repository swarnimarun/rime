//! Binary target for the breadth fixture.

use anyhow::Result;

fn main() -> Result<()> {
    println!("2 + 2 = {}", full_manifest::add(2, 2));
    Ok(())
}
