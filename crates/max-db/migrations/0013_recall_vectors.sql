-- Vectors for context_search's search by meaning: one for each chat row
-- that says something, and one for each active summary, with the model
-- that made it, as caption_embeddings has them for stickers. A vector
-- keeps its conversation too, since a search looks at one conversation's.
-- The recall vector worker is their only writer; see "召回".
--
-- Half precision, unlike the stickers': for some 225,000 rows, the table
-- and its HNSW index take 1.2 GB rather than 3, and the same come out
-- nearest: of 50 searches among 20,000 random vectors, each found the
-- same ten in half precision, 49 of them in the same order. A search in
-- a big conversation goes by the HNSW index; in a small one, through its
-- conversation's rows.

-- What of a row's text is embedded: without the handles that carry no
-- words, a quote's, a mention's, a picture's that has no description.
create function recall_text(text text) returns text
    language sql immutable parallel safe
    return btrim(regexp_replace(text, '\[[a-z]+(#[0-9]+)?\]', ' ', 'g'));

create table message_embeddings (
    message_id bigint primary key references messages,
    conversation_id bigint not null references conversations,
    model text not null,
    embedding halfvec(1024) not null,
    created_at timestamptz not null
);
create index on message_embeddings using hnsw (embedding halfvec_cosine_ops);
create index on message_embeddings (conversation_id);

create table summary_embeddings (
    summary_id bigint primary key references summaries,
    conversation_id bigint not null references conversations,
    model text not null,
    embedding halfvec(1024) not null,
    created_at timestamptz not null
);
create index on summary_embeddings using hnsw (embedding halfvec_cosine_ops);
create index on summary_embeddings (conversation_id);
