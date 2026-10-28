// sqlx::migrate! embeds the migrations; rebuild when they change.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
