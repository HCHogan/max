use std::time::Duration;

use super::testing::{Faces, face, serve};
use super::*;
use crate::scope::Scope;

#[test]
fn one_picture_at_two_sizes_is_alike() {
    assert!(alike(&face(0, 640), &face(0, 100)).unwrap());
    assert!(!alike(&face(0, 640), &face(1, 640)).unwrap());
    assert!(!alike(&face(0, 640), &face(2, 100)).unwrap());
    assert!(alike(&face(0, 640), b"not a picture").is_err());
}

#[tokio::test]
async fn an_account_shows_its_numbers_avatar() {
    let mut scope = Scope::new();
    let faces = Faces::from([
        ("/openid/HONG".to_owned(), face(0, 640)),
        ("/number/20001".to_owned(), face(0, 100)),
        ("/number/20002".to_owned(), face(1, 100)),
    ]);
    let avatars = serve(faces, &mut scope).await;
    assert!(avatars.same("HONG", "20001").await.unwrap());
    assert!(!avatars.same("HONG", "20002").await.unwrap());
    assert!(
        avatars.same("HONG", "20003").await.is_err(),
        "no avatar there"
    );
    scope.close(Duration::from_secs(5)).await;
}
