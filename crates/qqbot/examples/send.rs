//! Sends one message, or recalls one, for trying things against the real
//! API. The message's text comes from stdin; with a picture, it is the
//! text under it, and a file goes without it.
//!
//! ```sh
//! export QQBOT_APP_ID=… QQBOT_SECRET=…
//! echo 早 | cargo run -p qqbot --example send -- group <group_openid> [markdown] [picture <path> | file <path>] [quote <msg_idx>]
//! cargo run -p qqbot --example send -- group <group_openid> recall <id>
//! ```

#![expect(clippy::print_stdout, reason = "printing QQ's answer is the point")]

use std::io::Read;

use qqbot::api::Media;
use qqbot::{Body, Chat, Client, Credentials, Outgoing};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let credentials = Credentials {
        app_id: std::env::var("QQBOT_APP_ID")?,
        secret: std::env::var("QQBOT_SECRET")?,
    };
    let client = Client::new(credentials)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [kind, openid, rest @ ..] = args.as_slice() else {
        return Err("usage: send group|user <openid> [options]".into());
    };
    let chat = match kind.as_str() {
        "group" => Chat::Group(openid),
        "user" => Chat::User(openid),
        _ => return Err(format!("not group or user: {kind}").into()),
    };
    if let [recall, id] = rest
        && recall == "recall"
    {
        client.recall(chat, id).await?;
        println!("recalled");
        return Ok(());
    }
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    let mut message = Outgoing {
        body: Body::Text(text.trim_end().to_owned()),
        quote: None,
    };
    let mut i = 0;
    while i < rest.len() {
        let arg = |n: usize| {
            rest.get(i + n)
                .ok_or_else(|| format!("{} needs {n}", rest[i]))
        };
        match rest[i].as_str() {
            "markdown" => {
                message.body = match message.body {
                    Body::Text(text) | Body::Markdown(text) => Body::Markdown(text),
                    media => media,
                };
                i += 1;
            }
            "picture" => {
                let bytes = std::fs::read(arg(1)?)?;
                let uploaded = client.upload(chat, Media::Picture(&bytes)).await?;
                println!("uploaded, for {}s", uploaded.ttl);
                message.body = Body::Media {
                    file_info: uploaded.file_info,
                    caption: Some(text.trim_end().to_owned()).filter(|text| !text.is_empty()),
                };
                i += 2;
            }
            "file" => {
                let path = std::path::Path::new(arg(1)?);
                let bytes = std::fs::read(path)?;
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .ok_or("no name")?;
                let uploaded = client
                    .upload(
                        chat,
                        Media::File {
                            name,
                            bytes: &bytes,
                        },
                    )
                    .await?;
                println!("uploaded, for {}s", uploaded.ttl);
                message.body = Body::Media {
                    file_info: uploaded.file_info,
                    caption: None,
                };
                i += 2;
            }
            "quote" => {
                message.quote = Some(arg(1)?.clone());
                i += 2;
            }
            other => return Err(format!("unknown option: {other}").into()),
        }
    }
    let sent = client.send(chat, &message).await?;
    println!("sent {sent:?}");
    Ok(())
}
