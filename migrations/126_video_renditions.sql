-- Provider renditions of videos, keyed by source content and preparation
-- parameters (vision envelope and window). Rendition bytes live in the
-- content-addressed blob store; fetched streams have no videos row.
CREATE TABLE video_renditions (
  source_sha256 text NOT NULL,
  params text NOT NULL,
  rendition_sha256 text NOT NULL,
  vision_tokens integer NOT NULL CHECK (vision_tokens > 0),
  source_seconds double precision NOT NULL,
  start_seconds double precision NOT NULL,
  span_seconds double precision NOT NULL,
  speed double precision NOT NULL CHECK (speed >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_sha256, params)
);
