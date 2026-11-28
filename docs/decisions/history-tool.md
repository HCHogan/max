# Recall is one tool, and search goes by keywords

Max recalls with one tool, `history`, which searches when given a query
and reads without one. It and `find_stickers` find text by its keywords
alone: there is no search by meaning, no embedding model and no pgvector.
With `tools: true`, `history` looks through the tool calls of the
conversation's turns instead of its chat: those a query matches, or the
latest. The design is in
[Recall](../design/context.md#recall) and
[Sending images](../design/media.md#sending-images).

## Context

- The context holds only the raw tail and the memory file; everything
  older is found by asking for it.
- A request like "what Xiaoming said the day before yesterday" applies
  the same filters, who and when, whether or not it has a query.
- Tool output lives only in its turn's transcript: the next turn is
  projected afresh from the ledger, and sees what Max said, not what its
  tools returned. Without a way to it, Max can't look up what a search, a
  page or a command gave it a few turns before, or how it had done
  something, short of doing it again.
- The runs hold about 16,500 tool calls after four weeks: 60 MB of
  results and 5.6 MB of arguments, against some 320,000 chat rows.

## Decision

- **One tool, `history`**: with a query it searches, without it reads.
- **Keywords only**, ranked by the share of them a row has and then by
  time.
- **`find_stickers` searches captions by keywords**, as `history` does,
  ranked by how many a caption has and then by when the sticker was last
  seen. Its guide asks for a few short words that say the same thing in
  different ways.
- **Stickers are searched by `history` too**: everything can always be
  searched, though a sticker's caption describes what it is and when to
  use it.
- **`/clear --all` doesn't limit it**: the watermark governs only what
  the context shows.
- **`lower(text) like`**, not `ilike`, on a trigram index.
- **Tool calls behind a switch, off by default.** A search goes through
  the chat unless it asks for tool calls; one search looks at one or the
  other.
- **Without a query the switch gives the latest calls**, as a read
  without a query gives the latest messages: a fifth of the times Max
  set the switch it gave no query, to see what it had just done.
- **A table of text for them**, `tool_calls`: per call, the tool, its
  arguments a line `key: value` each, and the text of its result, under a
  trigram index as messages' text has. It is derived in the database, by
  a SQL function from the run: the outcome's insert writes the calls in
  the same statement.
- **A call is read by `t#N.n`**, the n-th call of turn t#N, whole and in
  pages.
- **Not reasoning**, which stays its turn's own, and not background
  agents' calls, which are in their harness's sessions in the VM.

## Why

One tool:

- Two tools, one to search and one to read, mean first choosing a tool
  and assembling its arguments, though both apply the same filters and
  differ only in whether there is a query.

Keywords, without vectors. Measured over four weeks in which both
searches also had vectors from bge-m3, an embedding model on another
machine:

- **Meaning is mostly noise.** Of `history`'s 880 searches and 11,774
  results, keyword hits were 68%, and the model went on to use 11.5% of
  them: it read around the row, quoted it or answered it. Rows found by
  meaning alone, at least 0.5 similar, were 32%, and it used 1.5% of
  those. 0.5 is close to where bge-m3 puts unrelated sentences.
- **The model searches again.** Only 20 searches found nothing by keyword
  and something by meaning, and 3 of them led anywhere. What meaning
  found that keywords missed were words written another way (自由～的～光～
  for 自由的光, 哦鲸鲸 for 欧鲸鲸), which shorter or other keywords find. A
  miss costs one more call with other words, which the guide asks for:
  short Chinese keywords of two or three characters.
- **Captions are written to be found.** The caption model says what a
  sticker shows, the feeling and when it fits, and copies the words
  written on it. Of 113 `find_stickers` calls by meaning, 35 were
  followed by a sticker sent, and every one whose description could be
  read had one of the query's words in its caption.
- **Less to keep running:** 1.35 GB of vectors and their HNSW index, a
  worker for each kind of text, a model on another machine over a link
  that drops packets in the evenings, up to 5 seconds' wait on every
  search, and an extension only a superuser may create.

Tool calls, when asked:

- **The chat stays the default.** Tool output is bulky and noisy, web
  pages, command output and JSON, and much of it says how things stood
  then: a price, a service's state, a file. Mixed into every search it
  would crowd out what people said, and old output would be taken for
  news.
- **A search a model asks for.** "What did that page say" and "how did I
  do it last time" are questions the model knows it is asking; a switch
  costs it one argument.
- **A table, not the runs.** The trigram index finds a call in tens of
  milliseconds however many turns there are, and the runs can lose their
  bulk later (their base context and opaque fields) without losing it.
- **One extraction.** What a call's text is is written once, in SQL, and
  written with the outcome it comes from: there is never an outcome
  without its calls.

## Measurements

- `lower(text) like` against `ilike`: 50 ms against 178 ms.
- Search without an index, on the largest conversation, 62,000 rows:
  about 85 ms for 1 term, 97 ms for 2, 145 ms for 8.
- With the trigram index, on a database of 290,000 rows: a 3-character
  term 19 ms, a 4-character term 2 ms, two 3-character terms 13 ms. For a
  2-character term the custom plan scans row by row in 182 ms, while the
  generic plan reads the whole index in 496 ms, hence
  `force_custom_plan`. The index takes 88 MB there.
- Searching the runs' JSON directly for tool calls: 850 ms in the busiest
  conversation, growing with every turn.

## Cost

- **Short Chinese terms have no trigrams** and are compared row by row
  within the conversation, so searches are capped at 4 at a time across
  all groups.
- **What only meaning finds is lost:** words written differently, close
  synonyms, a description of a sticker in other words. The model finds
  them only if it thinks of the words.
- **The ranking is coarse.** Of the stickers with as many of the
  keywords, the ones seen last come first, not the ones that fit best;
  the model reads the descriptions and picks.
- **The run's JSON is read in SQL.** `tool_calls_of` knows how an item is
  serialized; a change to it needs a migration that replaces the
  function.
- **About 65 MB of tool calls' text and its index**, growing with the
  turns.
- **Whatever went into a call can be found**: an account's password Max
  typed for someone, a token a command printed. Only from the same
  conversation, which is the unit of permission anyway.
- **A turn lost in a crash has no calls**, as it has no run.
- **Output is as it was shown**: a result cut to 16 KiB is cut here too;
  the whole is in the VM's `/work/.max/out/` while Max keeps it.

## Alternatives

- **Search by meaning beside the keywords**, on vectors of every row: see
  Why.
- **A higher threshold for meaning**: fewer noisy rows, but the same
  model, workers and extension for the 3 searches in 880 that it helped.
- **Vectors for stickers only**: the sticker library is small, about
  3,000 captions, but the vectors would need the embedding model and
  pgvector all the same.
- **Tool output in every search**: no argument to learn, but every search
  wades through it.
- **A tool of its own for a turn** (`turn_read(t#N)`, reading a whole
  turn): reading without finding, and a second recall tool where one
  applies the same filters.
- **Searching the runs' JSON**: nothing to write, but a scan of every run
  in the conversation for each search.
- **Writing the calls' rows from max** as the turn ends: the same text
  made in Rust for new turns and in SQL for the old, two versions to keep
  alike.
