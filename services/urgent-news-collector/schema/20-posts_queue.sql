-- posts_queue + content_revisions + system_flags: очередь публикаций. Снято с chat:postgres-local 05.10.26, pg_dump --schema-only --no-owner --no-privileges
--
-- PostgreSQL database dump
--

\restrict 0RUwrpeaNeer2ciOahLcEKTHQPq0aQRwzaufJr4fldHR5cmFaOTHwonFiIKGPHT

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

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
-- Name: content_revisions; Type: TABLE; Schema: public; Owner: -
--

-- Функция триггера updated_at: pg_dump -t <таблица> функции не выгружает,
-- без неё CREATE TRIGGER ниже падает. Текст — db/migrations/001_posts_queue.sql
-- службы content-publisher.
CREATE OR REPLACE FUNCTION public.update_posts_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TABLE public.content_revisions (
    id integer NOT NULL,
    post_id integer,
    revision_num integer DEFAULT 1,
    text_snapshot text,
    reviewer character varying(100),
    comment text,
    action character varying(30),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: content_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.content_revisions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: content_revisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.content_revisions_id_seq OWNED BY public.content_revisions.id;


--
-- Name: posts_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posts_queue (
    id integer NOT NULL,
    request_id uuid DEFAULT gen_random_uuid(),
    project_name character varying(200),
    content_type character varying(50),
    requester character varying(100) DEFAULT 'oksana'::character varying,
    request_text text,
    requested_at timestamp with time zone DEFAULT now(),
    deadline timestamp with time zone,
    is_urgent boolean DEFAULT false,
    draft_text text,
    smm_text text,
    final_text text,
    hashtags text[],
    media_path character varying(500),
    media_approved boolean DEFAULT false,
    status character varying(30) DEFAULT 'DRAFT'::character varying NOT NULL,
    reviewer character varying(100),
    review_comment text,
    reviewed_at timestamp with time zone,
    scheduled_at timestamp with time zone,
    published_at timestamp with time zone,
    tg_message_id bigint,
    tg_channel character varying(100) DEFAULT '@rznvictory'::character varying,
    created_by character varying(100),
    updated_at timestamp with time zone DEFAULT now(),
    iteration integer DEFAULT 1,
    CONSTRAINT posts_queue_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'WAITING_APPROVAL'::character varying, 'APPROVED'::character varying, 'SCHEDULED'::character varying, 'PUBLISHING'::character varying, 'PUBLISHED'::character varying, 'FAILED'::character varying, 'REJECTED'::character varying, 'ON_REVISION'::character varying, 'REVISION'::character varying])::text[])))
);


--
-- Name: posts_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.posts_queue_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: posts_queue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.posts_queue_id_seq OWNED BY public.posts_queue.id;


--
-- Name: system_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_flags (
    name text NOT NULL,
    value jsonb DEFAULT 'null'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: content_revisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_revisions ALTER COLUMN id SET DEFAULT nextval('public.content_revisions_id_seq'::regclass);


--
-- Name: posts_queue id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts_queue ALTER COLUMN id SET DEFAULT nextval('public.posts_queue_id_seq'::regclass);


--
-- Name: content_revisions content_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_revisions
    ADD CONSTRAINT content_revisions_pkey PRIMARY KEY (id);


--
-- Name: posts_queue posts_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts_queue
    ADD CONSTRAINT posts_queue_pkey PRIMARY KEY (id);


--
-- Name: posts_queue posts_queue_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts_queue
    ADD CONSTRAINT posts_queue_request_id_key UNIQUE (request_id);


--
-- Name: system_flags system_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_flags
    ADD CONSTRAINT system_flags_pkey PRIMARY KEY (name);


--
-- Name: idx_posts_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_created ON public.posts_queue USING btree (requested_at);


--
-- Name: idx_posts_requester; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_requester ON public.posts_queue USING btree (requester);


--
-- Name: idx_posts_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_scheduled ON public.posts_queue USING btree (scheduled_at) WHERE ((status)::text = 'SCHEDULED'::text);


--
-- Name: idx_posts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_status ON public.posts_queue USING btree (status);


--
-- Name: idx_revisions_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_revisions_post ON public.content_revisions USING btree (post_id);


--
-- Name: posts_queue_tg_message_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX posts_queue_tg_message_id_unique ON public.posts_queue USING btree (tg_message_id) WHERE (tg_message_id IS NOT NULL);


--
-- Name: posts_queue trigger_posts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_posts_updated_at BEFORE UPDATE ON public.posts_queue FOR EACH ROW EXECUTE FUNCTION public.update_posts_updated_at();


--
-- Name: content_revisions content_revisions_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_revisions
    ADD CONSTRAINT content_revisions_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.posts_queue(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 0RUwrpeaNeer2ciOahLcEKTHQPq0aQRwzaufJr4fldHR5cmFaOTHwonFiIKGPHT

