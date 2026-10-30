-- Where a conversation's raw tail starts: after this row. A projection
-- moves it on when the tail passes its high watermark. It was where the
-- newest summary ended; with no summaries it is kept on its own, and with
-- none yet the tail is counted from the first row.

alter table conversations add column tail_after bigint;
