-- Retain legacy text and evidence as history; new captures write one summary.
ALTER TABLE conversation_compartments ADD COLUMN summary text;
UPDATE conversation_compartments
SET summary = (
  SELECT string_agg(text, E'\n' ORDER BY first_position)
  FROM (
    SELECT text, min(position) AS first_position
    FROM unnest(ARRAY[summary_p1, summary_p2, summary_p3]) WITH ORDINALITY AS old(text, position)
    GROUP BY text
  ) AS distinct_text
);
ALTER TABLE conversation_compartments
  ALTER COLUMN summary SET NOT NULL,
  ADD CONSTRAINT conversation_compartments_summary_check CHECK (summary <> ''),
  ALTER COLUMN summary_p1 DROP NOT NULL,
  ALTER COLUMN summary_p2 DROP NOT NULL,
  ALTER COLUMN summary_p3 DROP NOT NULL;

-- Old vectors remain valid only when their source text is unchanged.
UPDATE conversation_compartments
SET embedding=NULL, embedding_model=NULL, embedding_dimensions=NULL,
    embedding_content_hash=NULL, embedding_updated_at=NULL
WHERE summary IS DISTINCT FROM summary_p1;

ALTER TABLE compartment_evidence DROP CONSTRAINT compartment_evidence_summary_tier_check;
ALTER TABLE compartment_evidence ADD CONSTRAINT compartment_evidence_summary_tier_check
  CHECK (summary_tier IN ('p1','p2','p3','summary'));
INSERT INTO compartment_evidence(compartment_id,summary_tier,source_canonical_message_id,source_principal_id)
SELECT DISTINCT evidence.compartment_id,'summary',message.canonical_message_id,message.author_principal_id
FROM compartment_evidence evidence
JOIN messages message ON message.canonical_message_id=evidence.source_canonical_message_id;
