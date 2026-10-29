-- Vectors for search by meaning, from the configured embedding model; see
-- "发图". Each kind of text embedded gets a table of this shape. A vector
-- keeps the model that made it: after a change of model the embedding
-- worker does them all again, and a search compares one model's vectors
-- only. 1024 dimensions are bge-m3's.
--
-- pgvector isn't a trusted extension: only a superuser may create it. On a
-- server the NixOS module does, before max starts, and this does nothing.
create extension if not exists vector;

-- A sticker's caption, for find_stickers: one per file, the embedding
-- worker's.
create table caption_embeddings (
    sha256 text primary key references media_captions,
    model text not null,
    embedding vector(1024) not null,
    created_at timestamptz not null
);
