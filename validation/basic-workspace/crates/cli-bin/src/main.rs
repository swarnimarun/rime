//! Binary member: exercises lib + path-dep wiring end to end.

use anyhow::Result;

fn main() -> Result<()> {
    let record = core_lib::Record::new("demo", 42);
    println!("{}", record.describe());
    Ok(())
}
