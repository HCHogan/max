ALTER TABLE skills ADD COLUMN evidence jsonb NOT NULL DEFAULT '"trusted"'::jsonb;

-- Earlier publications did not preserve sufficient execution evidence.
UPDATE skills SET evidence = '"requires-validation"'::jsonb
WHERE EXISTS (SELECT 1 FROM skill_publications p WHERE p.skill_id=skills.id);
