//! Bench target (harness = false) for the breadth fixture.
fn main() {
    let mut sum = 0u64;
    for i in 0..1000 {
        sum += full_manifest::add(i, i);
    }
    println!("{sum}");
}
