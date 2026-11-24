//! The sticker library, which `find_stickers` searches: every sticker seen
//! in any conversation, one per file, by the keywords in its caption. See
//! "Sending images".

use max_core::ids::MessageId;
use sqlx::PgConnection;

/// A sticker in the library: the last row that has it as a sticker, which
/// of the row's media it is, and its caption.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sticker {
    /// The row.
    pub message: MessageId,
    /// Which of the row's media it is.
    pub ordinal: u16,
    /// What the caption says.
    pub caption: String,
}

/// Up to `limit` stickers whose captions have any of `patterns` (LIKE
/// patterns for lowercased text, as `recall`'s), those with the most of
/// them first, then those seen last; one per file: captions that aren't
/// skipped or empty, of files some row in any conversation has as a
/// sticker.
pub async fn matching(
    conn: &mut PgConnection,
    patterns: &[String],
    limit: u8,
) -> sqlx::Result<Vec<Sticker>> {
    let rows = sqlx::query!(
        r#"
        select last.message_id as "message_id!", last.ordinal as "ordinal!", hit.text as "text!"
        from (
            select c.sha256, c.text, (
                select count(*) from unnest($1::text[]) as p(pattern)
                where lower(c.text) like p.pattern
            ) as terms
            from media_captions c
            where c.kind = 'sticker' and not c.skip and c.text <> ''
              and lower(c.text) like any($1)
        ) hit
        cross join lateral (
            select mm.message_id, mm.ordinal
            from message_media mm join messages m on m.id = mm.message_id
            where mm.sha256 = hit.sha256
              and (jsonb_path_query_array(m.nodes, '$[*] ? (@.type == "media").meta.kind')
                   ->> mm.ordinal::int) = 'sticker'
            order by mm.message_id desc
            limit 1
        ) last
        order by hit.terms desc, last.message_id desc
        limit $2
        "#,
        patterns,
        i64::from(limit)
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            Some(Sticker {
                message: MessageId::new(row.message_id),
                ordinal: u16::try_from(row.ordinal).ok()?,
                caption: row.text,
            })
        })
        .collect())
}
