//! Connects to the gateway with real credentials and prints what it
//! dispatches, until interrupted. Sends nothing.
//!
//! ```sh
//! QQBOT_APP_ID=… QQBOT_SECRET=… cargo run -p qqbot --example listen
//! ```

#![expect(
    clippy::print_stdout,
    reason = "printing what the gateway sends is the point"
)]

use qqbot::gateway::{GROUP_AND_C2C, Session};
use qqbot::{Client, Credentials, Dispatch};
use tokio::sync::mpsc;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let credentials = Credentials {
        app_id: std::env::var("QQBOT_APP_ID")?,
        secret: std::env::var("QQBOT_SECRET")?,
    };
    tracing_subscriber::fmt::init();
    let client = Client::new(credentials)?;
    let me = client.me().await?;
    println!("connected as {} ({})", me.username, me.id);
    let (events, mut received) = mpsc::unbounded_channel::<Dispatch>();
    let print = async {
        while let Some(dispatch) = received.recv().await {
            println!("{} {}", dispatch.kind, dispatch.data);
        }
    };
    let mut session = Session::new(GROUP_AND_C2C);
    let (ran, ()) = tokio::join!(qqbot::run(&client, &mut session, events), print);
    Ok(ran?)
}
