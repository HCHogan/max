-- What a picture or sticker shows, in words: the caption worker's, written
-- once per file; see "媒体". The rows it describes show it to the model
-- when their node came without one.
create table media_captions (
    sha256 text primary key references media,
    -- Which prompt wrote it: a sticker's says what it's for.
    kind text not null check (kind in ('image', 'sticker')),
    -- Empty when the model failed twice; it isn't tried again.
    text text not null,
    -- A sticker that isn't one to send (a photo, a screenshot of a chat):
    -- shown as usual, but kept out of the sticker library.
    skip boolean not null default false,
    -- Which model wrote it; none for those imported from the Haskell
    -- version.
    model text,
    created_at timestamptz not null
);
