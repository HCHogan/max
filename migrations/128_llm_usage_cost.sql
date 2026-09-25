-- Estimated cost of each completion under its profile's configured prices.
-- Calls on unpriced profiles, and every row before this migration, carry none.
ALTER TABLE llm_usage
  ADD COLUMN cost double precision CHECK (cost >= 0),
  ADD COLUMN cost_currency text,
  ADD CONSTRAINT llm_usage_cost_currency CHECK ((cost IS NULL) = (cost_currency IS NULL));
