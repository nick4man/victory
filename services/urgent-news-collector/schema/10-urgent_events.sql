-- urgent_events: события конвейера новостей (pgvector 3072). Снято с chat:audit-v2-postgres 05.10.26, pg_dump --schema-only --no-owner --no-privileges
CREATE EXTENSION IF NOT EXISTS vector;
--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4
-- Dumped by pg_dump version 16.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: urgent_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.urgent_events (
    id integer NOT NULL,
    event_type character varying(50),
    headline text,
    details text,
    is_processed boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    embedding public.vector(3072),
    source_url text,
    relevance_tier character varying(20) DEFAULT 'URGENT'::character varying,
    audience_fit character varying(20) DEFAULT 'UNKNOWN'::character varying,
    published_to_tg boolean DEFAULT false
);


--
-- Name: urgent_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.urgent_events_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: urgent_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.urgent_events_id_seq OWNED BY public.urgent_events.id;


--
-- Name: urgent_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.urgent_events ALTER COLUMN id SET DEFAULT nextval('public.urgent_events_id_seq'::regclass);


--
-- Name: urgent_events urgent_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.urgent_events
    ADD CONSTRAINT urgent_events_pkey PRIMARY KEY (id);


--
-- Name: idx_urgent_events_pub_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_urgent_events_pub_tier ON public.urgent_events USING btree (published_to_tg, relevance_tier, created_at DESC);


--
-- Name: idx_urgent_events_tier_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_urgent_events_tier_created ON public.urgent_events USING btree (relevance_tier, created_at DESC);


--
-- Name: idx_urgent_events_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_urgent_events_url ON public.urgent_events USING btree (source_url) WHERE (source_url IS NOT NULL);


--
-- PostgreSQL database dump complete
--

