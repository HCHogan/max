-- Recall: context_search looks for its terms in the rows' rendered text and
-- in the pictures' captions, as substrings of the lowercased text; see
-- "召回". Trigrams find a term of three characters or more without reading
-- the whole conversation; a shorter one has none, and is looked for row by
-- row. A database whose ctype is C, as the dev shell's, makes no trigrams of
-- Chinese at all: the search then reads every row, and finds the same.
create extension if not exists pg_trgm;

create index on messages using gin (lower(text) gin_trgm_ops);
create index on media_captions using gin (lower(text) gin_trgm_ops);
