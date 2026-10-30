-- How long each model call took, in milliseconds, where max measured it:
-- until the model's first output, until the end of its answer, and the
-- longest wait for anything to arrive, which the stream's idle timeout
-- cuts. A job's calls go through pi and aren't measured.
alter table llm_usage
    add column first_ms integer,
    add column took_ms integer,
    add column quiet_ms integer;
