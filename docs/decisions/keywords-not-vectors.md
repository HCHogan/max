# Search goes by keywords, without vectors

`history` and `find_stickers` find text by its keywords alone. There is no
search by meaning, no embedding model and no pgvector. The design is in
[Recall](../design/context.md#recall) and
[Sending images](../design/media.md#sending-images).

## Context

Two searches had vectors from bge-m3, an embedding model on another
machine:

- `history` searched by keyword and, at the same time, by meaning: the
  query became a vector, every chat row had one, and a row at least 0.5
  similar became a result beside the keyword hits.
- `find_stickers` searched only by meaning, over a vector of each sticker's
  caption.

The turn records show what both did over the first four weeks in
production:

- **`history`:** 880 searches, 11,774 results. Keyword hits were 68% of the
  results, and the model went on to use 11.5% of them: it read around the
  row, quoted it or answered it. Rows found by meaning alone were 32%, and
  it used 1.5% of those, 55 in all.
- **Meaning alone:** only 20 searches found nothing by keyword and
  something by meaning, and 3 of them led anywhere. The rows it found that
  keywords missed were words written another way (自由～的～光～ for 自由的光,
  哦鲸鲸 for 欧鲸鲸, 三遍 for 两遍), which shorter or other keywords find.
- **`find_stickers`:** 113 calls, 35 of them followed by a sticker sent. It
  was the only way Max found stickers. The model's queries were long
  descriptions, and every sticker sent whose description could be read had
  one of the query's words in its caption.

## Decision

- **`history` searches by keywords only**, ranked by the share of them a
  row has and then by time.
- **`find_stickers` searches captions by keywords**, as `history` does,
  ranked by how many a caption has and then by when the sticker was last
  seen. Its guide asks for a few short words that say the same thing in
  different ways.
- **pgvector goes completely.** Without it, vectors would be kept only in
  case they were wanted again. The embedding client and its two workers,
  the vector tables, `[embedding]` and the extension are gone, along with
  the two migrations that made them (0010 and 0013), so that a new
  database never needs the extension.

## Why

- **Meaning was mostly noise.** It took a third of the result slots and
  the tokens they cost, and was used an eighth as often as a keyword hit.
  0.5 is close to where bge-m3 puts unrelated sentences.
- **The model searches again.** A miss costs one more call with other
  words, which the guide already asks for: short Chinese keywords of two
  or three characters.
- **Captions are written to be found.** The caption model says what a
  sticker shows, the feeling and when it fits, and copies the words
  written on it. Keywords such as 无语, 这么强 and 嫌弃 find the stickers that
  were sent.
- **Less to keep running:** 1.35 GB of vectors and their HNSW index, a
  worker for each kind of text, a model on another machine over a link
  that drops packets in the evenings, up to 5 seconds' wait on every
  search, and an extension only a superuser may create.

## Cost

- **What only meaning found is lost:** words written differently, close
  synonyms, a description of a sticker in other words. The model finds them
  only if it thinks of the words.
- **The ranking is coarse.** Of the stickers with as many of the keywords,
  the ones seen last come first, not the ones that fit best; the model
  reads the descriptions and picks.
- **Two applied migrations were removed.** sqlx refuses to start when a
  database has applied a migration the code no longer has, so a database
  that applied 0010 and 0013 is fixed once by hand: the vector tables, the
  `recall_text` function and the extension dropped, and the two rows taken
  out of `_sqlx_migrations`. The usual rule is that applied migrations are
  never changed; here keeping them would have kept pgvector.

## Alternatives

- **A higher threshold for meaning in `history`**: fewer noisy rows, but the
  same model, workers and extension for the 3 searches in 880 that it
  helped.
- **Vectors for stickers only**: the sticker library is small, about 3,000
  captions, but the vectors would need the embedding model and pgvector
  all the same.
- **A new migration that drops the tables, keeping 0010 and 0013**: no
  database to fix by hand, but every new database would still need
  pgvector to replay them.
