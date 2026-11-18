//! sqlx::migrate! embeds the migrations: cargo builds again when they
//! change.

fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
