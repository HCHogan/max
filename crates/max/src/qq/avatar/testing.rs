//! Made-up avatars, and a server for them in place of QQ's.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::Arc;

use axum::Router;
use axum::extract::State;
use axum::http::{StatusCode, Uri};
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use tokio::net::TcpListener;

use super::Avatars;
use crate::scope::Scope;

/// A JPEG `side` pixels square; `seed` picks one of three gradients, each
/// far from the others.
pub fn face(seed: u8, side: u32) -> Vec<u8> {
    let image = RgbImage::from_fn(side, side, |x, y| {
        let t = match seed % 3 {
            0 => x,
            1 => y,
            _ => side - 1 - x,
        };
        let v = u8::try_from(t * 255 / (side - 1)).unwrap();
        Rgb([v, v / 2, 255 - v])
    });
    let mut bytes = Vec::new();
    DynamicImage::ImageRgb8(image)
        .write_to(&mut Cursor::new(&mut bytes), ImageFormat::Jpeg)
        .unwrap();
    bytes
}

/// What the server has: an account's avatar at `/openid/<openid>`, a
/// number's at `/number/<number>`.
pub type Faces = HashMap<String, Vec<u8>>;

/// Serves `faces` until `scope` closes; Avatars that ask it.
pub async fn serve(faces: Faces, scope: &mut Scope) -> Avatars {
    async fn get(State(faces): State<Arc<Faces>>, uri: Uri) -> (StatusCode, Vec<u8>) {
        match faces.get(uri.path()) {
            Some(bytes) => (StatusCode::OK, bytes.clone()),
            None => (StatusCode::NOT_FOUND, Vec::new()),
        }
    }
    let app = Router::new().fallback(get).with_state(Arc::new(faces));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    scope.spawn(move |stop| async move {
        let server = axum::serve(listener, app).with_graceful_shutdown(stop.cancelled_owned());
        server.await.unwrap();
    });
    Avatars::new(
        format!("http://{address}/openid/{{openid}}"),
        format!("http://{address}/number/{{number}}"),
    )
    .unwrap()
}
