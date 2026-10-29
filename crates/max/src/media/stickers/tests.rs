use max_db::captions::{self, Caption, Kind};
use max_db::media::{self, Blob};
use sqlx::PgPool;

use super::*;
use crate::embedding::testing::{serve, vector};
use crate::scope::Scope;

const FIRST: Attempt = Attempt {
    number: 1,
    last: false,
};

/// A file by the letter its SHA-256 repeats, with a caption.
async fn captioned(pool: &PgPool, letter: char, kind: Kind, text: &str, skip: bool) -> String {
    let sha256 = letter.to_string().repeat(64);
    let blob = Blob {
        sha256: sha256.clone(),
        mime: None,
        size: 1,
        width: None,
        height: None,
        model_sha256: None,
    };
    let mut conn = pool.acquire().await.unwrap();
    media::remember(&mut conn, &blob, Utc::now()).await.unwrap();
    let caption = Caption {
        sha256: &sha256,
        kind,
        text,
        skip,
        model: None,
        at: Utc::now(),
    };
    captions::write(&mut conn, &caption).await.unwrap();
    sha256
}

async fn stored(pool: &PgPool) -> Vec<(String, String, Vec<f32>)> {
    sqlx::query_as("select sha256, model, embedding::real[] from caption_embeddings order by 1")
        .fetch_all(pool)
        .await
        .unwrap()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn each_sticker_caption_gets_a_vector(pool: PgPool) {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let worker = Stickers {
        pool: pool.clone(),
        embedder,
    };
    let cat = captioned(&pool, 'a', Kind::Sticker, "翻白眼的猫", false).await;
    captioned(&pool, 'b', Kind::Sticker, "自拍", true).await;
    captioned(&pool, 'c', Kind::Image, "截图", false).await;
    let down = captioned(&pool, 'd', Kind::Sticker, "挂了的狗", false).await;
    assert_eq!(worker.scan().await.unwrap(), [down.clone(), cat.clone()]);

    worker.run(&cat, FIRST).await.unwrap();
    let expected = (cat.clone(), "test-m3".to_owned(), vector("翻白眼的猫"));
    assert_eq!(stored(&pool).await, std::slice::from_ref(&expected));
    assert_eq!(asked.lock().unwrap()[0].1["input"][0], "翻白眼的猫");
    // Done: the service isn't asked again.
    worker.run(&cat, FIRST).await.unwrap();
    assert_eq!(asked.lock().unwrap().len(), 1);
    // Nor for what isn't a sticker's caption to embed.
    worker.run(&"b".repeat(64), FIRST).await.unwrap();
    worker.run(&"c".repeat(64), FIRST).await.unwrap();
    assert_eq!(asked.lock().unwrap().len(), 1);

    // A failure writes nothing; the scan still has it.
    assert!(worker.run(&down, FIRST).await.is_err());
    assert_eq!(stored(&pool).await, [expected]);
    assert_eq!(worker.scan().await.unwrap(), [down]);
    scope.close(Duration::ZERO).await;
}
