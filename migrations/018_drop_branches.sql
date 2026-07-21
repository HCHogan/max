-- Session branches (!branch / !switch) are removed: nobody used them
-- and !clear/!unclear covers the "start fresh but recoverable" case.
-- Collapse sessions to one row per group: keep the branch the active
-- pointer names; for a group without a pointer keep the most recently
-- updated row.  Then drop the branch column and the pointer table.

DELETE FROM sessions s
 USING session_active_branch a
 WHERE a.group_id = s.group_id
   AND s.branch <> a.branch;

DELETE FROM sessions
 WHERE ctid NOT IN (
     SELECT DISTINCT ON (group_id) ctid
       FROM sessions
      ORDER BY group_id, updated_at DESC);

ALTER TABLE sessions DROP CONSTRAINT sessions_pkey;
ALTER TABLE sessions DROP COLUMN branch;
ALTER TABLE sessions ADD PRIMARY KEY (group_id);

DROP TABLE session_active_branch;
