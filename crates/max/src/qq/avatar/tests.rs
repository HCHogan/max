use std::time::Duration;

use super::testing::{Faces, face, serve};
use super::*;
use crate::scope::Scope;

#[test]
fn one_picture_at_two_sizes_is_alike() {
    let print = |seed, side| print(&face(seed, side)).unwrap();
    assert_eq!(print(0, 640).len(), 256);
    assert!(alike(&print(0, 640), &print(0, 100)));
    assert!(!alike(&print(0, 640), &print(1, 640)));
    assert!(!alike(&print(0, 640), &print(2, 100)));
    assert!(!alike(&print(0, 640), &[0; 4]));
    assert!(super::print(b"not a picture").is_err());
}

#[tokio::test]
async fn accounts_and_numbers_show_their_avatars() {
    let mut scope = Scope::new();
    let faces = Faces::from([
        ("/openid/HONG".to_owned(), face(0, 640)),
        ("/openid/0".to_owned(), face(2, 640)),
        ("/number/20001".to_owned(), face(0, 100)),
        ("/number/20002".to_owned(), face(1, 100)),
    ]);
    let avatars = serve(faces, &mut scope).await;
    let hong = avatars.of_account("HONG").await.unwrap();
    assert!(alike(&hong, &avatars.of_number("20001").await.unwrap()));
    assert!(!alike(&hong, &avatars.of_number("20002").await.unwrap()));
    assert!(!alike(&hong, &avatars.default().await.unwrap()));
    assert!(avatars.of_number("20003").await.is_err(), "no avatar there");
    scope.close(Duration::from_secs(5)).await;
}
