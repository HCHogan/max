-- Schema baseline: the complete max schema as of the ADR 003 cutover
-- (squash of former migrations 001-064, taken from the production
-- schema on 2026-08-04, PostgreSQL 17.10).
--
-- There is exactly one production instance.  Its schema_migrations
-- bookkeeping is folded onto this file by the squash reconciliation in
-- Max.DB.Migrations: a database that already records the final
-- pre-squash migration adopts this baseline without executing it.
-- A fresh database executes it normally.
--
-- PostgreSQL database dump
--


-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', 'public', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: conversation_source_hash(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.conversation_source_hash(source_conversation_id bigint, source_start_seq bigint, source_end_seq bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT encode(
        digest(
            convert_to(
                COALESCE(
                    jsonb_agg(
                        jsonb_build_array(
                            m.ingest_seq,
                            m.canonical_message_id,
                            m.message_id,
                            m.author_principal_id,
                            to_char(
                                m.occurred_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                            ),
                            m.canonical_content,
                            m.reply_to_canonical_message_id,
                            m.message_origin,
                            m.event_kind,
                            m.kind,
                            COALESCE((
                                SELECT jsonb_agg(
                                    jsonb_build_array(
                                        relation.relation_kind,
                                        relation.target_canonical_message_id,
                                        relation.target_native_event_id,
                                        relation.reaction_key,
                                        relation.reaction_added,
                                        relation.relation_position
                                    ) ORDER BY relation.relation_kind,
                                               relation.target_canonical_message_id,
                                               relation.target_native_event_id,
                                               relation.reaction_key,
                                               relation.reaction_added,
                                               relation.relation_position
                                )
                                FROM message_relations relation
                                WHERE relation.canonical_message_id = m.canonical_message_id
                            ), '[]'::jsonb)
                        ) ORDER BY m.ingest_seq
                    ),
                    '[]'::jsonb
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    FROM messages AS m
    JOIN conversations conversation USING (conversation_id)
    WHERE conversation.legacy_group_id = source_conversation_id
      AND m.ingest_seq BETWEEN source_start_seq AND source_end_seq;
$$;


--
-- Name: invalidate_embedding_on_source_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invalidate_embedding_on_source_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Dynamic JSON field access lets the same trigger function serve tables
    -- whose source columns have different names.  Direct OLD.column access
    -- would be planned against every trigger's row type, even in a branch for
    -- a different TG_ARGV value.
    IF to_jsonb(OLD) -> TG_ARGV[0] IS DISTINCT FROM
       to_jsonb(NEW) -> TG_ARGV[0] THEN
        NEW.embedding := NULL;
        NEW.embedding_model := NULL;
        NEW.embedding_dimensions := NULL;
        NEW.embedding_content_hash := NULL;
        NEW.embedding_updated_at := NULL;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: max_bump_admin_timeline(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_bump_admin_timeline(target_conversation bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO admin_timeline_revisions (conversation_id, revision, updated_at)
  VALUES (target_conversation, 1, now())
  ON CONFLICT (conversation_id) DO UPDATE
  SET revision = admin_timeline_revisions.revision + 1,
      updated_at = now();
  PERFORM pg_notify('max_timeline_work', target_conversation::text);
END
$$;


--
-- Name: max_notify_all_timelines(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_all_timelines() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO admin_timeline_revisions (conversation_id, revision, updated_at)
  SELECT conversation_id, 1, now() FROM conversations
  ON CONFLICT (conversation_id) DO UPDATE
  SET revision = admin_timeline_revisions.revision + 1,
      updated_at = now();
  PERFORM pg_notify('max_timeline_work', '*');
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: max_notify_delivery_work(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_delivery_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status IN ('pending', 'failed') THEN
    PERFORM pg_notify('max_delivery_work', NEW.delivery_id::text);
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: max_notify_dispatch_work(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_dispatch_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status IN ('pending', 'failed') THEN
    PERFORM pg_notify('max_dispatch_work', NEW.canonical_message_id::text);
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: max_notify_timeline_delivery_work(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_timeline_delivery_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  target_conversation bigint;
BEGIN
  SELECT message.conversation_id INTO target_conversation
  FROM messages message
  WHERE message.canonical_message_id = NEW.canonical_message_id;

  IF target_conversation IS NOT NULL THEN
    PERFORM max_bump_admin_timeline(target_conversation);
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: max_notify_timeline_dispatch_work(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_timeline_dispatch_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  target_conversation bigint;
BEGIN
  SELECT message.conversation_id INTO target_conversation
  FROM messages message
  WHERE message.canonical_message_id = NEW.canonical_message_id;

  IF target_conversation IS NOT NULL THEN
    PERFORM max_bump_admin_timeline(target_conversation);
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: max_notify_timeline_work(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max_notify_timeline_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM max_bump_admin_timeline(NEW.conversation_id);
  RETURN NEW;
END
$$;


--
-- Name: messages_assign_canonical_sequence(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.messages_assign_canonical_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.conversation_id IS NULL
     OR NEW.author_principal_id IS NULL
     OR NEW.origin_endpoint_id IS NULL
     OR NEW.source_native_event_id IS NULL
     OR NEW.occurred_at IS NULL THEN
    RAISE EXCEPTION 'legacy message INSERT is disabled; canonical provenance is required';
  END IF;
  NEW.conversation_seq := COALESCE(NEW.conversation_seq, NEW.ingest_seq);
  RETURN NEW;
END;
$$;


--
-- Name: reject_context_materialization_version_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_context_materialization_version_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'context_materialization_versions is append-only'
        USING ERRCODE = '55000';
END;
$$;


--
-- Name: reject_episode_evidence_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_episode_evidence_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;


--
-- Name: reject_memory_ledger_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_memory_ledger_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admin_timeline_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_timeline_revisions (
    conversation_id bigint NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_timeline_revisions_revision_check CHECK ((revision >= 0))
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    message_id bigint NOT NULL,
    group_id bigint NOT NULL,
    user_id bigint NOT NULL,
    self_id bigint NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    segments jsonb NOT NULL,
    rendered_text text NOT NULL,
    raw_message text DEFAULT ''::text NOT NULL,
    sender_nickname text,
    sender_card text,
    reply_to_message_id bigint,
    is_synthetic boolean DEFAULT false NOT NULL,
    rendered_text_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, rendered_text)) STORED,
    embedding public.vector,
    kind text DEFAULT 'chat'::text NOT NULL,
    ingest_seq bigint NOT NULL,
    embedding_model text,
    embedding_dimensions integer,
    embedding_content_hash text,
    embedding_updated_at timestamp with time zone,
    canonical_message_id bigint NOT NULL,
    canonical_content jsonb NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_seq bigint NOT NULL,
    author_principal_id bigint NOT NULL,
    origin_endpoint_id bigint NOT NULL,
    source_native_event_id text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    reply_to_canonical_message_id bigint,
    message_origin text NOT NULL,
    source_platform text NOT NULL,
    event_kind text DEFAULT 'message'::text NOT NULL,
    CONSTRAINT messages_canonical_content_v2_check CHECK (((jsonb_typeof(canonical_content) = 'object'::text) AND ((canonical_content ->> 'v'::text) = '2'::text) AND (jsonb_typeof((canonical_content -> 'nodes'::text)) = 'array'::text))),
    CONSTRAINT messages_embedding_metadata_consistent CHECK ((((embedding IS NULL) AND (embedding_model IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_content_hash IS NULL) AND (embedding_updated_at IS NULL)) OR ((embedding IS NOT NULL) AND (embedding_model IS NOT NULL) AND (embedding_dimensions IS NOT NULL) AND (embedding_dimensions > 0) AND (embedding_dimensions = public.vector_dims(embedding)) AND (embedding_content_hash IS NOT NULL) AND (embedding_content_hash ~ '^[0-9a-f]{64}$'::text) AND (embedding_updated_at IS NOT NULL)))),
    CONSTRAINT messages_event_kind_check CHECK ((event_kind = ANY (ARRAY['message'::text, 'edit'::text, 'reaction'::text, 'redaction'::text, 'membership'::text]))),
    CONSTRAINT messages_kind_check CHECK ((kind = ANY (ARRAY['chat'::text, 'command'::text, 'debug'::text]))),
    CONSTRAINT messages_message_origin_check CHECK ((message_origin = ANY (ARRAY['legacy'::text, 'inbound'::text, 'outbound'::text, 'internal'::text]))),
    CONSTRAINT messages_non_qq_segments_empty_check CHECK (((source_platform = 'qq'::text) OR (segments = '[]'::jsonb))),
    CONSTRAINT messages_source_platform_check CHECK ((source_platform <> ''::text))
);


--
-- Name: canonical_message_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.canonical_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: canonical_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.canonical_message_id_seq OWNED BY public.messages.canonical_message_id;


--
-- Name: compartment_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.compartment_evidence (
    compartment_id bigint NOT NULL,
    summary_tier text NOT NULL,
    source_message_id bigint NOT NULL,
    source_principal_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT compartment_evidence_summary_tier_check CHECK ((summary_tier = ANY (ARRAY['p1'::text, 'p2'::text, 'p3'::text])))
);


--
-- Name: context_materialization_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.context_materialization_versions (
    conversation_id bigint NOT NULL,
    revision bigint NOT NULL,
    end_ingest_seq bigint NOT NULL,
    policy_version text NOT NULL,
    source_fingerprint text NOT NULL,
    items jsonb NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT context_materialization_versions_end_ingest_seq_check CHECK ((end_ingest_seq > 0)),
    CONSTRAINT context_materialization_versions_items_check CHECK ((jsonb_typeof(items) = 'array'::text)),
    CONSTRAINT context_materialization_versions_revision_check CHECK ((revision > 0)),
    CONSTRAINT context_materialization_versions_source_fingerprint_check CHECK ((source_fingerprint ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: context_materializations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.context_materializations (
    conversation_id bigint NOT NULL,
    revision bigint NOT NULL,
    end_ingest_seq bigint NOT NULL,
    policy_version text NOT NULL,
    source_fingerprint text NOT NULL,
    items jsonb NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT context_materializations_end_ingest_seq_check CHECK ((end_ingest_seq > 0)),
    CONSTRAINT context_materializations_items_check CHECK ((jsonb_typeof(items) = 'array'::text)),
    CONSTRAINT context_materializations_policy_version_check CHECK ((policy_version <> ''::text)),
    CONSTRAINT context_materializations_reason_check CHECK ((reason = ANY (ARRAY['initial_materialization'::text, 'high_water'::text, 'projection_change'::text, 'manual_rebuild'::text]))),
    CONSTRAINT context_materializations_revision_check CHECK ((revision > 0)),
    CONSTRAINT context_materializations_source_fingerprint_check CHECK ((source_fingerprint ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: context_plan_traces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.context_plan_traces (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    trigger_message_id bigint NOT NULL,
    history_mode text NOT NULL,
    policy_version text NOT NULL,
    materialization_revision bigint,
    materialization_reason text,
    estimated_prompt_tokens integer NOT NULL,
    prompt_token_limit integer NOT NULL,
    max_input_tokens integer NOT NULL,
    reserved_output_tokens integer NOT NULL,
    attachment_reserve integer NOT NULL,
    tool_round_reserve integer NOT NULL,
    within_budget boolean NOT NULL,
    decisions jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT context_plan_traces_attachment_reserve_check CHECK ((attachment_reserve >= 0)),
    CONSTRAINT context_plan_traces_decisions_check CHECK ((jsonb_typeof(decisions) = 'array'::text)),
    CONSTRAINT context_plan_traces_estimated_prompt_tokens_check CHECK ((estimated_prompt_tokens >= 0)),
    CONSTRAINT context_plan_traces_history_mode_check CHECK ((history_mode = ANY (ARRAY['legacy'::text, 'tiered'::text, 'raw_emergency'::text]))),
    CONSTRAINT context_plan_traces_max_input_tokens_check CHECK ((max_input_tokens > 0)),
    CONSTRAINT context_plan_traces_policy_version_check CHECK ((policy_version <> ''::text)),
    CONSTRAINT context_plan_traces_prompt_token_limit_check CHECK ((prompt_token_limit > 0)),
    CONSTRAINT context_plan_traces_reserved_output_tokens_check CHECK ((reserved_output_tokens >= 0)),
    CONSTRAINT context_plan_traces_tool_round_reserve_check CHECK ((tool_round_reserve >= 0))
);


--
-- Name: context_plan_traces_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.context_plan_traces_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: context_plan_traces_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.context_plan_traces_id_seq OWNED BY public.context_plan_traces.id;


--
-- Name: conversation_compartments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_compartments (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    capture_run_id bigint NOT NULL,
    start_ingest_seq bigint NOT NULL,
    end_ingest_seq bigint NOT NULL,
    source_range int8range GENERATED ALWAYS AS (int8range(start_ingest_seq, end_ingest_seq, '[]'::text)) STORED,
    source_hash text NOT NULL,
    source_message_count integer NOT NULL,
    summary_p1 text NOT NULL,
    summary_p2 text NOT NULL,
    summary_p3 text NOT NULL,
    episode_kind text NOT NULL,
    importance double precision NOT NULL,
    confidence double precision NOT NULL,
    state text DEFAULT 'staged'::text NOT NULL,
    superseded_by bigint,
    historian_profile text NOT NULL,
    prompt_version text NOT NULL,
    schema_version integer NOT NULL,
    materialization_version bigint NOT NULL,
    speaker_stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    embedding public.vector,
    embedding_model text,
    embedding_dimensions integer,
    embedding_content_hash text,
    embedding_updated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    activated_at timestamp with time zone,
    expand_handle uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT conversation_compartments_check CHECK ((end_ingest_seq >= start_ingest_seq)),
    CONSTRAINT conversation_compartments_check1 CHECK ((((state = 'superseded'::text) AND (superseded_by IS NOT NULL) AND (superseded_by <> id)) OR ((state <> 'superseded'::text) AND (superseded_by IS NULL)))),
    CONSTRAINT conversation_compartments_check2 CHECK ((((embedding IS NULL) AND (embedding_model IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_content_hash IS NULL) AND (embedding_updated_at IS NULL)) OR ((embedding IS NOT NULL) AND (embedding_model IS NOT NULL) AND (embedding_dimensions = public.vector_dims(embedding)) AND (embedding_content_hash ~ '^[0-9a-f]{64}$'::text) AND (embedding_updated_at IS NOT NULL)))),
    CONSTRAINT conversation_compartments_confidence_check CHECK (((confidence >= (0)::double precision) AND (confidence <= (1)::double precision))),
    CONSTRAINT conversation_compartments_episode_kind_check CHECK ((episode_kind = ANY (ARRAY['max_interaction'::text, 'ambient'::text, 'mixed'::text, 'decision'::text, 'support'::text, 'social'::text]))),
    CONSTRAINT conversation_compartments_importance_check CHECK (((importance >= (0)::double precision) AND (importance <= (1)::double precision))),
    CONSTRAINT conversation_compartments_materialization_version_check CHECK ((materialization_version > 0)),
    CONSTRAINT conversation_compartments_schema_version_check CHECK ((schema_version > 0)),
    CONSTRAINT conversation_compartments_source_hash_check CHECK ((source_hash ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT conversation_compartments_source_message_count_check CHECK ((source_message_count > 0)),
    CONSTRAINT conversation_compartments_start_ingest_seq_check CHECK ((start_ingest_seq > 0)),
    CONSTRAINT conversation_compartments_state_check CHECK ((state = ANY (ARRAY['staged'::text, 'active'::text, 'superseded'::text]))),
    CONSTRAINT conversation_compartments_summary_p1_check CHECK ((summary_p1 <> ''::text)),
    CONSTRAINT conversation_compartments_summary_p2_check CHECK ((summary_p2 <> ''::text)),
    CONSTRAINT conversation_compartments_summary_p3_check CHECK ((summary_p3 <> ''::text))
);


--
-- Name: conversation_compartments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_compartments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_compartments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_compartments_id_seq OWNED BY public.conversation_compartments.id;


--
-- Name: conversation_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_cursors (
    conversation_id bigint NOT NULL,
    cursor_name text NOT NULL,
    ingest_seq bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conversation_cursors_ingest_seq_check CHECK ((ingest_seq >= 0))
);


--
-- Name: conversation_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_endpoints (
    endpoint_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    platform_account_id bigint NOT NULL,
    native_conversation_id text NOT NULL,
    endpoint_kind text NOT NULL,
    endpoint_mode text DEFAULT 'standalone'::text NOT NULL,
    display_name text,
    enabled boolean DEFAULT true NOT NULL,
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conversation_endpoints_endpoint_kind_check CHECK ((endpoint_kind = ANY (ARRAY['group'::text, 'direct'::text]))),
    CONSTRAINT conversation_endpoints_endpoint_mode_check CHECK ((endpoint_mode = ANY (ARRAY['standalone'::text, 'mirror'::text]))),
    CONSTRAINT conversation_endpoints_native_conversation_id_check CHECK ((native_conversation_id <> ''::text))
);


--
-- Name: conversation_endpoints_endpoint_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_endpoints_endpoint_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_endpoints_endpoint_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_endpoints_endpoint_id_seq OWNED BY public.conversation_endpoints.endpoint_id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    conversation_id bigint NOT NULL,
    conversation_kind text NOT NULL,
    title text,
    legacy_group_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conversations_conversation_kind_check CHECK ((conversation_kind = ANY (ARRAY['group'::text, 'direct'::text])))
);


--
-- Name: conversations_conversation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_conversation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_conversation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_conversation_id_seq OWNED BY public.conversations.conversation_id;


--
-- Name: episode_capture_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_capture_runs (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    expected_cursor_seq bigint NOT NULL,
    start_ingest_seq bigint NOT NULL,
    end_ingest_seq bigint NOT NULL,
    source_hash text NOT NULL,
    source_message_count integer NOT NULL,
    scheduling_reason text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    lease_owner text,
    lease_expires_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    last_error text,
    historian_profile text NOT NULL,
    prompt_version text NOT NULL,
    schema_version integer NOT NULL,
    idempotency_key text NOT NULL,
    raw_output text,
    parsed_output jsonb,
    validation_errors jsonb DEFAULT '[]'::jsonb NOT NULL,
    replaces_compartment_id bigint,
    published_compartment_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT episode_capture_runs_attempt_check CHECK ((attempt >= 0)),
    CONSTRAINT episode_capture_runs_check CHECK ((end_ingest_seq >= start_ingest_seq)),
    CONSTRAINT episode_capture_runs_check1 CHECK ((((status = ANY (ARRAY['leased'::text, 'generated'::text])) AND (lease_owner IS NOT NULL) AND (lease_expires_at IS NOT NULL)) OR (status <> ALL (ARRAY['leased'::text, 'generated'::text])))),
    CONSTRAINT episode_capture_runs_expected_cursor_seq_check CHECK ((expected_cursor_seq >= 0)),
    CONSTRAINT episode_capture_runs_historian_profile_check CHECK ((historian_profile <> ''::text)),
    CONSTRAINT episode_capture_runs_idempotency_key_check CHECK ((idempotency_key ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT episode_capture_runs_prompt_version_check CHECK ((prompt_version <> ''::text)),
    CONSTRAINT episode_capture_runs_scheduling_reason_check CHECK ((scheduling_reason = ANY (ARRAY['idle'::text, 'volume'::text, 'token_pressure'::text, 'backfill'::text, 'rebuild'::text]))),
    CONSTRAINT episode_capture_runs_schema_version_check CHECK ((schema_version > 0)),
    CONSTRAINT episode_capture_runs_source_hash_check CHECK ((source_hash ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT episode_capture_runs_source_message_count_check CHECK ((source_message_count > 0)),
    CONSTRAINT episode_capture_runs_start_ingest_seq_check CHECK ((start_ingest_seq > 0)),
    CONSTRAINT episode_capture_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'leased'::text, 'generated'::text, 'published'::text, 'failed'::text, 'abandoned'::text])))
);


--
-- Name: episode_capture_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.episode_capture_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: episode_capture_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.episode_capture_runs_id_seq OWNED BY public.episode_capture_runs.id;


--
-- Name: episode_memory_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_memory_proposals (
    capture_run_id bigint NOT NULL,
    proposal_index integer NOT NULL,
    proposal jsonb NOT NULL,
    evidence_message_ids bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    outcome text NOT NULL,
    outcome_reason text,
    memory_id bigint,
    memory_version bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT episode_memory_proposals_check CHECK ((((memory_id IS NULL) AND (memory_version IS NULL)) OR ((memory_id IS NOT NULL) AND (memory_version IS NOT NULL)))),
    CONSTRAINT episode_memory_proposals_outcome_check CHECK ((outcome = ANY (ARRAY['applied'::text, 'rejected_validation'::text, 'rejected_store'::text]))),
    CONSTRAINT episode_memory_proposals_proposal_index_check CHECK ((proposal_index >= 0))
);


--
-- Name: fetch_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fetch_jobs (
    id bigint NOT NULL,
    kind text NOT NULL,
    dedupe_key text NOT NULL,
    payload jsonb NOT NULL,
    enqueued_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    claimed_until timestamp with time zone,
    last_error text,
    parked_at timestamp with time zone
);


--
-- Name: fetch_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fetch_jobs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fetch_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: group_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_files (
    file_id text NOT NULL,
    group_id bigint NOT NULL,
    message_id bigint,
    sender_user_id bigint NOT NULL,
    file_name text NOT NULL,
    mime_type text,
    bytes_size bigint,
    sha256 text,
    local_path text,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    fetched_at timestamp with time zone
);


--
-- Name: images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.images (
    sha256 text NOT NULL,
    mime_type text NOT NULL,
    bytes_size bigint NOT NULL,
    local_path text NOT NULL,
    width integer,
    height integer,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    description text,
    caption_attempts integer DEFAULT 0 NOT NULL
);


--
-- Name: llm_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.llm_calls (
    id bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    group_id bigint,
    source text NOT NULL,
    profile text NOT NULL,
    model text NOT NULL,
    streamed boolean DEFAULT false NOT NULL,
    duration_ms integer NOT NULL,
    request jsonb NOT NULL,
    response jsonb,
    error text,
    prompt_tokens integer,
    completion_tokens integer,
    cached_prompt_tokens integer
);


--
-- Name: llm_calls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_calls_id_seq OWNED BY public.llm_calls.id;


--
-- Name: llm_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.llm_usage (
    id bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    group_id bigint,
    source text NOT NULL,
    profile text NOT NULL,
    prompt_tokens integer NOT NULL,
    completion_tokens integer NOT NULL,
    cached_prompt_tokens integer
);


--
-- Name: llm_usage_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.llm_usage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: llm_usage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.llm_usage_id_seq OWNED BY public.llm_usage.id;


--
-- Name: maintenance_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.maintenance_leases (
    domain text NOT NULL,
    owner text NOT NULL,
    fencing_token bigint NOT NULL,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    heartbeat_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT maintenance_leases_check CHECK ((expires_at > heartbeat_at)),
    CONSTRAINT maintenance_leases_domain_check CHECK ((domain <> ''::text)),
    CONSTRAINT maintenance_leases_fencing_token_check CHECK ((fencing_token > 0)),
    CONSTRAINT maintenance_leases_owner_check CHECK ((owner <> ''::text))
);


--
-- Name: memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memories (
    id bigint NOT NULL,
    scope text NOT NULL,
    scope_id bigint NOT NULL,
    content text NOT NULL,
    source_group_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    embedding public.vector,
    embedding_model text,
    embedding_dimensions integer,
    embedding_content_hash text,
    embedding_updated_at timestamp with time zone,
    version bigint DEFAULT 1 NOT NULL,
    lifecycle text DEFAULT 'active'::text NOT NULL,
    category text,
    superseded_by bigint,
    CONSTRAINT memories_category_check CHECK (((category IS NULL) OR (category = ANY (ARRAY['person_fact'::text, 'preference'::text, 'group_convention'::text, 'ongoing_project'::text, 'commitment'::text, 'decision'::text, 'running_joke'::text, 'relationship_context'::text])))),
    CONSTRAINT memories_embedding_metadata_consistent CHECK ((((embedding IS NULL) AND (embedding_model IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_content_hash IS NULL) AND (embedding_updated_at IS NULL)) OR ((embedding IS NOT NULL) AND (embedding_model IS NOT NULL) AND (embedding_dimensions IS NOT NULL) AND (embedding_dimensions > 0) AND (embedding_dimensions = public.vector_dims(embedding)) AND (embedding_content_hash IS NOT NULL) AND (embedding_content_hash ~ '^[0-9a-f]{64}$'::text) AND (embedding_updated_at IS NOT NULL)))),
    CONSTRAINT memories_lifecycle_check CHECK ((lifecycle = ANY (ARRAY['active'::text, 'permanent'::text, 'archived'::text, 'superseded'::text]))),
    CONSTRAINT memories_scope_check CHECK ((scope = ANY (ARRAY['group'::text, 'user'::text]))),
    CONSTRAINT memories_supersession_consistent CHECK ((((lifecycle = 'superseded'::text) AND (superseded_by IS NOT NULL) AND (superseded_by <> id)) OR ((lifecycle <> 'superseded'::text) AND (superseded_by IS NULL)))),
    CONSTRAINT memories_version_check CHECK ((version > 0))
);


--
-- Name: memories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memories_id_seq OWNED BY public.memories.id;


--
-- Name: memory_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_evidence (
    id bigint NOT NULL,
    memory_id bigint NOT NULL,
    memory_version bigint NOT NULL,
    evidence_kind text NOT NULL,
    source_conversation_id bigint,
    source_principal_id bigint,
    source_message_id bigint,
    source_start_ingest_seq bigint,
    source_end_ingest_seq bigint,
    source_episode_id bigint,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT memory_evidence_check CHECK ((((source_start_ingest_seq IS NULL) AND (source_end_ingest_seq IS NULL)) OR ((source_start_ingest_seq IS NOT NULL) AND (source_end_ingest_seq IS NOT NULL) AND (source_start_ingest_seq <= source_end_ingest_seq)))),
    CONSTRAINT memory_evidence_check1 CHECK (((evidence_kind = 'legacy'::text) OR ((evidence_kind = 'message'::text) AND (source_conversation_id IS NOT NULL) AND (source_message_id IS NOT NULL)) OR ((evidence_kind = 'range'::text) AND (source_conversation_id IS NOT NULL) AND (source_start_ingest_seq IS NOT NULL)) OR ((evidence_kind = 'episode'::text) AND (source_conversation_id IS NOT NULL) AND (source_episode_id IS NOT NULL)) OR ((evidence_kind = 'maintenance'::text) AND (source_conversation_id IS NOT NULL)) OR (evidence_kind = 'admin'::text))),
    CONSTRAINT memory_evidence_evidence_kind_check CHECK ((evidence_kind = ANY (ARRAY['legacy'::text, 'message'::text, 'range'::text, 'episode'::text, 'maintenance'::text, 'admin'::text])))
);


--
-- Name: memory_evidence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_evidence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_evidence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_evidence_id_seq OWNED BY public.memory_evidence.id;


--
-- Name: memory_mutations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_mutations (
    id bigint NOT NULL,
    memory_id bigint NOT NULL,
    from_version bigint,
    to_version bigint NOT NULL,
    operation text NOT NULL,
    actor_kind text NOT NULL,
    actor_principal_id bigint,
    conversation_id bigint,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT memory_mutations_actor_kind_check CHECK ((actor_kind <> ''::text)),
    CONSTRAINT memory_mutations_operation_check CHECK ((operation = ANY (ARRAY['create'::text, 'update'::text, 'archive'::text, 'make_permanent'::text, 'restore'::text, 'supersede'::text, 'backfill'::text]))),
    CONSTRAINT memory_mutations_to_version_check CHECK ((to_version > 0))
);


--
-- Name: memory_mutations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_mutations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_mutations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_mutations_id_seq OWNED BY public.memory_mutations.id;


--
-- Name: memory_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_versions (
    memory_id bigint NOT NULL,
    version bigint NOT NULL,
    content text NOT NULL,
    lifecycle text NOT NULL,
    category text,
    superseded_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT memory_versions_category_check CHECK (((category IS NULL) OR (category = ANY (ARRAY['person_fact'::text, 'preference'::text, 'group_convention'::text, 'ongoing_project'::text, 'commitment'::text, 'decision'::text, 'running_joke'::text, 'relationship_context'::text])))),
    CONSTRAINT memory_versions_lifecycle_check CHECK ((lifecycle = ANY (ARRAY['active'::text, 'permanent'::text, 'archived'::text, 'superseded'::text]))),
    CONSTRAINT memory_versions_version_check CHECK ((version > 0))
);


--
-- Name: message_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_deliveries (
    delivery_id bigint NOT NULL,
    canonical_message_id bigint NOT NULL,
    endpoint_id bigint NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    native_event_id text,
    idempotency_key text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    lease_owner text,
    lease_expires_at timestamp with time zone,
    last_error text,
    last_attempt_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    lower_notes jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT message_deliveries_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT message_deliveries_lower_notes_array CHECK ((jsonb_typeof(lower_notes) = 'array'::text)),
    CONSTRAINT message_deliveries_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sending'::text, 'accepted_unconfirmed'::text, 'confirmed'::text, 'failed'::text, 'outcome_unknown'::text, 'suppressed'::text])))
);


--
-- Name: message_deliveries_delivery_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.message_deliveries_delivery_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_deliveries_delivery_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.message_deliveries_delivery_id_seq OWNED BY public.message_deliveries.delivery_id;


--
-- Name: message_dispatches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_dispatches (
    canonical_message_id bigint NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    lease_owner text,
    lease_expires_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    last_attempt_at timestamp with time zone,
    completed_at timestamp with time zone,
    CONSTRAINT message_dispatches_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT message_dispatches_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'claimed'::text, 'completed'::text, 'ignored'::text, 'failed'::text])))
);


--
-- Name: message_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_images (
    message_id bigint NOT NULL,
    sha256 text NOT NULL,
    seg_index integer NOT NULL
);


--
-- Name: message_relations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_relations (
    relation_id bigint NOT NULL,
    canonical_message_id bigint NOT NULL,
    relation_kind text NOT NULL,
    target_canonical_message_id bigint,
    target_native_event_id text,
    reaction_key text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reaction_added boolean DEFAULT true NOT NULL,
    relation_position integer,
    CONSTRAINT message_relations_check CHECK (((target_canonical_message_id IS NOT NULL) OR (target_native_event_id IS NOT NULL))),
    CONSTRAINT message_relations_relation_kind_check CHECK ((relation_kind = ANY (ARRAY['reply'::text, 'replace'::text, 'redacts'::text, 'reaction'::text, 'contained_in'::text])))
);


--
-- Name: message_relations_relation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.message_relations_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_relations_relation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.message_relations_relation_id_seq OWNED BY public.message_relations.relation_id;


--
-- Name: message_videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_videos (
    message_id bigint NOT NULL,
    seg_index integer NOT NULL,
    sha256 text NOT NULL
);


--
-- Name: messages_ingest_seq_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_ingest_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_ingest_seq_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_ingest_seq_seq OWNED BY public.messages.ingest_seq;


--
-- Name: permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permissions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    capability text NOT NULL,
    scope_group_id bigint,
    deny boolean DEFAULT false NOT NULL,
    granted_by bigint NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.permissions_id_seq OWNED BY public.permissions.id;


--
-- Name: platform_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_accounts (
    platform_account_id bigint NOT NULL,
    platform text NOT NULL,
    native_account_id text NOT NULL,
    display_name text,
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_accounts_native_account_id_check CHECK ((native_account_id <> ''::text)),
    CONSTRAINT platform_accounts_platform_check CHECK ((platform <> ''::text))
);


--
-- Name: platform_accounts_platform_account_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_accounts_platform_account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_accounts_platform_account_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.platform_accounts_platform_account_id_seq OWNED BY public.platform_accounts.platform_account_id;


--
-- Name: platform_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_events (
    platform_event_id bigint NOT NULL,
    endpoint_id bigint NOT NULL,
    native_event_id text NOT NULL,
    sender_identity_id bigint,
    event_kind text DEFAULT 'message'::text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    source_cursor jsonb,
    raw_payload jsonb,
    raw_payload_truncated boolean DEFAULT false NOT NULL,
    canonical_message_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_events_event_kind_check CHECK ((event_kind = ANY (ARRAY['message'::text, 'edit'::text, 'reaction'::text, 'redaction'::text, 'membership'::text]))),
    CONSTRAINT platform_events_native_event_id_check CHECK ((native_event_id <> ''::text))
);


--
-- Name: platform_events_platform_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_events_platform_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_events_platform_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.platform_events_platform_event_id_seq OWNED BY public.platform_events.platform_event_id;


--
-- Name: platform_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_ids; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_ids (
    platform text NOT NULL,
    kind text NOT NULL,
    native_id text NOT NULL,
    mapped_id bigint DEFAULT ('-1000000000000'::bigint - nextval('public.platform_id_seq'::regclass)) NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_ids_kind_check CHECK ((kind = ANY (ARRAY['user'::text, 'channel'::text, 'message'::text])))
);


--
-- Name: platform_ingest_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_ingest_cursors (
    platform_account_id bigint NOT NULL,
    stream_key text NOT NULL,
    cursor jsonb NOT NULL,
    source_fingerprint text,
    revision bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_ingest_cursors_revision_check CHECK ((revision >= 0))
);


--
-- Name: principal_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.principal_identities (
    principal_identity_id bigint NOT NULL,
    principal_id bigint NOT NULL,
    platform_account_id bigint NOT NULL,
    native_user_id text NOT NULL,
    display_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT principal_identities_native_user_id_check CHECK ((native_user_id <> ''::text))
);


--
-- Name: principal_identities_principal_identity_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.principal_identities_principal_identity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: principal_identities_principal_identity_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.principal_identities_principal_identity_id_seq OWNED BY public.principal_identities.principal_identity_id;


--
-- Name: principals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.principals (
    principal_id bigint NOT NULL,
    display_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: principals_principal_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.principals_principal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: principals_principal_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.principals_principal_id_seq OWNED BY public.principals.principal_id;


--
-- Name: reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminders (
    id bigint NOT NULL,
    group_id bigint NOT NULL,
    user_id bigint NOT NULL,
    self_id bigint NOT NULL,
    text text NOT NULL,
    cron_expr text,
    fire_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    fired_at timestamp with time zone,
    delivery_attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone,
    last_error text,
    parked_at timestamp with time zone
);


--
-- Name: reminders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.reminders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.reminders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    group_id bigint NOT NULL,
    model text,
    persona text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    cleared_at timestamp with time zone,
    pinned jsonb DEFAULT '[]'::jsonb NOT NULL,
    debug_override boolean,
    sticker_override boolean,
    proactive_override boolean,
    effort_override text,
    revision bigint DEFAULT 0 NOT NULL,
    CONSTRAINT sessions_revision_check CHECK ((revision >= 0))
);


--
-- Name: skills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.skills (
    id bigint NOT NULL,
    name text NOT NULL,
    group_id bigint,
    description text NOT NULL,
    body text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: skills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.skills_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: skills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.skills_id_seq OWNED BY public.skills.id;


--
-- Name: stickers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stickers (
    sha256 text NOT NULL,
    kind text NOT NULL,
    emoji_id text,
    emoji_package_id text,
    mface_key text,
    summary text,
    description text,
    caption_attempts integer DEFAULT 0 NOT NULL,
    banned boolean DEFAULT false NOT NULL,
    times_seen integer DEFAULT 1 NOT NULL,
    times_sent integer DEFAULT 0 NOT NULL,
    first_group_id bigint,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    embedding public.vector,
    id bigint NOT NULL,
    embedding_model text,
    embedding_dimensions integer,
    embedding_content_hash text,
    embedding_updated_at timestamp with time zone,
    CONSTRAINT stickers_embedding_metadata_consistent CHECK ((((embedding IS NULL) AND (embedding_model IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_content_hash IS NULL) AND (embedding_updated_at IS NULL)) OR ((embedding IS NOT NULL) AND (embedding_model IS NOT NULL) AND (embedding_dimensions IS NOT NULL) AND (embedding_dimensions > 0) AND (embedding_dimensions = public.vector_dims(embedding)) AND (embedding_content_hash IS NOT NULL) AND (embedding_content_hash ~ '^[0-9a-f]{64}$'::text) AND (embedding_updated_at IS NOT NULL)))),
    CONSTRAINT stickers_kind_check CHECK ((kind = ANY (ARRAY['custom'::text, 'mface'::text])))
);


--
-- Name: stickers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stickers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.stickers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: synthetic_message_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.synthetic_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.videos (
    sha256 text NOT NULL,
    mime_type text NOT NULL,
    bytes_size bigint NOT NULL,
    local_path text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    description text,
    caption_attempts integer DEFAULT 0 NOT NULL,
    duration_seconds double precision
);


--
-- Name: context_plan_traces id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_plan_traces ALTER COLUMN id SET DEFAULT nextval('public.context_plan_traces_id_seq'::regclass);


--
-- Name: conversation_compartments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments ALTER COLUMN id SET DEFAULT nextval('public.conversation_compartments_id_seq'::regclass);


--
-- Name: conversation_endpoints endpoint_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_endpoints ALTER COLUMN endpoint_id SET DEFAULT nextval('public.conversation_endpoints_endpoint_id_seq'::regclass);


--
-- Name: conversations conversation_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN conversation_id SET DEFAULT nextval('public.conversations_conversation_id_seq'::regclass);


--
-- Name: episode_capture_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_capture_runs ALTER COLUMN id SET DEFAULT nextval('public.episode_capture_runs_id_seq'::regclass);


--
-- Name: llm_calls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_calls ALTER COLUMN id SET DEFAULT nextval('public.llm_calls_id_seq'::regclass);


--
-- Name: llm_usage id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_usage ALTER COLUMN id SET DEFAULT nextval('public.llm_usage_id_seq'::regclass);


--
-- Name: memories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories ALTER COLUMN id SET DEFAULT nextval('public.memories_id_seq'::regclass);


--
-- Name: memory_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence ALTER COLUMN id SET DEFAULT nextval('public.memory_evidence_id_seq'::regclass);


--
-- Name: memory_mutations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_mutations ALTER COLUMN id SET DEFAULT nextval('public.memory_mutations_id_seq'::regclass);


--
-- Name: message_deliveries delivery_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries ALTER COLUMN delivery_id SET DEFAULT nextval('public.message_deliveries_delivery_id_seq'::regclass);


--
-- Name: message_relations relation_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_relations ALTER COLUMN relation_id SET DEFAULT nextval('public.message_relations_relation_id_seq'::regclass);


--
-- Name: messages ingest_seq; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN ingest_seq SET DEFAULT nextval('public.messages_ingest_seq_seq'::regclass);


--
-- Name: messages canonical_message_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN canonical_message_id SET DEFAULT nextval('public.canonical_message_id_seq'::regclass);


--
-- Name: permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions ALTER COLUMN id SET DEFAULT nextval('public.permissions_id_seq'::regclass);


--
-- Name: platform_accounts platform_account_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_accounts ALTER COLUMN platform_account_id SET DEFAULT nextval('public.platform_accounts_platform_account_id_seq'::regclass);


--
-- Name: platform_events platform_event_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events ALTER COLUMN platform_event_id SET DEFAULT nextval('public.platform_events_platform_event_id_seq'::regclass);


--
-- Name: principal_identities principal_identity_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_identities ALTER COLUMN principal_identity_id SET DEFAULT nextval('public.principal_identities_principal_identity_id_seq'::regclass);


--
-- Name: principals principal_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principals ALTER COLUMN principal_id SET DEFAULT nextval('public.principals_principal_id_seq'::regclass);


--
-- Name: skills id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.skills ALTER COLUMN id SET DEFAULT nextval('public.skills_id_seq'::regclass);


--
-- Name: admin_timeline_revisions admin_timeline_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_timeline_revisions
    ADD CONSTRAINT admin_timeline_revisions_pkey PRIMARY KEY (conversation_id);


--
-- Name: compartment_evidence compartment_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compartment_evidence
    ADD CONSTRAINT compartment_evidence_pkey PRIMARY KEY (compartment_id, summary_tier, source_message_id);


--
-- Name: context_materialization_versions context_materialization_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_materialization_versions
    ADD CONSTRAINT context_materialization_versions_pkey PRIMARY KEY (conversation_id, revision);


--
-- Name: context_materializations context_materializations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_materializations
    ADD CONSTRAINT context_materializations_pkey PRIMARY KEY (conversation_id);


--
-- Name: context_plan_traces context_plan_traces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.context_plan_traces
    ADD CONSTRAINT context_plan_traces_pkey PRIMARY KEY (id);


--
-- Name: conversation_compartments conversation_compartments_active_range_excl; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_active_range_excl EXCLUDE USING gist (conversation_id WITH =, source_range WITH &&) WHERE ((state = 'active'::text));


--
-- Name: conversation_compartments conversation_compartments_capture_run_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_capture_run_id_key UNIQUE (capture_run_id);


--
-- Name: conversation_compartments conversation_compartments_expand_handle_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_expand_handle_key UNIQUE (expand_handle);


--
-- Name: conversation_compartments conversation_compartments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_pkey PRIMARY KEY (id);


--
-- Name: conversation_cursors conversation_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_cursors
    ADD CONSTRAINT conversation_cursors_pkey PRIMARY KEY (conversation_id, cursor_name);


--
-- Name: conversation_endpoints conversation_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_endpoints
    ADD CONSTRAINT conversation_endpoints_pkey PRIMARY KEY (endpoint_id);


--
-- Name: conversation_endpoints conversation_endpoints_platform_account_id_native_conversat_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_endpoints
    ADD CONSTRAINT conversation_endpoints_platform_account_id_native_conversat_key UNIQUE (platform_account_id, native_conversation_id);


--
-- Name: conversations conversations_legacy_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_legacy_group_id_key UNIQUE (legacy_group_id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (conversation_id);


--
-- Name: episode_capture_runs episode_capture_runs_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_capture_runs
    ADD CONSTRAINT episode_capture_runs_idempotency_key_key UNIQUE (idempotency_key);


--
-- Name: episode_capture_runs episode_capture_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_capture_runs
    ADD CONSTRAINT episode_capture_runs_pkey PRIMARY KEY (id);


--
-- Name: episode_memory_proposals episode_memory_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_memory_proposals
    ADD CONSTRAINT episode_memory_proposals_pkey PRIMARY KEY (capture_run_id, proposal_index);


--
-- Name: fetch_jobs fetch_jobs_kind_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fetch_jobs
    ADD CONSTRAINT fetch_jobs_kind_dedupe_key_key UNIQUE (kind, dedupe_key);


--
-- Name: fetch_jobs fetch_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fetch_jobs
    ADD CONSTRAINT fetch_jobs_pkey PRIMARY KEY (id);


--
-- Name: group_files group_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_files
    ADD CONSTRAINT group_files_pkey PRIMARY KEY (file_id);


--
-- Name: images images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_pkey PRIMARY KEY (sha256);


--
-- Name: llm_calls llm_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_calls
    ADD CONSTRAINT llm_calls_pkey PRIMARY KEY (id);


--
-- Name: llm_usage llm_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.llm_usage
    ADD CONSTRAINT llm_usage_pkey PRIMARY KEY (id);


--
-- Name: maintenance_leases maintenance_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.maintenance_leases
    ADD CONSTRAINT maintenance_leases_pkey PRIMARY KEY (domain);


--
-- Name: memories memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_pkey PRIMARY KEY (id);


--
-- Name: memory_evidence memory_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence
    ADD CONSTRAINT memory_evidence_pkey PRIMARY KEY (id);


--
-- Name: memory_mutations memory_mutations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_mutations
    ADD CONSTRAINT memory_mutations_pkey PRIMARY KEY (id);


--
-- Name: memory_versions memory_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_versions
    ADD CONSTRAINT memory_versions_pkey PRIMARY KEY (memory_id, version);


--
-- Name: message_deliveries message_deliveries_canonical_message_id_endpoint_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_canonical_message_id_endpoint_id_key UNIQUE (canonical_message_id, endpoint_id);


--
-- Name: message_deliveries message_deliveries_endpoint_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_endpoint_id_idempotency_key_key UNIQUE (endpoint_id, idempotency_key);


--
-- Name: message_deliveries message_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_pkey PRIMARY KEY (delivery_id);


--
-- Name: message_dispatches message_dispatches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_dispatches
    ADD CONSTRAINT message_dispatches_pkey PRIMARY KEY (canonical_message_id);


--
-- Name: message_images message_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_images
    ADD CONSTRAINT message_images_pkey PRIMARY KEY (message_id, seg_index);


--
-- Name: message_relations message_relations_canonical_message_relation_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_relations
    ADD CONSTRAINT message_relations_canonical_message_relation_unique UNIQUE NULLS NOT DISTINCT (canonical_message_id, relation_kind, target_canonical_message_id, target_native_event_id, reaction_key, reaction_added, relation_position);


--
-- Name: message_relations message_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_relations
    ADD CONSTRAINT message_relations_pkey PRIMARY KEY (relation_id);


--
-- Name: message_videos message_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_videos
    ADD CONSTRAINT message_videos_pkey PRIMARY KEY (message_id, seg_index);


--
-- Name: messages messages_canonical_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_canonical_message_id_key UNIQUE (canonical_message_id);


--
-- Name: messages messages_conversation_seq_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_seq_key UNIQUE (conversation_id, conversation_seq);


--
-- Name: messages messages_ingest_seq_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_ingest_seq_key UNIQUE (ingest_seq);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (message_id);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: permissions permissions_user_id_capability_scope_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_user_id_capability_scope_group_id_key UNIQUE (user_id, capability, scope_group_id);


--
-- Name: platform_accounts platform_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_accounts
    ADD CONSTRAINT platform_accounts_pkey PRIMARY KEY (platform_account_id);


--
-- Name: platform_accounts platform_accounts_platform_native_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_accounts
    ADD CONSTRAINT platform_accounts_platform_native_account_id_key UNIQUE (platform, native_account_id);


--
-- Name: platform_events platform_events_endpoint_id_native_event_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events
    ADD CONSTRAINT platform_events_endpoint_id_native_event_id_key UNIQUE (endpoint_id, native_event_id);


--
-- Name: platform_events platform_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events
    ADD CONSTRAINT platform_events_pkey PRIMARY KEY (platform_event_id);


--
-- Name: platform_ids platform_ids_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_ids
    ADD CONSTRAINT platform_ids_pkey PRIMARY KEY (mapped_id);


--
-- Name: platform_ids platform_ids_platform_kind_native_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_ids
    ADD CONSTRAINT platform_ids_platform_kind_native_id_key UNIQUE (platform, kind, native_id);


--
-- Name: platform_ingest_cursors platform_ingest_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_ingest_cursors
    ADD CONSTRAINT platform_ingest_cursors_pkey PRIMARY KEY (platform_account_id, stream_key);


--
-- Name: principal_identities principal_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_identities
    ADD CONSTRAINT principal_identities_pkey PRIMARY KEY (principal_identity_id);


--
-- Name: principal_identities principal_identities_platform_account_id_native_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_identities
    ADD CONSTRAINT principal_identities_platform_account_id_native_user_id_key UNIQUE (platform_account_id, native_user_id);


--
-- Name: principals principals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principals
    ADD CONSTRAINT principals_pkey PRIMARY KEY (principal_id);


--
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (group_id);


--
-- Name: skills skills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.skills
    ADD CONSTRAINT skills_pkey PRIMARY KEY (id);


--
-- Name: stickers stickers_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stickers
    ADD CONSTRAINT stickers_id_key UNIQUE (id);


--
-- Name: stickers stickers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stickers
    ADD CONSTRAINT stickers_pkey PRIMARY KEY (sha256);


--
-- Name: videos videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos
    ADD CONSTRAINT videos_pkey PRIMARY KEY (sha256);


--
-- Name: compartment_evidence_message_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX compartment_evidence_message_idx ON public.compartment_evidence USING btree (source_message_id, compartment_id);


--
-- Name: context_plan_traces_conversation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX context_plan_traces_conversation_idx ON public.context_plan_traces USING btree (conversation_id, id DESC);


--
-- Name: conversation_compartments_active_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_compartments_active_order_idx ON public.conversation_compartments USING btree (conversation_id, start_ingest_seq, end_ingest_seq) WHERE (state = 'active'::text);


--
-- Name: conversation_compartments_materialization_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX conversation_compartments_materialization_idx ON public.conversation_compartments USING btree (conversation_id, materialization_version);


--
-- Name: conversation_endpoints_conversation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_endpoints_conversation_idx ON public.conversation_endpoints USING btree (conversation_id, enabled);


--
-- Name: episode_capture_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_capture_claim_idx ON public.episode_capture_runs USING btree (COALESCE(next_retry_at, created_at), id) WHERE (status = ANY (ARRAY['pending'::text, 'failed'::text, 'leased'::text, 'generated'::text]));


--
-- Name: episode_capture_one_open_rebuild_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_capture_one_open_rebuild_idx ON public.episode_capture_runs USING btree (replaces_compartment_id) WHERE ((replaces_compartment_id IS NOT NULL) AND (status = ANY (ARRAY['pending'::text, 'leased'::text, 'generated'::text, 'failed'::text])));


--
-- Name: fetch_jobs_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fetch_jobs_pending_idx ON public.fetch_jobs USING btree (kind, id) WHERE (parked_at IS NULL);


--
-- Name: group_files_group_received_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX group_files_group_received_idx ON public.group_files USING btree (group_id, received_at DESC);


--
-- Name: group_files_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX group_files_sha256_idx ON public.group_files USING btree (sha256) WHERE (sha256 IS NOT NULL);


--
-- Name: images_uncaptioned_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX images_uncaptioned_idx ON public.images USING btree (first_seen_at) WHERE ((description IS NULL) AND (caption_attempts < 5));


--
-- Name: llm_calls_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX llm_calls_at_idx ON public.llm_calls USING btree (at DESC);


--
-- Name: llm_calls_group_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX llm_calls_group_at_idx ON public.llm_calls USING btree (group_id, at DESC);


--
-- Name: llm_usage_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX llm_usage_at_idx ON public.llm_usage USING btree (at DESC);


--
-- Name: llm_usage_group_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX llm_usage_group_at_idx ON public.llm_usage USING btree (group_id, at DESC);


--
-- Name: maintenance_leases_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX maintenance_leases_expiry_idx ON public.maintenance_leases USING btree (expires_at);


--
-- Name: memories_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_scope_idx ON public.memories USING btree (scope, scope_id);


--
-- Name: memories_visible_namespace_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_visible_namespace_idx ON public.memories USING btree (scope, scope_id, source_group_id, updated_at DESC, id DESC) WHERE (lifecycle = ANY (ARRAY['active'::text, 'permanent'::text]));


--
-- Name: memory_evidence_memory_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_evidence_memory_idx ON public.memory_evidence USING btree (memory_id, memory_version);


--
-- Name: memory_evidence_source_range_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_evidence_source_range_idx ON public.memory_evidence USING btree (source_conversation_id, source_start_ingest_seq, source_end_ingest_seq) WHERE (source_start_ingest_seq IS NOT NULL);


--
-- Name: memory_mutations_memory_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_mutations_memory_idx ON public.memory_mutations USING btree (memory_id, created_at DESC, id DESC);


--
-- Name: memory_versions_memory_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_versions_memory_idx ON public.memory_versions USING btree (memory_id, version DESC);


--
-- Name: message_deliveries_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_deliveries_claim_idx ON public.message_deliveries USING btree (next_attempt_at, delivery_id) WHERE (status = ANY (ARRAY['pending'::text, 'failed'::text]));


--
-- Name: message_deliveries_native_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX message_deliveries_native_event_idx ON public.message_deliveries USING btree (endpoint_id, native_event_id) WHERE (native_event_id IS NOT NULL);


--
-- Name: message_deliveries_sending_lease_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_deliveries_sending_lease_idx ON public.message_deliveries USING btree (lease_expires_at, delivery_id) WHERE (status = 'sending'::text);


--
-- Name: message_dispatches_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_dispatches_claim_idx ON public.message_dispatches USING btree (next_attempt_at, canonical_message_id) WHERE (status = ANY (ARRAY['pending'::text, 'failed'::text]));


--
-- Name: message_images_sha_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_images_sha_idx ON public.message_images USING btree (sha256);


--
-- Name: message_relations_meta_target_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_relations_meta_target_idx ON public.message_relations USING btree (target_canonical_message_id, relation_kind, reaction_key, reaction_added, canonical_message_id);


--
-- Name: message_videos_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX message_videos_sha256_idx ON public.message_videos USING btree (sha256);


--
-- Name: messages_canonical_conversation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_canonical_conversation_idx ON public.messages USING btree (conversation_id, conversation_seq);


--
-- Name: messages_group_ingest_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_group_ingest_idx ON public.messages USING btree (group_id, ingest_seq);


--
-- Name: messages_group_received_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_group_received_idx ON public.messages USING btree (group_id, received_at DESC);


--
-- Name: messages_group_recent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_group_recent_idx ON public.messages USING btree (group_id, received_at DESC) WHERE (kind = 'chat'::text);


--
-- Name: messages_rendered_text_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_rendered_text_trgm ON public.messages USING gin (rendered_text public.gin_trgm_ops);


--
-- Name: messages_reply_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_reply_idx ON public.messages USING btree (reply_to_message_id);


--
-- Name: messages_text_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_text_idx ON public.messages USING gin (rendered_text_tsv);


--
-- Name: messages_unembedded_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_unembedded_idx ON public.messages USING btree (received_at DESC) WHERE (embedding IS NULL);


--
-- Name: messages_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_user_idx ON public.messages USING btree (user_id);


--
-- Name: permissions_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX permissions_user_idx ON public.permissions USING btree (user_id);


--
-- Name: platform_events_canonical_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_events_canonical_idx ON public.platform_events USING btree (canonical_message_id);


--
-- Name: principal_identities_principal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX principal_identities_principal_idx ON public.principal_identities USING btree (principal_id);


--
-- Name: reminders_due_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reminders_due_idx ON public.reminders USING btree (COALESCE(next_attempt_at, fire_at)) WHERE ((fired_at IS NULL) AND (parked_at IS NULL));


--
-- Name: skills_scope_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX skills_scope_name_idx ON public.skills USING btree (COALESCE(group_id, (0)::bigint), name);


--
-- Name: stickers_uncaptioned_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stickers_uncaptioned_idx ON public.stickers USING btree (first_seen_at) WHERE ((description IS NULL) AND (NOT banned) AND (caption_attempts < 5));


--
-- Name: stickers_unembedded_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stickers_unembedded_idx ON public.stickers USING btree (first_seen_at) WHERE ((embedding IS NULL) AND (description IS NOT NULL) AND (NOT banned));


--
-- Name: videos_uncaptioned_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_uncaptioned_idx ON public.videos USING btree (first_seen_at) WHERE ((description IS NULL) AND (caption_attempts < 5));


--
-- Name: compartment_evidence compartment_evidence_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER compartment_evidence_append_only BEFORE DELETE OR UPDATE ON public.compartment_evidence FOR EACH ROW EXECUTE FUNCTION public.reject_episode_evidence_mutation();


--
-- Name: context_materialization_versions context_materialization_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER context_materialization_versions_append_only BEFORE DELETE OR UPDATE ON public.context_materialization_versions FOR EACH ROW EXECUTE FUNCTION public.reject_context_materialization_version_mutation();


--
-- Name: conversation_endpoints conversation_endpoints_notify_timeline_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversation_endpoints_notify_timeline_work AFTER INSERT OR UPDATE ON public.conversation_endpoints FOR EACH ROW EXECUTE FUNCTION public.max_notify_timeline_work();


--
-- Name: episode_memory_proposals episode_memory_proposals_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER episode_memory_proposals_append_only BEFORE DELETE OR UPDATE ON public.episode_memory_proposals FOR EACH ROW EXECUTE FUNCTION public.reject_episode_evidence_mutation();


--
-- Name: fetch_jobs fetch_jobs_notify_all_timelines; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER fetch_jobs_notify_all_timelines AFTER INSERT OR DELETE OR UPDATE ON public.fetch_jobs FOR EACH ROW EXECUTE FUNCTION public.max_notify_all_timelines();


--
-- Name: memories memories_invalidate_embedding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memories_invalidate_embedding BEFORE UPDATE OF content ON public.memories FOR EACH ROW EXECUTE FUNCTION public.invalidate_embedding_on_source_change('content');


--
-- Name: memory_evidence memory_evidence_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_evidence_append_only BEFORE DELETE OR UPDATE ON public.memory_evidence FOR EACH ROW EXECUTE FUNCTION public.reject_memory_ledger_mutation();


--
-- Name: memory_mutations memory_mutations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_mutations_append_only BEFORE DELETE OR UPDATE ON public.memory_mutations FOR EACH ROW EXECUTE FUNCTION public.reject_memory_ledger_mutation();


--
-- Name: memory_versions memory_versions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_versions_append_only BEFORE DELETE OR UPDATE ON public.memory_versions FOR EACH ROW EXECUTE FUNCTION public.reject_memory_ledger_mutation();


--
-- Name: message_deliveries message_deliveries_notify_timeline_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER message_deliveries_notify_timeline_work AFTER INSERT OR UPDATE ON public.message_deliveries FOR EACH ROW EXECUTE FUNCTION public.max_notify_timeline_delivery_work();


--
-- Name: message_deliveries message_deliveries_notify_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER message_deliveries_notify_work AFTER INSERT OR UPDATE OF status, next_attempt_at ON public.message_deliveries FOR EACH ROW EXECUTE FUNCTION public.max_notify_delivery_work();


--
-- Name: message_dispatches message_dispatches_notify_timeline_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER message_dispatches_notify_timeline_work AFTER INSERT OR UPDATE ON public.message_dispatches FOR EACH ROW EXECUTE FUNCTION public.max_notify_timeline_dispatch_work();


--
-- Name: message_dispatches message_dispatches_notify_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER message_dispatches_notify_work AFTER INSERT OR UPDATE OF status, next_attempt_at ON public.message_dispatches FOR EACH ROW EXECUTE FUNCTION public.max_notify_dispatch_work();


--
-- Name: messages messages_assign_canonical_sequence_before; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER messages_assign_canonical_sequence_before BEFORE INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.messages_assign_canonical_sequence();


--
-- Name: messages messages_invalidate_embedding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER messages_invalidate_embedding BEFORE UPDATE OF rendered_text ON public.messages FOR EACH ROW EXECUTE FUNCTION public.invalidate_embedding_on_source_change('rendered_text');


--
-- Name: messages messages_notify_timeline_work; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER messages_notify_timeline_work AFTER INSERT ON public.messages FOR EACH ROW EXECUTE FUNCTION public.max_notify_timeline_work();


--
-- Name: platform_accounts platform_accounts_notify_all_timelines; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER platform_accounts_notify_all_timelines AFTER UPDATE ON public.platform_accounts FOR EACH ROW EXECUTE FUNCTION public.max_notify_all_timelines();


--
-- Name: stickers stickers_invalidate_embedding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stickers_invalidate_embedding BEFORE UPDATE OF description ON public.stickers FOR EACH ROW EXECUTE FUNCTION public.invalidate_embedding_on_source_change('description');


--
-- Name: admin_timeline_revisions admin_timeline_revisions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_timeline_revisions
    ADD CONSTRAINT admin_timeline_revisions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(conversation_id) ON DELETE CASCADE;


--
-- Name: compartment_evidence compartment_evidence_compartment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compartment_evidence
    ADD CONSTRAINT compartment_evidence_compartment_id_fkey FOREIGN KEY (compartment_id) REFERENCES public.conversation_compartments(id) ON DELETE RESTRICT;


--
-- Name: compartment_evidence compartment_evidence_source_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compartment_evidence
    ADD CONSTRAINT compartment_evidence_source_message_id_fkey FOREIGN KEY (source_message_id) REFERENCES public.messages(message_id) ON DELETE RESTRICT;


--
-- Name: conversation_compartments conversation_compartments_capture_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_capture_run_id_fkey FOREIGN KEY (capture_run_id) REFERENCES public.episode_capture_runs(id) ON DELETE RESTRICT;


--
-- Name: conversation_compartments conversation_compartments_superseded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_compartments
    ADD CONSTRAINT conversation_compartments_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES public.conversation_compartments(id) ON DELETE RESTRICT;


--
-- Name: conversation_endpoints conversation_endpoints_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_endpoints
    ADD CONSTRAINT conversation_endpoints_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(conversation_id) ON DELETE CASCADE;


--
-- Name: conversation_endpoints conversation_endpoints_platform_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_endpoints
    ADD CONSTRAINT conversation_endpoints_platform_account_id_fkey FOREIGN KEY (platform_account_id) REFERENCES public.platform_accounts(platform_account_id) ON DELETE RESTRICT;


--
-- Name: episode_capture_runs episode_capture_published_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_capture_runs
    ADD CONSTRAINT episode_capture_published_fkey FOREIGN KEY (published_compartment_id) REFERENCES public.conversation_compartments(id) ON DELETE RESTRICT;


--
-- Name: episode_capture_runs episode_capture_replaces_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_capture_runs
    ADD CONSTRAINT episode_capture_replaces_fkey FOREIGN KEY (replaces_compartment_id) REFERENCES public.conversation_compartments(id) ON DELETE RESTRICT;


--
-- Name: episode_memory_proposals episode_memory_proposals_capture_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_memory_proposals
    ADD CONSTRAINT episode_memory_proposals_capture_run_id_fkey FOREIGN KEY (capture_run_id) REFERENCES public.episode_capture_runs(id) ON DELETE RESTRICT;


--
-- Name: episode_memory_proposals episode_memory_proposals_memory_id_memory_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_memory_proposals
    ADD CONSTRAINT episode_memory_proposals_memory_id_memory_version_fkey FOREIGN KEY (memory_id, memory_version) REFERENCES public.memory_versions(memory_id, version) ON DELETE RESTRICT;


--
-- Name: memories memories_superseded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES public.memories(id) ON DELETE RESTRICT;


--
-- Name: memory_evidence memory_evidence_memory_id_memory_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence
    ADD CONSTRAINT memory_evidence_memory_id_memory_version_fkey FOREIGN KEY (memory_id, memory_version) REFERENCES public.memory_versions(memory_id, version) ON DELETE RESTRICT;


--
-- Name: memory_mutations memory_mutations_memory_id_to_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_mutations
    ADD CONSTRAINT memory_mutations_memory_id_to_version_fkey FOREIGN KEY (memory_id, to_version) REFERENCES public.memory_versions(memory_id, version) ON DELETE RESTRICT;


--
-- Name: memory_versions memory_versions_memory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_versions
    ADD CONSTRAINT memory_versions_memory_id_fkey FOREIGN KEY (memory_id) REFERENCES public.memories(id) ON DELETE RESTRICT;


--
-- Name: memory_versions memory_versions_superseded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_versions
    ADD CONSTRAINT memory_versions_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES public.memories(id) ON DELETE RESTRICT;


--
-- Name: message_deliveries message_deliveries_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_endpoint_id_fkey FOREIGN KEY (endpoint_id) REFERENCES public.conversation_endpoints(endpoint_id) ON DELETE CASCADE;


--
-- Name: message_deliveries message_deliveries_message_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_message_fk FOREIGN KEY (canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE CASCADE;


--
-- Name: message_dispatches message_dispatches_message_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_dispatches
    ADD CONSTRAINT message_dispatches_message_fk FOREIGN KEY (canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE CASCADE;


--
-- Name: message_images message_images_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_images
    ADD CONSTRAINT message_images_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(message_id) ON DELETE CASCADE;


--
-- Name: message_images message_images_sha256_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_images
    ADD CONSTRAINT message_images_sha256_fkey FOREIGN KEY (sha256) REFERENCES public.images(sha256) ON DELETE RESTRICT;


--
-- Name: message_relations message_relations_message_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_relations
    ADD CONSTRAINT message_relations_message_fk FOREIGN KEY (canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE CASCADE;


--
-- Name: message_relations message_relations_target_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_relations
    ADD CONSTRAINT message_relations_target_fk FOREIGN KEY (target_canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE SET NULL;


--
-- Name: message_videos message_videos_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_videos
    ADD CONSTRAINT message_videos_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(message_id) ON DELETE CASCADE;


--
-- Name: message_videos message_videos_sha256_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_videos
    ADD CONSTRAINT message_videos_sha256_fkey FOREIGN KEY (sha256) REFERENCES public.videos(sha256);


--
-- Name: messages messages_author_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_author_principal_id_fkey FOREIGN KEY (author_principal_id) REFERENCES public.principals(principal_id) ON DELETE RESTRICT;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(conversation_id) ON DELETE RESTRICT;


--
-- Name: messages messages_origin_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_origin_endpoint_id_fkey FOREIGN KEY (origin_endpoint_id) REFERENCES public.conversation_endpoints(endpoint_id) ON DELETE RESTRICT;


--
-- Name: messages messages_reply_to_canonical_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_reply_to_canonical_fk FOREIGN KEY (reply_to_canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE SET NULL;


--
-- Name: platform_events platform_events_canonical_message_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events
    ADD CONSTRAINT platform_events_canonical_message_fk FOREIGN KEY (canonical_message_id) REFERENCES public.messages(canonical_message_id) ON DELETE CASCADE;


--
-- Name: platform_events platform_events_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events
    ADD CONSTRAINT platform_events_endpoint_id_fkey FOREIGN KEY (endpoint_id) REFERENCES public.conversation_endpoints(endpoint_id) ON DELETE CASCADE;


--
-- Name: platform_events platform_events_sender_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_events
    ADD CONSTRAINT platform_events_sender_identity_id_fkey FOREIGN KEY (sender_identity_id) REFERENCES public.principal_identities(principal_identity_id) ON DELETE RESTRICT;


--
-- Name: platform_ingest_cursors platform_ingest_cursors_platform_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_ingest_cursors
    ADD CONSTRAINT platform_ingest_cursors_platform_account_id_fkey FOREIGN KEY (platform_account_id) REFERENCES public.platform_accounts(platform_account_id) ON DELETE CASCADE;


--
-- Name: principal_identities principal_identities_platform_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_identities
    ADD CONSTRAINT principal_identities_platform_account_id_fkey FOREIGN KEY (platform_account_id) REFERENCES public.platform_accounts(platform_account_id) ON DELETE CASCADE;


--
-- Name: principal_identities principal_identities_principal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.principal_identities
    ADD CONSTRAINT principal_identities_principal_id_fkey FOREIGN KEY (principal_id) REFERENCES public.principals(principal_id) ON DELETE CASCADE;


--
-- Name: stickers stickers_sha256_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stickers
    ADD CONSTRAINT stickers_sha256_fkey FOREIGN KEY (sha256) REFERENCES public.images(sha256) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


