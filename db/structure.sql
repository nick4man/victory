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

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activation_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activation_events (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    channel character varying(32) NOT NULL,
    happened_at timestamp(6) without time zone NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    ip_address character varying(45),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: activation_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activation_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activation_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activation_events_id_seq OWNED BY public.activation_events.id;


--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: article_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.article_embeddings (
    id bigint NOT NULL,
    article_id bigint NOT NULL,
    content_hash character varying NOT NULL,
    content_text text NOT NULL,
    embedding public.vector(768) NOT NULL,
    embedded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: article_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.article_embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: article_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.article_embeddings_id_seq OWNED BY public.article_embeddings.id;


--
-- Name: articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.articles (
    id bigint NOT NULL,
    title character varying NOT NULL,
    slug character varying NOT NULL,
    excerpt text,
    body text NOT NULL,
    body_html text,
    author_id bigint,
    category character varying DEFAULT 'guides'::character varying NOT NULL,
    region character varying,
    schema_type character varying DEFAULT 'BlogPosting'::character varying NOT NULL,
    published_at timestamp(6) without time zone,
    views_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    external_id character varying,
    external_source character varying,
    hidden_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: articles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.articles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: articles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.articles_id_seq OWNED BY public.articles.id;


--
-- Name: bank_rate_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_rate_snapshots (
    id bigint NOT NULL,
    as_of date NOT NULL,
    kind character varying NOT NULL,
    payload jsonb NOT NULL,
    source character varying,
    items_count integer DEFAULT 0,
    status character varying DEFAULT 'ok'::character varying,
    error_log text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: bank_rate_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bank_rate_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bank_rate_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bank_rate_snapshots_id_seq OWNED BY public.bank_rate_snapshots.id;


--
-- Name: bot_command_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bot_command_logs (
    id bigint NOT NULL,
    tg_user_id bigint NOT NULL,
    command character varying NOT NULL,
    args text,
    result character varying,
    error_class character varying,
    created_at timestamp(6) without time zone NOT NULL,
    error_message text
);


--
-- Name: bot_command_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bot_command_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bot_command_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bot_command_logs_id_seq OWNED BY public.bot_command_logs.id;


--
-- Name: buyer_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.buyer_orders (
    id bigint NOT NULL,
    crm_id bigint NOT NULL,
    deal_type character varying NOT NULL,
    realty_type character varying,
    price_min bigint,
    price_max bigint,
    area_min numeric(10,2),
    area_max numeric(10,2),
    rooms_min integer,
    rooms_max integer,
    preferred_districts character varying[] DEFAULT '{}'::character varying[],
    preferred_cities character varying[] DEFAULT '{}'::character varying[],
    metro_stations character varying[] DEFAULT '{}'::character varying[],
    description text,
    user_id bigint,
    stage_name character varying,
    stage_id bigint,
    deal_state character varying,
    client_name character varying,
    client_phone_masked character varying,
    fc_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    client_crm_id bigint
);


--
-- Name: buyer_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.buyer_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: buyer_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.buyer_orders_id_seq OWNED BY public.buyer_orders.id;


--
-- Name: case_studies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_studies (
    id bigint NOT NULL,
    title character varying NOT NULL,
    slug character varying NOT NULL,
    excerpt text,
    body text NOT NULL,
    body_html text,
    client_alias character varying,
    client_origin character varying,
    client_profession character varying,
    district character varying,
    property_type integer DEFAULT 0 NOT NULL,
    area numeric(8,2),
    deal_amount bigint,
    deal_duration_days integer,
    bank character varying,
    mortgage_program character varying,
    author_id bigint,
    inquiry_id bigint,
    property_id bigint,
    meta_title character varying,
    meta_description character varying,
    og_image_url character varying,
    status integer DEFAULT 0 NOT NULL,
    published_at timestamp(6) without time zone,
    deleted_at timestamp(6) without time zone,
    views_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: case_studies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_studies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_studies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_studies_id_seq OWNED BY public.case_studies.id;


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    role integer NOT NULL,
    body text NOT NULL,
    author_id bigint,
    telegram_message_id bigint,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: chat_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.chat_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.chat_messages_id_seq OWNED BY public.chat_messages.id;


--
-- Name: city_median_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.city_median_prices (
    id bigint NOT NULL,
    city character varying NOT NULL,
    region character varying,
    property_type character varying NOT NULL,
    median_price_per_sqm integer NOT NULL,
    source character varying,
    as_of date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: city_median_prices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.city_median_prices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: city_median_prices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.city_median_prices_id_seq OWNED BY public.city_median_prices.id;


--
-- Name: client_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_documents (
    id bigint NOT NULL,
    uploader_id bigint NOT NULL,
    inquiry_id bigint,
    document_kind integer DEFAULT 0 NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    tg_chat_id character varying,
    tg_message_id character varying,
    tg_file_id character varying,
    yandex_vision_response jsonb DEFAULT '{}'::jsonb,
    parsed_data jsonb DEFAULT '{}'::jsonb,
    ocr_raw_text text,
    error_message text,
    processed_at timestamp(6) without time zone,
    reviewed_at timestamp(6) without time zone,
    reviewed_by_user_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    nextcloud_path character varying,
    property_id bigint
);


--
-- Name: client_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_documents_id_seq OWNED BY public.client_documents.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id bigint NOT NULL,
    visitor_token character varying NOT NULL,
    user_id bigint,
    assigned_user_id bigint,
    name character varying,
    phone character varying,
    email character varying,
    status integer DEFAULT 0 NOT NULL,
    escalated_at timestamp(6) without time zone,
    last_message_at timestamp(6) without time zone,
    telegram_chat_id bigint,
    telegram_message_id bigint,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: crm_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crm_reports (
    id bigint NOT NULL,
    crm_id bigint,
    title character varying NOT NULL,
    slug character varying NOT NULL,
    page_id integer NOT NULL,
    order_position integer DEFAULT 1,
    template_class character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    synced_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: crm_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.crm_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: crm_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.crm_reports_id_seq OWNED BY public.crm_reports.id;


--
-- Name: daily_digests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_digests (
    id bigint NOT NULL,
    date date NOT NULL,
    tg_chat_id bigint NOT NULL,
    tg_thread_id bigint,
    tg_message_id bigint NOT NULL,
    topic_key character varying DEFAULT 'dispatcher'::character varying,
    posted_at timestamp(6) without time zone NOT NULL,
    archived_at timestamp(6) without time zone,
    tasks_count integer DEFAULT 0,
    done_count integer DEFAULT 0,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: daily_digests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.daily_digests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: daily_digests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.daily_digests_id_seq OWNED BY public.daily_digests.id;


--
-- Name: departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.departments (
    id bigint NOT NULL,
    crm_id bigint NOT NULL,
    crm_parent_id bigint,
    company_id bigint,
    title character varying NOT NULL,
    address character varying,
    active boolean DEFAULT true NOT NULL,
    synced_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: departments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: departments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.departments_id_seq OWNED BY public.departments.id;


--
-- Name: districts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.districts (
    id bigint NOT NULL,
    name character varying NOT NULL,
    city character varying,
    boundary public.geometry(MultiPolygon,4326) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: districts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.districts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: districts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.districts_id_seq OWNED BY public.districts.id;


--
-- Name: document_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_requirements (
    id bigint NOT NULL,
    lead_event_id bigint,
    property_id bigint,
    kind character varying NOT NULL,
    status character varying DEFAULT 'not_requested'::character varying NOT NULL,
    requested_at timestamp(6) without time zone,
    received_at timestamp(6) without time zone,
    verified_at timestamp(6) without time zone,
    approved_at timestamp(6) without time zone,
    rejected_at timestamp(6) without time zone,
    requested_by_id bigint,
    verified_by_id bigint,
    approved_by_id bigint,
    received_via_client_document_id bigint,
    sla_seconds integer,
    last_reminder_at timestamp(6) without time zone,
    reminder_count integer DEFAULT 0 NOT NULL,
    note text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: document_requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_requirements_id_seq OWNED BY public.document_requirements.id;


--
-- Name: document_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_uploads (
    id bigint NOT NULL,
    uploaded_by_id bigint NOT NULL,
    nextcloud_path character varying NOT NULL,
    file_name character varying NOT NULL,
    file_size bigint DEFAULT 0 NOT NULL,
    content_type character varying,
    related_task_id bigint,
    related_property_id bigint,
    related_lead_event_id bigint,
    purpose character varying,
    uploaded_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: document_uploads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_uploads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_uploads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_uploads_id_seq OWNED BY public.document_uploads.id;


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    user_id bigint,
    title character varying NOT NULL,
    description text,
    document_type character varying NOT NULL,
    file_url character varying NOT NULL,
    file_name character varying,
    content_type character varying,
    file_size bigint,
    public boolean DEFAULT false NOT NULL,
    downloads_count integer DEFAULT 0 NOT NULL,
    verified_at timestamp(6) without time zone,
    verified_by_id bigint,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone
);


--
-- Name: documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documents_id_seq OWNED BY public.documents.id;


--
-- Name: external_listings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_listings (
    id bigint NOT NULL,
    source character varying NOT NULL,
    source_id character varying NOT NULL,
    url character varying,
    title character varying,
    description text,
    price integer,
    area double precision,
    land_area double precision,
    rooms integer,
    floor integer,
    total_floors integer,
    building_year integer,
    condition character varying,
    district character varying,
    address character varying,
    latitude double precision,
    longitude double precision,
    property_type character varying,
    deal_type character varying,
    seller_kind character varying,
    seller_name character varying,
    seller_phone character varying,
    fetched_at timestamp(6) without time zone NOT NULL,
    closed_at timestamp(6) without time zone,
    raw_payload jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: external_listings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.external_listings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_listings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.external_listings_id_seq OWNED BY public.external_listings.id;


--
-- Name: favorites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.favorites (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    property_id bigint NOT NULL,
    note text,
    notify_on_price_change boolean DEFAULT true,
    notify_on_status_change boolean DEFAULT true,
    source character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: favorites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.favorites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: favorites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.favorites_id_seq OWNED BY public.favorites.id;


--
-- Name: friendly_id_slugs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.friendly_id_slugs (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    sluggable_id integer NOT NULL,
    sluggable_type character varying(50),
    scope character varying,
    created_at timestamp(6) without time zone
);


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.friendly_id_slugs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: friendly_id_slugs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.friendly_id_slugs_id_seq OWNED BY public.friendly_id_slugs.id;


--
-- Name: inquiries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inquiries (
    id bigint NOT NULL,
    user_id bigint,
    property_id bigint,
    agent_id bigint,
    inquiry_type integer DEFAULT 0 NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    name character varying NOT NULL,
    phone character varying,
    email character varying,
    message text,
    comment text,
    preferred_date timestamp(6) without time zone,
    preferred_time character varying,
    scheduled_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    source character varying,
    utm_source character varying,
    utm_medium character varying,
    utm_campaign character varying,
    referrer_url character varying,
    ip_address character varying,
    user_agent character varying,
    processed_at timestamp(6) without time zone,
    cancelled_at timestamp(6) without time zone,
    cancellation_reason character varying,
    crm_id character varying,
    synced_to_crm_at timestamp(6) without time zone,
    priority integer DEFAULT 0,
    notifications_sent boolean DEFAULT false,
    last_notification_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    client_tg_user_id bigint,
    client_phone_e164 character varying,
    client_email_norm character varying,
    attribution_source character varying,
    external_listing_id bigint,
    staff_test boolean DEFAULT false NOT NULL,
    staff_test_matched_by character varying(64)
);


--
-- Name: inquiries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inquiries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inquiries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inquiries_id_seq OWNED BY public.inquiries.id;


--
-- Name: landing_contents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.landing_contents (
    id bigint NOT NULL,
    intent character varying NOT NULL,
    type character varying NOT NULL,
    district_slug character varying,
    rooms character varying,
    title character varying NOT NULL,
    meta_description character varying(300),
    body_blocks jsonb DEFAULT '[]'::jsonb,
    body_html text,
    body_plain text,
    published boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: landing_contents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.landing_contents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: landing_contents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.landing_contents_id_seq OWNED BY public.landing_contents.id;


--
-- Name: lead_event_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_event_embeddings (
    id bigint NOT NULL,
    lead_event_id bigint NOT NULL,
    content_hash character varying(64) NOT NULL,
    embedded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    embedding public.vector(768) NOT NULL
);


--
-- Name: lead_event_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lead_event_embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lead_event_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lead_event_embeddings_id_seq OWNED BY public.lead_event_embeddings.id;


--
-- Name: lead_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_events (
    id bigint NOT NULL,
    lead_ref_type character varying NOT NULL,
    lead_ref_id bigint NOT NULL,
    source character varying NOT NULL,
    tg_chat_id bigint NOT NULL,
    anchor_thread_id integer,
    anchor_message_id bigint,
    anchor_topic_key character varying DEFAULT 'dispatcher'::character varying NOT NULL,
    deal_mirror_message_id bigint,
    dispatcher_message_id bigint,
    current_stage character varying DEFAULT 'new'::character varying NOT NULL,
    assigned_to_id bigint,
    assigned_at timestamp(6) without time zone,
    first_contact_at timestamp(6) without time zone,
    closed_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    crm_sync_failed boolean DEFAULT false NOT NULL,
    crm_sync_last_error character varying,
    assigned_by_id bigint,
    routed_by_id bigint,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('russian'::regconfig, ((((COALESCE((metadata ->> 'summary'::text), ''::text) || ' '::text) || COALESCE((metadata ->> 'name'::text), ''::text)) || ' '::text) || COALESCE(((metadata -> 'notes'::text))::text, ''::text)))) STORED,
    staff_test boolean DEFAULT false NOT NULL,
    staff_test_matched_by character varying(64)
);


--
-- Name: lead_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lead_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lead_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lead_events_id_seq OWNED BY public.lead_events.id;


--
-- Name: listing_consents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listing_consents (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying NOT NULL,
    signed_at timestamp(6) without time zone NOT NULL,
    consent_text text NOT NULL,
    consent_version character varying NOT NULL,
    content_hash character varying NOT NULL,
    ip_address character varying,
    user_agent character varying,
    revoked_at timestamp(6) without time zone,
    revocation_reason character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: listing_consents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.listing_consents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: listing_consents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.listing_consents_id_seq OWNED BY public.listing_consents.id;


--
-- Name: magic_link_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.magic_link_tokens (
    id bigint NOT NULL,
    token character varying NOT NULL,
    identifier character varying NOT NULL,
    identifier_type character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    scope character varying DEFAULT 'login'::character varying NOT NULL
);


--
-- Name: magic_link_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.magic_link_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: magic_link_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.magic_link_tokens_id_seq OWNED BY public.magic_link_tokens.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    sender_id bigint NOT NULL,
    recipient_id bigint NOT NULL,
    property_id bigint,
    inquiry_id bigint,
    conversation_id character varying NOT NULL,
    parent_id bigint,
    subject character varying,
    body text NOT NULL,
    message_type integer DEFAULT 0 NOT NULL,
    read boolean DEFAULT false NOT NULL,
    read_at timestamp(6) without time zone,
    archived_by_sender boolean DEFAULT false,
    archived_by_recipient boolean DEFAULT false,
    deleted_by_sender boolean DEFAULT false,
    deleted_by_recipient boolean DEFAULT false,
    priority integer DEFAULT 0 NOT NULL,
    attachments_count integer DEFAULT 0 NOT NULL,
    attachments_metadata jsonb DEFAULT '{}'::jsonb,
    ip_address character varying,
    user_agent character varying,
    is_automated boolean DEFAULT false NOT NULL,
    automated_template character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: mls_listings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mls_listings (
    id bigint NOT NULL,
    external_source character varying NOT NULL,
    external_id character varying NOT NULL,
    deal_type character varying NOT NULL,
    realty_type character varying NOT NULL,
    price bigint,
    price_per_sqm integer,
    area numeric(10,2),
    living_area numeric(10,2),
    rooms integer,
    floor integer,
    total_floors integer,
    building_year integer,
    building_type character varying,
    condition character varying,
    address character varying,
    city character varying,
    district character varying,
    latitude double precision,
    longitude double precision,
    metro_station character varying,
    metro_distance integer,
    has_balcony boolean DEFAULT false,
    has_loggia boolean DEFAULT false,
    has_parking boolean DEFAULT false,
    has_elevator boolean DEFAULT false,
    url character varying,
    listed_at timestamp(6) without time zone,
    synced_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: mls_listings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mls_listings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mls_listings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mls_listings_id_seq OWNED BY public.mls_listings.id;


--
-- Name: nextcloud_share_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nextcloud_share_links (
    id bigint NOT NULL,
    path_sha256 character varying(64) NOT NULL,
    path text NOT NULL,
    share_url character varying NOT NULL,
    share_token character varying,
    password character varying,
    nc_share_id integer,
    expires_at timestamp(6) without time zone,
    created_by_id bigint,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: nextcloud_share_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.nextcloud_share_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nextcloud_share_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.nextcloud_share_links_id_seq OWNED BY public.nextcloud_share_links.id;


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id bigint NOT NULL,
    notable_type character varying NOT NULL,
    notable_id bigint NOT NULL,
    crm_note_id bigint,
    crm_user_id bigint,
    user_id bigint,
    note text NOT NULL,
    sync_state character varying DEFAULT 'pending'::character varying NOT NULL,
    synced_at timestamp(6) without time zone,
    crm_entity_type character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notes_id_seq OWNED BY public.notes.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    kind character varying NOT NULL,
    title character varying NOT NULL,
    body text,
    url character varying,
    notifiable_type character varying,
    notifiable_id bigint,
    read_at timestamp(6) without time zone,
    archived_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: partner_agencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partner_agencies (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    feed_source_key character varying,
    contact_email character varying,
    contact_phone character varying,
    contact_person character varying,
    default_commission_rate numeric(5,4),
    settlement_terms character varying,
    notes text,
    status character varying DEFAULT 'active'::character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    last_login_at timestamp(6) without time zone
);


--
-- Name: partner_agencies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.partner_agencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: partner_agencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.partner_agencies_id_seq OWNED BY public.partner_agencies.id;


--
-- Name: phone_stop_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_stop_lists (
    id bigint NOT NULL,
    phone_last10 character varying(10) NOT NULL,
    reason character varying(500) NOT NULL,
    added_by character varying(60) NOT NULL,
    added_by_user_id bigint,
    source_note text,
    expires_at timestamp(6) without time zone,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: phone_stop_lists_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.phone_stop_lists_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phone_stop_lists_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.phone_stop_lists_id_seq OWNED BY public.phone_stop_lists.id;


--
-- Name: price_histories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_histories (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    changed_by_id bigint,
    old_price numeric(15,2),
    new_price numeric(15,2) NOT NULL,
    price_change numeric(15,2),
    price_change_percent numeric(5,2),
    change_type character varying NOT NULL,
    reason text,
    notes text,
    effective_date timestamp(6) without time zone NOT NULL,
    auto_generated boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: price_histories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.price_histories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: price_histories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.price_histories_id_seq OWNED BY public.price_histories.id;


--
-- Name: properties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.properties (
    id bigint NOT NULL,
    title character varying NOT NULL,
    description text,
    slug character varying,
    price numeric(15,2) NOT NULL,
    price_per_sqm numeric(10,2),
    deal_type integer DEFAULT 0 NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    user_id bigint NOT NULL,
    property_type_id bigint,
    area numeric(10,2),
    living_area numeric(10,2),
    kitchen_area numeric(10,2),
    rooms integer,
    bedrooms integer,
    bathrooms integer,
    floor integer,
    total_floors integer,
    building_year integer,
    building_type character varying,
    condition integer DEFAULT 1,
    address character varying NOT NULL,
    district character varying,
    metro_station character varying,
    metro_distance integer,
    metro_transport character varying,
    latitude numeric(10,6),
    longitude numeric(10,6),
    has_balcony boolean DEFAULT false,
    has_loggia boolean DEFAULT false,
    has_parking boolean DEFAULT false,
    has_elevator boolean DEFAULT false,
    has_garbage_chute boolean DEFAULT false,
    has_security boolean DEFAULT false,
    has_concierge boolean DEFAULT false,
    pets_allowed boolean DEFAULT false,
    has_gas boolean DEFAULT false,
    has_water boolean DEFAULT true,
    has_electricity boolean DEFAULT true,
    has_heating boolean DEFAULT true,
    ceiling_height character varying,
    window_view character varying,
    furniture character varying,
    appliances character varying,
    ownership_type character varying,
    owners_count integer,
    encumbrance boolean DEFAULT false,
    mortgage_allowed boolean DEFAULT true,
    video_url character varying,
    virtual_tour_url character varying,
    images_count integer DEFAULT 0,
    views_count integer DEFAULT 0 NOT NULL,
    favorites_count integer DEFAULT 0 NOT NULL,
    inquiries_count integer DEFAULT 0 NOT NULL,
    phone_views_count integer DEFAULT 0 NOT NULL,
    original_price numeric(15,2),
    price_changed_at timestamp(6) without time zone,
    meta_title character varying,
    meta_description text,
    meta_keywords character varying,
    published_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    is_featured boolean DEFAULT false,
    featured_order integer DEFAULT 0,
    moderated_at timestamp(6) without time zone,
    moderated_by_id bigint,
    moderation_notes text,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    external_source character varying,
    external_id character varying,
    synced_at timestamp(6) without time zone,
    deal_state character varying,
    geom public.geography(Point,4326),
    land_area_m2 numeric(10,2),
    closed_at timestamp(6) without time zone,
    in_ad boolean DEFAULT false NOT NULL,
    in_mls boolean DEFAULT false NOT NULL,
    owner_user_id bigint,
    force_publish boolean DEFAULT false NOT NULL,
    seo_title character varying(90),
    seo_description text,
    seo_h1 character varying(120),
    seo_generated_at timestamp(6) without time zone,
    seo_model character varying(100),
    is_premium boolean DEFAULT false NOT NULL,
    city character varying,
    force_archive boolean DEFAULT false NOT NULL,
    signed_agency_contract_at timestamp(6) without time zone,
    commercial_type character varying,
    residential_complex_id bigint
);


--
-- Name: properties_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.properties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: properties_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.properties_id_seq OWNED BY public.properties.id;


--
-- Name: property_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_embeddings (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    content_hash character varying(64) NOT NULL,
    content_text text NOT NULL,
    embedding public.vector(768) NOT NULL,
    embedded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: property_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.property_embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.property_embeddings_id_seq OWNED BY public.property_embeddings.id;


--
-- Name: property_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_types (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    description text,
    icon character varying,
    "position" integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    properties_count integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: property_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.property_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.property_types_id_seq OWNED BY public.property_types.id;


--
-- Name: property_valuation_report_number_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.property_valuation_report_number_seq
    START WITH 10001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_valuations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_valuations (
    id bigint NOT NULL,
    user_id bigint,
    property_type character varying NOT NULL,
    deal_type character varying NOT NULL,
    address character varying NOT NULL,
    city character varying,
    district character varying,
    total_area numeric(8,2),
    living_area numeric(8,2),
    kitchen_area numeric(8,2),
    rooms integer,
    floor integer,
    total_floors integer,
    building_type character varying,
    building_year integer,
    condition character varying,
    has_balcony boolean DEFAULT false,
    has_loggia boolean DEFAULT false,
    has_garage boolean DEFAULT false,
    metro_station character varying,
    metro_distance integer,
    latitude numeric(10,6),
    longitude numeric(10,6),
    estimated_price numeric(12,2),
    min_price numeric(12,2),
    max_price numeric(12,2),
    confidence_level numeric(3,2),
    evaluation_data jsonb DEFAULT '{}'::jsonb,
    name character varying,
    email character varying,
    phone character varying,
    description text,
    token character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    ip_address character varying,
    user_agent character varying,
    call_requested boolean DEFAULT false,
    call_requested_at timestamp(6) without time zone,
    viewed_at timestamp(6) without time zone,
    views_count integer DEFAULT 0,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    land_area numeric(10,2),
    land_category character varying,
    ownership_type character varying,
    audit_mode character varying DEFAULT 'express'::character varying NOT NULL,
    audit_engine_id uuid,
    hedonic_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    report_number bigint DEFAULT nextval('public.property_valuation_report_number_seq'::regclass) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    staff_test boolean DEFAULT false NOT NULL,
    staff_test_matched_by character varying(64)
);


--
-- Name: property_valuations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.property_valuations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_valuations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.property_valuations_id_seq OWNED BY public.property_valuations.id;


--
-- Name: property_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_views (
    id bigint NOT NULL,
    user_id bigint,
    property_id bigint NOT NULL,
    viewed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    duration_seconds integer,
    ip_address character varying,
    user_agent character varying,
    referrer_url character varying,
    session_id character varying,
    device_type character varying,
    browser character varying,
    os character varying,
    source character varying,
    utm_source character varying,
    utm_medium character varying,
    utm_campaign character varying,
    utm_term character varying,
    utm_content character varying,
    viewed_phone boolean DEFAULT false,
    viewed_images boolean DEFAULT false,
    viewed_map boolean DEFAULT false,
    viewed_virtual_tour boolean DEFAULT false,
    images_viewed_count integer DEFAULT 0,
    contacted_owner boolean DEFAULT false,
    added_to_favorites boolean DEFAULT false,
    shared boolean DEFAULT false,
    country_code character varying,
    city character varying,
    latitude numeric(10,6),
    longitude numeric(10,6),
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: property_views_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.property_views_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: property_views_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.property_views_id_seq OWNED BY public.property_views.id;


--
-- Name: referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referrals (
    id bigint NOT NULL,
    inquiry_id bigint NOT NULL,
    partner_agency_id bigint NOT NULL,
    external_listing_id bigint,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    commission_rate numeric(5,4),
    final_commission_amount numeric(12,2),
    forwarded_at timestamp(6) without time zone,
    closed_at timestamp(6) without time zone,
    agent_notes text,
    metadata jsonb DEFAULT '{}'::jsonb,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: referrals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.referrals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: referrals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.referrals_id_seq OWNED BY public.referrals.id;


--
-- Name: residential_complexes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.residential_complexes (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying,
    city character varying DEFAULT 'Рязань'::character varying NOT NULL,
    district_slug character varying,
    developer character varying,
    address character varying,
    address_patterns character varying[] DEFAULT '{}'::character varying[],
    latitude numeric(10,6),
    longitude numeric(10,6),
    built_from integer,
    built_to integer,
    buildings_count integer,
    floors_min integer,
    floors_max integer,
    wall_material character varying,
    housing_class integer,
    build_status integer,
    has_parking boolean DEFAULT false NOT NULL,
    has_closed_yard boolean DEFAULT false NOT NULL,
    has_playground boolean DEFAULT false NOT NULL,
    has_kindergarten boolean DEFAULT false NOT NULL,
    has_school boolean DEFAULT false NOT NULL,
    title character varying,
    meta_description character varying(300),
    body_blocks jsonb DEFAULT '[]'::jsonb,
    body_html text,
    body_plain text,
    published boolean DEFAULT false NOT NULL,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: residential_complexes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.residential_complexes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: residential_complexes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.residential_complexes_id_seq OWNED BY public.residential_complexes.id;


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    id bigint NOT NULL,
    user_id bigint,
    property_id bigint,
    agent_id bigint,
    review_type integer DEFAULT 0 NOT NULL,
    rating integer NOT NULL,
    location_rating integer,
    value_rating integer,
    condition_rating integer,
    communication_rating integer,
    professionalism_rating integer,
    title character varying,
    body text NOT NULL,
    pros text,
    cons text,
    status integer DEFAULT 0 NOT NULL,
    moderated_by_id bigint,
    moderated_at timestamp(6) without time zone,
    moderation_notes text,
    rejection_reason character varying,
    response text,
    responded_by_id bigint,
    responded_at timestamp(6) without time zone,
    verified_purchase boolean DEFAULT false,
    verified_client boolean DEFAULT false,
    helpful_count integer DEFAULT 0 NOT NULL,
    not_helpful_count integer DEFAULT 0 NOT NULL,
    images_count integer DEFAULT 0 NOT NULL,
    reports_count integer DEFAULT 0 NOT NULL,
    flagged boolean DEFAULT false,
    visible boolean DEFAULT true NOT NULL,
    featured boolean DEFAULT false NOT NULL,
    ip_address character varying,
    user_agent character varying,
    source character varying DEFAULT 'own'::character varying,
    deal_date date,
    transaction_id character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    published_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    external_url character varying,
    author_name character varying,
    author_email character varying,
    author_phone character varying,
    submitted_via character varying,
    CONSTRAINT reviews_condition_rating_range CHECK (((condition_rating IS NULL) OR ((condition_rating >= 1) AND (condition_rating <= 5)))),
    CONSTRAINT reviews_location_rating_range CHECK (((location_rating IS NULL) OR ((location_rating >= 1) AND (location_rating <= 5)))),
    CONSTRAINT reviews_rating_range CHECK (((rating >= 1) AND (rating <= 5))),
    CONSTRAINT reviews_value_rating_range CHECK (((value_rating IS NULL) OR ((value_rating >= 1) AND (value_rating <= 5))))
);


--
-- Name: reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reviews_id_seq OWNED BY public.reviews.id;


--
-- Name: saved_searches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_searches (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    filters jsonb DEFAULT '{}'::jsonb NOT NULL,
    search_url text,
    active boolean DEFAULT true NOT NULL,
    notify_enabled boolean DEFAULT true NOT NULL,
    notification_frequency integer DEFAULT 0 NOT NULL,
    last_checked_at timestamp(6) without time zone,
    last_notification_sent_at timestamp(6) without time zone,
    results_count integer DEFAULT 0 NOT NULL,
    new_results_count integer DEFAULT 0 NOT NULL,
    last_results_count_updated_at timestamp(6) without time zone,
    clicks_count integer DEFAULT 0 NOT NULL,
    last_used_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: saved_searches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.saved_searches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: saved_searches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.saved_searches_id_seq OWNED BY public.saved_searches.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: service_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_orders (
    id bigint NOT NULL,
    crm_id bigint NOT NULL,
    service_type_id bigint NOT NULL,
    user_id bigint,
    client_name character varying,
    client_phone_masked character varying,
    stage_name character varying,
    deal_state character varying,
    fc_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: service_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_orders_id_seq OWNED BY public.service_orders.id;


--
-- Name: service_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_types (
    id bigint NOT NULL,
    crm_type_id bigint,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    description text,
    category character varying,
    icon character varying,
    order_position integer DEFAULT 0,
    public_visible boolean DEFAULT true NOT NULL,
    active boolean DEFAULT true NOT NULL,
    cta_label character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    target_path character varying
);


--
-- Name: service_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_types_id_seq OWNED BY public.service_types.id;


--
-- Name: staff_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_metrics (
    id bigint NOT NULL,
    staff_id bigint NOT NULL,
    date date NOT NULL,
    tasks_assigned integer DEFAULT 0 NOT NULL,
    tasks_completed integer DEFAULT 0 NOT NULL,
    tasks_on_time integer DEFAULT 0 NOT NULL,
    tasks_overdue integer DEFAULT 0 NOT NULL,
    avg_completion_time_sec integer DEFAULT 0 NOT NULL,
    suspicious_completions integer DEFAULT 0 NOT NULL,
    questions_asked integer DEFAULT 0 NOT NULL,
    leads_assigned integer DEFAULT 0 NOT NULL,
    leads_first_contact_in_30m integer DEFAULT 0 NOT NULL,
    leads_converted integer DEFAULT 0 NOT NULL,
    documents_uploaded integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: staff_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.staff_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: staff_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.staff_metrics_id_seq OWNED BY public.staff_metrics.id;


--
-- Name: staff_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_questions (
    id bigint NOT NULL,
    asked_by_id bigint NOT NULL,
    related_task_id bigint,
    related_lead_event_id bigint,
    kind character varying,
    question_text text NOT NULL,
    answer_text text,
    answered_by_id bigint,
    escalated_to_id bigint,
    tg_message_id bigint,
    tg_chat_id bigint,
    tg_thread_id bigint,
    llm_model character varying,
    classifier_confidence double precision,
    answered_at timestamp(6) without time zone,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: staff_questions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.staff_questions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: staff_questions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.staff_questions_id_seq OWNED BY public.staff_questions.id;


--
-- Name: task_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_batches (
    id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    source character varying DEFAULT 'voice'::character varying NOT NULL,
    transcript_redacted text,
    parsed_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'pending_confirm'::character varying NOT NULL,
    preview_message_id bigint,
    preview_chat_id bigint,
    confirmed_at timestamp(6) without time zone,
    cancelled_at timestamp(6) without time zone,
    expired_at timestamp(6) without time zone,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: task_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.task_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: task_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.task_batches_id_seq OWNED BY public.task_batches.id;


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id bigint NOT NULL,
    topnlab_id bigint,
    topnlab_type character varying,
    lead_event_id bigint,
    assignee_id bigint,
    created_by_id bigint,
    title character varying NOT NULL,
    due_at timestamp(6) without time zone,
    status character varying DEFAULT 'open'::character varying NOT NULL,
    tg_message_id bigint,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    last_pinged_at timestamp(6) without time zone,
    assigned_at timestamp(6) without time zone,
    notified_at timestamp(6) without time zone,
    first_acked_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    acked_method character varying,
    task_batch_id bigint,
    priority character varying DEFAULT 'normal'::character varying NOT NULL,
    kind character varying DEFAULT 'other'::character varying NOT NULL,
    suspicious_flag boolean DEFAULT false NOT NULL,
    attachments jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tasks_id_seq OWNED BY public.tasks.id;


--
-- Name: telegram_group_message_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_group_message_embeddings (
    id bigint NOT NULL,
    telegram_group_message_id bigint NOT NULL,
    content_hash character varying(64) NOT NULL,
    embedded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    embedding public.vector(768) NOT NULL
);


--
-- Name: telegram_group_message_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.telegram_group_message_embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: telegram_group_message_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.telegram_group_message_embeddings_id_seq OWNED BY public.telegram_group_message_embeddings.id;


--
-- Name: telegram_group_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_group_messages (
    id bigint NOT NULL,
    tg_chat_id bigint NOT NULL,
    tg_message_id bigint NOT NULL,
    tg_thread_id bigint,
    tg_user_id bigint,
    sender_username character varying(64),
    sender_first_name character varying(120),
    body text,
    payload_kind character varying(16) DEFAULT 'text'::character varying NOT NULL,
    has_attachment boolean DEFAULT false NOT NULL,
    reply_to_tg_message_id bigint,
    sent_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    body_tsv tsvector GENERATED ALWAYS AS (to_tsvector('russian'::regconfig, COALESCE(body, ''::text))) STORED
);


--
-- Name: telegram_group_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.telegram_group_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: telegram_group_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.telegram_group_messages_id_seq OWNED BY public.telegram_group_messages.id;


--
-- Name: telegram_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_users (
    id bigint NOT NULL,
    tg_user_id bigint NOT NULL,
    tg_username character varying,
    topnlab_user_id bigint,
    email character varying,
    first_name character varying,
    last_name character varying,
    is_manager boolean DEFAULT false NOT NULL,
    dm_chat_id bigint,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    last_seen_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    role character varying DEFAULT 'agent'::character varying NOT NULL,
    assignable boolean DEFAULT true NOT NULL,
    dm_pending_action jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: telegram_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.telegram_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: telegram_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.telegram_users_id_seq OWNED BY public.telegram_users.id;


--
-- Name: telegram_webhook_acks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telegram_webhook_acks (
    id bigint NOT NULL,
    update_id bigint NOT NULL,
    processed_at timestamp(6) without time zone NOT NULL
);


--
-- Name: telegram_webhook_acks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.telegram_webhook_acks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: telegram_webhook_acks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.telegram_webhook_acks_id_seq OWNED BY public.telegram_webhook_acks.id;


--
-- Name: tg_link_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tg_link_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token character varying(64) NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    consumed_at timestamp(6) without time zone,
    ip_address character varying(45),
    user_agent character varying(255),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source character varying(32)
);


--
-- Name: tg_link_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tg_link_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tg_link_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tg_link_tokens_id_seq OWNED BY public.tg_link_tokens.id;


--
-- Name: topnlab_doc_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topnlab_doc_chunks (
    id bigint NOT NULL,
    source_file character varying NOT NULL,
    chunk_index integer NOT NULL,
    section_title character varying,
    line_start integer,
    chunk_text text NOT NULL,
    content_hash character varying NOT NULL,
    embedding public.vector(768) NOT NULL,
    embedded_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: topnlab_doc_chunks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.topnlab_doc_chunks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: topnlab_doc_chunks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.topnlab_doc_chunks_id_seq OWNED BY public.topnlab_doc_chunks.id;


--
-- Name: topnlab_sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topnlab_sync_runs (
    id bigint NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    ids_seen integer DEFAULT 0,
    upserted integer DEFAULT 0,
    archived integer DEFAULT 0,
    photos_pending integer DEFAULT 0,
    error_log text,
    status character varying DEFAULT 'running'::character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: topnlab_sync_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.topnlab_sync_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: topnlab_sync_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.topnlab_sync_runs_id_seq OWNED BY public.topnlab_sync_runs.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp(6) without time zone,
    remember_created_at timestamp(6) without time zone,
    sign_in_count integer DEFAULT 0 NOT NULL,
    current_sign_in_at timestamp(6) without time zone,
    last_sign_in_at timestamp(6) without time zone,
    current_sign_in_ip character varying,
    last_sign_in_ip character varying,
    confirmation_token character varying,
    confirmed_at timestamp(6) without time zone,
    confirmation_sent_at timestamp(6) without time zone,
    unconfirmed_email character varying,
    failed_attempts integer DEFAULT 0 NOT NULL,
    unlock_token character varying,
    locked_at timestamp(6) without time zone,
    first_name character varying,
    last_name character varying,
    phone character varying,
    avatar_url character varying,
    role integer DEFAULT 0 NOT NULL,
    provider character varying,
    uid character varying,
    bio text,
    company character varying,
    "position" character varying,
    notification_settings jsonb DEFAULT '{}'::jsonb,
    preferences jsonb DEFAULT '{}'::jsonb,
    properties_count integer DEFAULT 0 NOT NULL,
    inquiries_count integer DEFAULT 0 NOT NULL,
    favorites_count integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    last_activity_at timestamp(6) without time zone,
    deleted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    crm_user_id bigint,
    crm_role_id character varying,
    crm_role_name character varying,
    crm_status character varying,
    department_id bigint,
    is_chief boolean DEFAULT false NOT NULL,
    middle_name character varying,
    crm_synced_at timestamp(6) without time zone,
    agent_slug character varying,
    deals_closed_count integer DEFAULT 0 NOT NULL,
    response_time_minutes integer,
    languages jsonb DEFAULT '[]'::jsonb,
    specialties jsonb DEFAULT '[]'::jsonb,
    license_no character varying,
    invited_at timestamp(6) without time zone,
    tg_user_id bigint,
    tg_username character varying(64),
    tg_linked_at timestamp(6) without time zone,
    public_profile_hidden_at timestamp(6) without time zone
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: viewing_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.viewing_schedules (
    id bigint NOT NULL,
    property_id bigint NOT NULL,
    user_id bigint NOT NULL,
    agent_id bigint,
    inquiry_id bigint,
    scheduled_at timestamp(6) without time zone NOT NULL,
    ends_at timestamp(6) without time zone,
    duration integer DEFAULT 60,
    name character varying NOT NULL,
    phone character varying NOT NULL,
    email character varying,
    notes text,
    agent_notes text,
    viewing_type character varying DEFAULT 'in_person'::character varying,
    meeting_link character varying,
    status character varying DEFAULT 'scheduled'::character varying NOT NULL,
    reminder_sent boolean DEFAULT false NOT NULL,
    reminder_sent_at timestamp(6) without time zone,
    confirmed_at timestamp(6) without time zone,
    confirmation_token character varying,
    completed_at timestamp(6) without time zone,
    completion_notes text,
    rating integer,
    feedback text,
    cancelled_at timestamp(6) without time zone,
    cancellation_reason character varying,
    cancellation_notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    deleted_at timestamp(6) without time zone
);


--
-- Name: viewing_schedules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.viewing_schedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: viewing_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.viewing_schedules_id_seq OWNED BY public.viewing_schedules.id;


--
-- Name: activation_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activation_events ALTER COLUMN id SET DEFAULT nextval('public.activation_events_id_seq'::regclass);


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: article_embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.article_embeddings ALTER COLUMN id SET DEFAULT nextval('public.article_embeddings_id_seq'::regclass);


--
-- Name: articles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.articles ALTER COLUMN id SET DEFAULT nextval('public.articles_id_seq'::regclass);


--
-- Name: bank_rate_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_rate_snapshots ALTER COLUMN id SET DEFAULT nextval('public.bank_rate_snapshots_id_seq'::regclass);


--
-- Name: bot_command_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bot_command_logs ALTER COLUMN id SET DEFAULT nextval('public.bot_command_logs_id_seq'::regclass);


--
-- Name: buyer_orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buyer_orders ALTER COLUMN id SET DEFAULT nextval('public.buyer_orders_id_seq'::regclass);


--
-- Name: case_studies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_studies ALTER COLUMN id SET DEFAULT nextval('public.case_studies_id_seq'::regclass);


--
-- Name: chat_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages ALTER COLUMN id SET DEFAULT nextval('public.chat_messages_id_seq'::regclass);


--
-- Name: city_median_prices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.city_median_prices ALTER COLUMN id SET DEFAULT nextval('public.city_median_prices_id_seq'::regclass);


--
-- Name: client_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_documents ALTER COLUMN id SET DEFAULT nextval('public.client_documents_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: crm_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crm_reports ALTER COLUMN id SET DEFAULT nextval('public.crm_reports_id_seq'::regclass);


--
-- Name: daily_digests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_digests ALTER COLUMN id SET DEFAULT nextval('public.daily_digests_id_seq'::regclass);


--
-- Name: departments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments ALTER COLUMN id SET DEFAULT nextval('public.departments_id_seq'::regclass);


--
-- Name: districts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.districts ALTER COLUMN id SET DEFAULT nextval('public.districts_id_seq'::regclass);


--
-- Name: document_requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_requirements ALTER COLUMN id SET DEFAULT nextval('public.document_requirements_id_seq'::regclass);


--
-- Name: document_uploads id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_uploads ALTER COLUMN id SET DEFAULT nextval('public.document_uploads_id_seq'::regclass);


--
-- Name: documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents ALTER COLUMN id SET DEFAULT nextval('public.documents_id_seq'::regclass);


--
-- Name: external_listings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_listings ALTER COLUMN id SET DEFAULT nextval('public.external_listings_id_seq'::regclass);


--
-- Name: favorites id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorites ALTER COLUMN id SET DEFAULT nextval('public.favorites_id_seq'::regclass);


--
-- Name: friendly_id_slugs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs ALTER COLUMN id SET DEFAULT nextval('public.friendly_id_slugs_id_seq'::regclass);


--
-- Name: inquiries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries ALTER COLUMN id SET DEFAULT nextval('public.inquiries_id_seq'::regclass);


--
-- Name: landing_contents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.landing_contents ALTER COLUMN id SET DEFAULT nextval('public.landing_contents_id_seq'::regclass);


--
-- Name: lead_event_embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_event_embeddings ALTER COLUMN id SET DEFAULT nextval('public.lead_event_embeddings_id_seq'::regclass);


--
-- Name: lead_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events ALTER COLUMN id SET DEFAULT nextval('public.lead_events_id_seq'::regclass);


--
-- Name: listing_consents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_consents ALTER COLUMN id SET DEFAULT nextval('public.listing_consents_id_seq'::regclass);


--
-- Name: magic_link_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.magic_link_tokens ALTER COLUMN id SET DEFAULT nextval('public.magic_link_tokens_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: mls_listings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mls_listings ALTER COLUMN id SET DEFAULT nextval('public.mls_listings_id_seq'::regclass);


--
-- Name: nextcloud_share_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nextcloud_share_links ALTER COLUMN id SET DEFAULT nextval('public.nextcloud_share_links_id_seq'::regclass);


--
-- Name: notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes ALTER COLUMN id SET DEFAULT nextval('public.notes_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: partner_agencies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_agencies ALTER COLUMN id SET DEFAULT nextval('public.partner_agencies_id_seq'::regclass);


--
-- Name: phone_stop_lists id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_stop_lists ALTER COLUMN id SET DEFAULT nextval('public.phone_stop_lists_id_seq'::regclass);


--
-- Name: price_histories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_histories ALTER COLUMN id SET DEFAULT nextval('public.price_histories_id_seq'::regclass);


--
-- Name: properties id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties ALTER COLUMN id SET DEFAULT nextval('public.properties_id_seq'::regclass);


--
-- Name: property_embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_embeddings ALTER COLUMN id SET DEFAULT nextval('public.property_embeddings_id_seq'::regclass);


--
-- Name: property_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_types ALTER COLUMN id SET DEFAULT nextval('public.property_types_id_seq'::regclass);


--
-- Name: property_valuations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_valuations ALTER COLUMN id SET DEFAULT nextval('public.property_valuations_id_seq'::regclass);


--
-- Name: property_views id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_views ALTER COLUMN id SET DEFAULT nextval('public.property_views_id_seq'::regclass);


--
-- Name: referrals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals ALTER COLUMN id SET DEFAULT nextval('public.referrals_id_seq'::regclass);


--
-- Name: residential_complexes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residential_complexes ALTER COLUMN id SET DEFAULT nextval('public.residential_complexes_id_seq'::regclass);


--
-- Name: reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews ALTER COLUMN id SET DEFAULT nextval('public.reviews_id_seq'::regclass);


--
-- Name: saved_searches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_searches ALTER COLUMN id SET DEFAULT nextval('public.saved_searches_id_seq'::regclass);


--
-- Name: service_orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_orders ALTER COLUMN id SET DEFAULT nextval('public.service_orders_id_seq'::regclass);


--
-- Name: service_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_types ALTER COLUMN id SET DEFAULT nextval('public.service_types_id_seq'::regclass);


--
-- Name: staff_metrics id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_metrics ALTER COLUMN id SET DEFAULT nextval('public.staff_metrics_id_seq'::regclass);


--
-- Name: staff_questions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_questions ALTER COLUMN id SET DEFAULT nextval('public.staff_questions_id_seq'::regclass);


--
-- Name: task_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_batches ALTER COLUMN id SET DEFAULT nextval('public.task_batches_id_seq'::regclass);


--
-- Name: tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks ALTER COLUMN id SET DEFAULT nextval('public.tasks_id_seq'::regclass);


--
-- Name: telegram_group_message_embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_group_message_embeddings ALTER COLUMN id SET DEFAULT nextval('public.telegram_group_message_embeddings_id_seq'::regclass);


--
-- Name: telegram_group_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_group_messages ALTER COLUMN id SET DEFAULT nextval('public.telegram_group_messages_id_seq'::regclass);


--
-- Name: telegram_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_users ALTER COLUMN id SET DEFAULT nextval('public.telegram_users_id_seq'::regclass);


--
-- Name: telegram_webhook_acks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_webhook_acks ALTER COLUMN id SET DEFAULT nextval('public.telegram_webhook_acks_id_seq'::regclass);


--
-- Name: tg_link_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tg_link_tokens ALTER COLUMN id SET DEFAULT nextval('public.tg_link_tokens_id_seq'::regclass);


--
-- Name: topnlab_doc_chunks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topnlab_doc_chunks ALTER COLUMN id SET DEFAULT nextval('public.topnlab_doc_chunks_id_seq'::regclass);


--
-- Name: topnlab_sync_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topnlab_sync_runs ALTER COLUMN id SET DEFAULT nextval('public.topnlab_sync_runs_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: viewing_schedules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules ALTER COLUMN id SET DEFAULT nextval('public.viewing_schedules_id_seq'::regclass);


--
-- Name: activation_events activation_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activation_events
    ADD CONSTRAINT activation_events_pkey PRIMARY KEY (id);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: article_embeddings article_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.article_embeddings
    ADD CONSTRAINT article_embeddings_pkey PRIMARY KEY (id);


--
-- Name: articles articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.articles
    ADD CONSTRAINT articles_pkey PRIMARY KEY (id);


--
-- Name: bank_rate_snapshots bank_rate_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_rate_snapshots
    ADD CONSTRAINT bank_rate_snapshots_pkey PRIMARY KEY (id);


--
-- Name: bot_command_logs bot_command_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bot_command_logs
    ADD CONSTRAINT bot_command_logs_pkey PRIMARY KEY (id);


--
-- Name: buyer_orders buyer_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buyer_orders
    ADD CONSTRAINT buyer_orders_pkey PRIMARY KEY (id);


--
-- Name: case_studies case_studies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_studies
    ADD CONSTRAINT case_studies_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: city_median_prices city_median_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.city_median_prices
    ADD CONSTRAINT city_median_prices_pkey PRIMARY KEY (id);


--
-- Name: client_documents client_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_documents
    ADD CONSTRAINT client_documents_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: crm_reports crm_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crm_reports
    ADD CONSTRAINT crm_reports_pkey PRIMARY KEY (id);


--
-- Name: daily_digests daily_digests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_digests
    ADD CONSTRAINT daily_digests_pkey PRIMARY KEY (id);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: districts districts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.districts
    ADD CONSTRAINT districts_pkey PRIMARY KEY (id);


--
-- Name: document_requirements document_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_requirements
    ADD CONSTRAINT document_requirements_pkey PRIMARY KEY (id);


--
-- Name: document_uploads document_uploads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_uploads
    ADD CONSTRAINT document_uploads_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: external_listings external_listings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_listings
    ADD CONSTRAINT external_listings_pkey PRIMARY KEY (id);


--
-- Name: favorites favorites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT favorites_pkey PRIMARY KEY (id);


--
-- Name: friendly_id_slugs friendly_id_slugs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendly_id_slugs
    ADD CONSTRAINT friendly_id_slugs_pkey PRIMARY KEY (id);


--
-- Name: inquiries inquiries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT inquiries_pkey PRIMARY KEY (id);


--
-- Name: landing_contents landing_contents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.landing_contents
    ADD CONSTRAINT landing_contents_pkey PRIMARY KEY (id);


--
-- Name: lead_event_embeddings lead_event_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_event_embeddings
    ADD CONSTRAINT lead_event_embeddings_pkey PRIMARY KEY (id);


--
-- Name: lead_events lead_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT lead_events_pkey PRIMARY KEY (id);


--
-- Name: listing_consents listing_consents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_consents
    ADD CONSTRAINT listing_consents_pkey PRIMARY KEY (id);


--
-- Name: magic_link_tokens magic_link_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.magic_link_tokens
    ADD CONSTRAINT magic_link_tokens_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: mls_listings mls_listings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mls_listings
    ADD CONSTRAINT mls_listings_pkey PRIMARY KEY (id);


--
-- Name: nextcloud_share_links nextcloud_share_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nextcloud_share_links
    ADD CONSTRAINT nextcloud_share_links_pkey PRIMARY KEY (id);


--
-- Name: notes notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: partner_agencies partner_agencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_agencies
    ADD CONSTRAINT partner_agencies_pkey PRIMARY KEY (id);


--
-- Name: phone_stop_lists phone_stop_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_stop_lists
    ADD CONSTRAINT phone_stop_lists_pkey PRIMARY KEY (id);


--
-- Name: price_histories price_histories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_histories
    ADD CONSTRAINT price_histories_pkey PRIMARY KEY (id);


--
-- Name: properties properties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT properties_pkey PRIMARY KEY (id);


--
-- Name: property_embeddings property_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_embeddings
    ADD CONSTRAINT property_embeddings_pkey PRIMARY KEY (id);


--
-- Name: property_types property_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_types
    ADD CONSTRAINT property_types_pkey PRIMARY KEY (id);


--
-- Name: property_valuations property_valuations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_valuations
    ADD CONSTRAINT property_valuations_pkey PRIMARY KEY (id);


--
-- Name: property_views property_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_views
    ADD CONSTRAINT property_views_pkey PRIMARY KEY (id);


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_pkey PRIMARY KEY (id);


--
-- Name: residential_complexes residential_complexes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.residential_complexes
    ADD CONSTRAINT residential_complexes_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: saved_searches saved_searches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_searches
    ADD CONSTRAINT saved_searches_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_orders service_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_orders
    ADD CONSTRAINT service_orders_pkey PRIMARY KEY (id);


--
-- Name: service_types service_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_types
    ADD CONSTRAINT service_types_pkey PRIMARY KEY (id);


--
-- Name: staff_metrics staff_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_metrics
    ADD CONSTRAINT staff_metrics_pkey PRIMARY KEY (id);


--
-- Name: staff_questions staff_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_questions
    ADD CONSTRAINT staff_questions_pkey PRIMARY KEY (id);


--
-- Name: task_batches task_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_batches
    ADD CONSTRAINT task_batches_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: telegram_group_message_embeddings telegram_group_message_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_group_message_embeddings
    ADD CONSTRAINT telegram_group_message_embeddings_pkey PRIMARY KEY (id);


--
-- Name: telegram_group_messages telegram_group_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_group_messages
    ADD CONSTRAINT telegram_group_messages_pkey PRIMARY KEY (id);


--
-- Name: telegram_users telegram_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_users
    ADD CONSTRAINT telegram_users_pkey PRIMARY KEY (id);


--
-- Name: telegram_webhook_acks telegram_webhook_acks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_webhook_acks
    ADD CONSTRAINT telegram_webhook_acks_pkey PRIMARY KEY (id);


--
-- Name: tg_link_tokens tg_link_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tg_link_tokens
    ADD CONSTRAINT tg_link_tokens_pkey PRIMARY KEY (id);


--
-- Name: topnlab_doc_chunks topnlab_doc_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topnlab_doc_chunks
    ADD CONSTRAINT topnlab_doc_chunks_pkey PRIMARY KEY (id);


--
-- Name: topnlab_sync_runs topnlab_sync_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topnlab_sync_runs
    ADD CONSTRAINT topnlab_sync_runs_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: viewing_schedules viewing_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules
    ADD CONSTRAINT viewing_schedules_pkey PRIMARY KEY (id);


--
-- Name: idx_article_embeddings_cosine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_article_embeddings_cosine ON public.article_embeddings USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_client_documents_nc_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_client_documents_nc_path ON public.client_documents USING btree (nextcloud_path) WHERE (nextcloud_path IS NOT NULL);


--
-- Name: idx_client_documents_tg_intake_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_client_documents_tg_intake_unique ON public.client_documents USING btree (tg_chat_id, tg_message_id) WHERE ((tg_chat_id IS NOT NULL) AND (tg_message_id IS NOT NULL));


--
-- Name: idx_daily_digests_active_per_day_chat; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_daily_digests_active_per_day_chat ON public.daily_digests USING btree (date, tg_chat_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_districts_boundary_gist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_districts_boundary_gist ON public.districts USING gist (boundary);


--
-- Name: idx_districts_city_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_districts_city_name ON public.districts USING btree (city, name);


--
-- Name: idx_doc_req_lead_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_req_lead_status ON public.document_requirements USING btree (lead_event_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_doc_req_sla_assessor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_req_sla_assessor ON public.document_requirements USING btree (status, requested_at) WHERE ((deleted_at IS NULL) AND ((status)::text = ANY ((ARRAY['requested'::character varying, 'received'::character varying])::text[])));


--
-- Name: idx_doc_req_unique_lead_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_doc_req_unique_lead_kind ON public.document_requirements USING btree (lead_event_id, kind) WHERE ((deleted_at IS NULL) AND (lead_event_id IS NOT NULL));


--
-- Name: idx_doc_req_unique_property_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_doc_req_unique_property_kind ON public.document_requirements USING btree (property_id, kind) WHERE ((deleted_at IS NULL) AND (property_id IS NOT NULL) AND (lead_event_id IS NULL));


--
-- Name: idx_doc_req_via_cd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_req_via_cd ON public.document_requirements USING btree (received_via_client_document_id);


--
-- Name: idx_inquiries_tg_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inquiries_tg_recent ON public.inquiries USING btree (client_tg_user_id, created_at) WHERE (client_tg_user_id IS NOT NULL);


--
-- Name: idx_landing_contents_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_landing_contents_uniq ON public.landing_contents USING btree (intent, type, district_slug, rooms);


--
-- Name: idx_lead_event_embeddings_vector_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lead_event_embeddings_vector_hnsw ON public.lead_event_embeddings USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: idx_lead_events_anchor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lead_events_anchor ON public.lead_events USING btree (anchor_thread_id, anchor_message_id);


--
-- Name: idx_lead_events_crm_sync_failed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lead_events_crm_sync_failed ON public.lead_events USING btree (crm_sync_failed) WHERE (crm_sync_failed = true);


--
-- Name: idx_lead_events_search_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lead_events_search_tsv ON public.lead_events USING gin (search_tsv);


--
-- Name: idx_nc_share_links_active_path; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_nc_share_links_active_path ON public.nextcloud_share_links USING btree (path_sha256) WHERE (deleted_at IS NULL);


--
-- Name: idx_on_district_property_type_deal_type_efc4ddb17d; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_district_property_type_deal_type_efc4ddb17d ON public.external_listings USING btree (district, property_type, deal_type);


--
-- Name: idx_on_telegram_group_message_id_95e1cb4d35; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_telegram_group_message_id_95e1cb4d35 ON public.telegram_group_message_embeddings USING btree (telegram_group_message_id);


--
-- Name: idx_properties_geom_gist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_properties_geom_gist ON public.properties USING gist (geom);


--
-- Name: idx_properties_seo_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_properties_seo_pending ON public.properties USING btree (seo_generated_at) WHERE (seo_generated_at IS NULL);


--
-- Name: idx_property_embeddings_cosine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_property_embeddings_cosine ON public.property_embeddings USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_property_valuations_audit_engine_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_property_valuations_audit_engine_id_unique ON public.property_valuations USING btree (audit_engine_id) WHERE (audit_engine_id IS NOT NULL);


--
-- Name: idx_tg_group_msg_body_tsv; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tg_group_msg_body_tsv ON public.telegram_group_messages USING gin (body_tsv);


--
-- Name: idx_tg_group_msg_chat_msg_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tg_group_msg_chat_msg_uniq ON public.telegram_group_messages USING btree (tg_chat_id, tg_message_id);


--
-- Name: idx_tgm_embeddings_vector_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tgm_embeddings_vector_hnsw ON public.telegram_group_message_embeddings USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: idx_topnlab_doc_chunks_cosine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_topnlab_doc_chunks_cosine ON public.topnlab_doc_chunks USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_topnlab_doc_chunks_source_pos; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_topnlab_doc_chunks_source_pos ON public.topnlab_doc_chunks USING btree (source_file, chunk_index);


--
-- Name: index_activation_events_on_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activation_events_on_channel ON public.activation_events USING btree (channel);


--
-- Name: index_activation_events_on_happened_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activation_events_on_happened_at ON public.activation_events USING btree (happened_at);


--
-- Name: index_activation_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activation_events_on_user_id ON public.activation_events USING btree (user_id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_article_embeddings_on_article_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_article_embeddings_on_article_id ON public.article_embeddings USING btree (article_id);


--
-- Name: index_articles_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_author_id ON public.articles USING btree (author_id);


--
-- Name: index_articles_on_category_and_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_category_and_published_at ON public.articles USING btree (category, published_at);


--
-- Name: index_articles_on_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_articles_on_external_id ON public.articles USING btree (external_id) WHERE (external_id IS NOT NULL);


--
-- Name: index_articles_on_hidden_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_hidden_at ON public.articles USING btree (hidden_at);


--
-- Name: index_articles_on_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_metadata ON public.articles USING gin (metadata);


--
-- Name: index_articles_on_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_published_at ON public.articles USING btree (published_at);


--
-- Name: index_articles_on_region_and_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_region_and_published_at ON public.articles USING btree (region, published_at);


--
-- Name: index_articles_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_articles_on_slug ON public.articles USING btree (slug);


--
-- Name: index_bank_rate_snapshots_on_kind_and_as_of; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_rate_snapshots_on_kind_and_as_of ON public.bank_rate_snapshots USING btree (kind, as_of);


--
-- Name: index_bank_rate_snapshots_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_rate_snapshots_on_status ON public.bank_rate_snapshots USING btree (status);


--
-- Name: index_bot_command_logs_on_command; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bot_command_logs_on_command ON public.bot_command_logs USING btree (command);


--
-- Name: index_bot_command_logs_on_result; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bot_command_logs_on_result ON public.bot_command_logs USING btree (result);


--
-- Name: index_bot_command_logs_on_tg_user_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bot_command_logs_on_tg_user_id_and_created_at ON public.bot_command_logs USING btree (tg_user_id, created_at);


--
-- Name: index_buyer_orders_on_client_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_client_crm_id ON public.buyer_orders USING btree (client_crm_id);


--
-- Name: index_buyer_orders_on_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_buyer_orders_on_crm_id ON public.buyer_orders USING btree (crm_id);


--
-- Name: index_buyer_orders_on_deal_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_deal_state ON public.buyer_orders USING btree (deal_state);


--
-- Name: index_buyer_orders_on_deal_type_and_realty_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_deal_type_and_realty_type ON public.buyer_orders USING btree (deal_type, realty_type);


--
-- Name: index_buyer_orders_on_preferred_cities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_preferred_cities ON public.buyer_orders USING gin (preferred_cities);


--
-- Name: index_buyer_orders_on_preferred_districts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_preferred_districts ON public.buyer_orders USING gin (preferred_districts);


--
-- Name: index_buyer_orders_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_buyer_orders_on_user_id ON public.buyer_orders USING btree (user_id);


--
-- Name: index_case_studies_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_author_id ON public.case_studies USING btree (author_id);


--
-- Name: index_case_studies_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_deleted_at ON public.case_studies USING btree (deleted_at);


--
-- Name: index_case_studies_on_district_and_property_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_district_and_property_type ON public.case_studies USING btree (district, property_type);


--
-- Name: index_case_studies_on_inquiry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_inquiry_id ON public.case_studies USING btree (inquiry_id);


--
-- Name: index_case_studies_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_property_id ON public.case_studies USING btree (property_id);


--
-- Name: index_case_studies_on_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_published_at ON public.case_studies USING btree (published_at);


--
-- Name: index_case_studies_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_case_studies_on_slug ON public.case_studies USING btree (slug);


--
-- Name: index_case_studies_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_case_studies_on_status ON public.case_studies USING btree (status);


--
-- Name: index_chat_messages_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_author_id ON public.chat_messages USING btree (author_id);


--
-- Name: index_chat_messages_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_conversation_id ON public.chat_messages USING btree (conversation_id);


--
-- Name: index_chat_messages_on_conversation_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_chat_messages_on_conversation_id_and_created_at ON public.chat_messages USING btree (conversation_id, created_at);


--
-- Name: index_city_median_prices_on_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_city_median_prices_on_city ON public.city_median_prices USING btree (city);


--
-- Name: index_city_median_prices_on_city_and_property_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_city_median_prices_on_city_and_property_type ON public.city_median_prices USING btree (city, property_type);


--
-- Name: index_client_documents_on_document_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_document_kind ON public.client_documents USING btree (document_kind);


--
-- Name: index_client_documents_on_inquiry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_inquiry_id ON public.client_documents USING btree (inquiry_id);


--
-- Name: index_client_documents_on_processed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_processed_at ON public.client_documents USING btree (processed_at);


--
-- Name: index_client_documents_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_property_id ON public.client_documents USING btree (property_id);


--
-- Name: index_client_documents_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_status ON public.client_documents USING btree (status);


--
-- Name: index_client_documents_on_tg_chat_id_and_tg_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_tg_chat_id_and_tg_message_id ON public.client_documents USING btree (tg_chat_id, tg_message_id);


--
-- Name: index_client_documents_on_uploader_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_client_documents_on_uploader_id ON public.client_documents USING btree (uploader_id);


--
-- Name: index_conversations_on_assigned_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_assigned_user_id ON public.conversations USING btree (assigned_user_id);


--
-- Name: index_conversations_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_status ON public.conversations USING btree (status);


--
-- Name: index_conversations_on_telegram_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversations_on_telegram_message_id ON public.conversations USING btree (telegram_message_id) WHERE (telegram_message_id IS NOT NULL);


--
-- Name: index_conversations_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_user_id ON public.conversations USING btree (user_id);


--
-- Name: index_conversations_on_visitor_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_visitor_token ON public.conversations USING btree (visitor_token);


--
-- Name: index_crm_reports_on_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crm_reports_on_crm_id ON public.crm_reports USING btree (crm_id) WHERE (crm_id IS NOT NULL);


--
-- Name: index_crm_reports_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_crm_reports_on_slug ON public.crm_reports USING btree (slug);


--
-- Name: index_daily_digests_on_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_daily_digests_on_date ON public.daily_digests USING btree (date);


--
-- Name: index_daily_digests_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_daily_digests_on_deleted_at ON public.daily_digests USING btree (deleted_at);


--
-- Name: index_departments_on_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_departments_on_crm_id ON public.departments USING btree (crm_id);


--
-- Name: index_departments_on_crm_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_departments_on_crm_parent_id ON public.departments USING btree (crm_parent_id);


--
-- Name: index_document_requirements_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_approved_by_id ON public.document_requirements USING btree (approved_by_id);


--
-- Name: index_document_requirements_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_deleted_at ON public.document_requirements USING btree (deleted_at);


--
-- Name: index_document_requirements_on_lead_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_lead_event_id ON public.document_requirements USING btree (lead_event_id);


--
-- Name: index_document_requirements_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_property_id ON public.document_requirements USING btree (property_id);


--
-- Name: index_document_requirements_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_requested_by_id ON public.document_requirements USING btree (requested_by_id);


--
-- Name: index_document_requirements_on_verified_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_requirements_on_verified_by_id ON public.document_requirements USING btree (verified_by_id);


--
-- Name: index_document_uploads_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_deleted_at ON public.document_uploads USING btree (deleted_at);


--
-- Name: index_document_uploads_on_purpose; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_purpose ON public.document_uploads USING btree (purpose);


--
-- Name: index_document_uploads_on_related_lead_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_related_lead_event_id ON public.document_uploads USING btree (related_lead_event_id);


--
-- Name: index_document_uploads_on_related_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_related_property_id ON public.document_uploads USING btree (related_property_id);


--
-- Name: index_document_uploads_on_related_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_related_task_id ON public.document_uploads USING btree (related_task_id);


--
-- Name: index_document_uploads_on_uploaded_by_id_and_uploaded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_uploads_on_uploaded_by_id_and_uploaded_at ON public.document_uploads USING btree (uploaded_by_id, uploaded_at);


--
-- Name: index_documents_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_deleted_at ON public.documents USING btree (deleted_at);


--
-- Name: index_documents_on_document_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_document_type ON public.documents USING btree (document_type);


--
-- Name: index_documents_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_property_id ON public.documents USING btree (property_id);


--
-- Name: index_documents_on_property_id_and_document_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_property_id_and_document_type ON public.documents USING btree (property_id, document_type);


--
-- Name: index_documents_on_public; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_public ON public.documents USING btree (public);


--
-- Name: index_documents_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_status ON public.documents USING btree (status);


--
-- Name: index_documents_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_user_id ON public.documents USING btree (user_id);


--
-- Name: index_documents_on_verified_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_verified_by_id ON public.documents USING btree (verified_by_id);


--
-- Name: index_external_listings_on_closed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_external_listings_on_closed_at ON public.external_listings USING btree (closed_at);


--
-- Name: index_external_listings_on_fetched_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_external_listings_on_fetched_at ON public.external_listings USING btree (fetched_at);


--
-- Name: index_external_listings_on_price_and_area; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_external_listings_on_price_and_area ON public.external_listings USING btree (price, area);


--
-- Name: index_external_listings_on_source_and_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_external_listings_on_source_and_source_id ON public.external_listings USING btree (source, source_id);


--
-- Name: index_favorites_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_favorites_on_created_at ON public.favorites USING btree (created_at);


--
-- Name: index_favorites_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_favorites_on_property_id ON public.favorites USING btree (property_id);


--
-- Name: index_favorites_on_property_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_favorites_on_property_id_and_created_at ON public.favorites USING btree (property_id, created_at);


--
-- Name: index_favorites_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_favorites_on_user_id ON public.favorites USING btree (user_id);


--
-- Name: index_favorites_on_user_id_and_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_favorites_on_user_id_and_property_id ON public.favorites USING btree (user_id, property_id);


--
-- Name: index_friendly_id_slugs_on_slug_and_sluggable_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_slug_and_sluggable_type ON public.friendly_id_slugs USING btree (slug, sluggable_type);


--
-- Name: index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope ON public.friendly_id_slugs USING btree (slug, sluggable_type, scope);


--
-- Name: index_friendly_id_slugs_on_sluggable_type_and_sluggable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_friendly_id_slugs_on_sluggable_type_and_sluggable_id ON public.friendly_id_slugs USING btree (sluggable_type, sluggable_id);


--
-- Name: index_inquiries_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_agent_id ON public.inquiries USING btree (agent_id);


--
-- Name: index_inquiries_on_client_email_norm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_client_email_norm ON public.inquiries USING btree (client_email_norm) WHERE (client_email_norm IS NOT NULL);


--
-- Name: index_inquiries_on_client_phone_e164; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_client_phone_e164 ON public.inquiries USING btree (client_phone_e164) WHERE (client_phone_e164 IS NOT NULL);


--
-- Name: index_inquiries_on_client_tg_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_client_tg_user_id ON public.inquiries USING btree (client_tg_user_id) WHERE (client_tg_user_id IS NOT NULL);


--
-- Name: index_inquiries_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_created_at ON public.inquiries USING btree (created_at);


--
-- Name: index_inquiries_on_created_at_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_created_at_and_status ON public.inquiries USING btree (created_at, status);


--
-- Name: index_inquiries_on_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_crm_id ON public.inquiries USING btree (crm_id);


--
-- Name: index_inquiries_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_email ON public.inquiries USING btree (email);


--
-- Name: index_inquiries_on_external_listing_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_external_listing_id ON public.inquiries USING btree (external_listing_id) WHERE (external_listing_id IS NOT NULL);


--
-- Name: index_inquiries_on_inquiry_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_inquiry_type ON public.inquiries USING btree (inquiry_type);


--
-- Name: index_inquiries_on_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_phone ON public.inquiries USING btree (phone);


--
-- Name: index_inquiries_on_preferred_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_preferred_date ON public.inquiries USING btree (preferred_date);


--
-- Name: index_inquiries_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_property_id ON public.inquiries USING btree (property_id);


--
-- Name: index_inquiries_on_property_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_property_id_and_status ON public.inquiries USING btree (property_id, status);


--
-- Name: index_inquiries_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_scheduled_at ON public.inquiries USING btree (scheduled_at);


--
-- Name: index_inquiries_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_source ON public.inquiries USING btree (source);


--
-- Name: index_inquiries_on_staff_test; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_staff_test ON public.inquiries USING btree (staff_test);


--
-- Name: index_inquiries_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_status ON public.inquiries USING btree (status);


--
-- Name: index_inquiries_on_status_and_inquiry_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_status_and_inquiry_type ON public.inquiries USING btree (status, inquiry_type);


--
-- Name: index_inquiries_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_user_id ON public.inquiries USING btree (user_id);


--
-- Name: index_inquiries_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inquiries_on_user_id_and_status ON public.inquiries USING btree (user_id, status);


--
-- Name: index_landing_contents_on_published; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_landing_contents_on_published ON public.landing_contents USING btree (published);


--
-- Name: index_lead_event_embeddings_on_lead_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_lead_event_embeddings_on_lead_event_id ON public.lead_event_embeddings USING btree (lead_event_id);


--
-- Name: index_lead_events_on_anchor_topic_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_anchor_topic_key ON public.lead_events USING btree (anchor_topic_key);


--
-- Name: index_lead_events_on_assigned_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_assigned_by_id ON public.lead_events USING btree (assigned_by_id);


--
-- Name: index_lead_events_on_assigned_to_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_assigned_to_id ON public.lead_events USING btree (assigned_to_id);


--
-- Name: index_lead_events_on_current_stage; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_current_stage ON public.lead_events USING btree (current_stage);


--
-- Name: index_lead_events_on_lead_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_lead_ref ON public.lead_events USING btree (lead_ref_type, lead_ref_id);


--
-- Name: index_lead_events_on_routed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_routed_by_id ON public.lead_events USING btree (routed_by_id);


--
-- Name: index_lead_events_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_source ON public.lead_events USING btree (source);


--
-- Name: index_lead_events_on_staff_test; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lead_events_on_staff_test ON public.lead_events USING btree (staff_test);


--
-- Name: index_listing_consents_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_listing_consents_on_property_id ON public.listing_consents USING btree (property_id);


--
-- Name: index_listing_consents_on_property_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_listing_consents_on_property_id_and_user_id ON public.listing_consents USING btree (property_id, user_id);


--
-- Name: index_listing_consents_on_signed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_listing_consents_on_signed_at ON public.listing_consents USING btree (signed_at);


--
-- Name: index_listing_consents_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_listing_consents_on_token ON public.listing_consents USING btree (token);


--
-- Name: index_listing_consents_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_listing_consents_on_user_id ON public.listing_consents USING btree (user_id);


--
-- Name: index_magic_link_tokens_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_magic_link_tokens_on_expires_at ON public.magic_link_tokens USING btree (expires_at);


--
-- Name: index_magic_link_tokens_on_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_magic_link_tokens_on_identifier ON public.magic_link_tokens USING btree (identifier);


--
-- Name: index_magic_link_tokens_on_scope_and_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_magic_link_tokens_on_scope_and_expires_at ON public.magic_link_tokens USING btree (scope, expires_at);


--
-- Name: index_magic_link_tokens_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_magic_link_tokens_on_token ON public.magic_link_tokens USING btree (token);


--
-- Name: index_messages_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_conversation_id ON public.messages USING btree (conversation_id);


--
-- Name: index_messages_on_conversation_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_conversation_id_and_created_at ON public.messages USING btree (conversation_id, created_at);


--
-- Name: index_messages_on_conversation_id_and_parent_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_conversation_id_and_parent_id_and_created_at ON public.messages USING btree (conversation_id, parent_id, created_at);


--
-- Name: index_messages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_created_at ON public.messages USING btree (created_at);


--
-- Name: index_messages_on_deleted_by_sender_and_deleted_by_recipient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_deleted_by_sender_and_deleted_by_recipient ON public.messages USING btree (deleted_by_sender, deleted_by_recipient);


--
-- Name: index_messages_on_inquiry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_inquiry_id ON public.messages USING btree (inquiry_id);


--
-- Name: index_messages_on_message_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_message_type ON public.messages USING btree (message_type);


--
-- Name: index_messages_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_parent_id ON public.messages USING btree (parent_id);


--
-- Name: index_messages_on_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_priority ON public.messages USING btree (priority);


--
-- Name: index_messages_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_property_id ON public.messages USING btree (property_id);


--
-- Name: index_messages_on_read_and_recipient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_read_and_recipient_id ON public.messages USING btree (read, recipient_id);


--
-- Name: index_messages_on_recipient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_recipient_id ON public.messages USING btree (recipient_id);


--
-- Name: index_messages_on_recipient_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_recipient_id_and_created_at ON public.messages USING btree (recipient_id, created_at);


--
-- Name: index_messages_on_recipient_id_and_read; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_recipient_id_and_read ON public.messages USING btree (recipient_id, read);


--
-- Name: index_messages_on_recipient_id_and_read_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_recipient_id_and_read_and_created_at ON public.messages USING btree (recipient_id, read, created_at);


--
-- Name: index_messages_on_sender_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_sender_id ON public.messages USING btree (sender_id);


--
-- Name: index_messages_on_sender_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_sender_id_and_created_at ON public.messages USING btree (sender_id, created_at);


--
-- Name: index_messages_on_sender_id_and_read; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_sender_id_and_read ON public.messages USING btree (sender_id, read);


--
-- Name: index_mls_listings_on_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_city ON public.mls_listings USING btree (city);


--
-- Name: index_mls_listings_on_deal_type_and_realty_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_deal_type_and_realty_type ON public.mls_listings USING btree (deal_type, realty_type);


--
-- Name: index_mls_listings_on_district; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_district ON public.mls_listings USING btree (district);


--
-- Name: index_mls_listings_on_latitude_and_longitude; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_latitude_and_longitude ON public.mls_listings USING btree (latitude, longitude);


--
-- Name: index_mls_listings_on_price_per_sqm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_price_per_sqm ON public.mls_listings USING btree (price_per_sqm);


--
-- Name: index_mls_listings_on_source_and_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mls_listings_on_source_and_external_id ON public.mls_listings USING btree (external_source, external_id);


--
-- Name: index_mls_listings_on_synced_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mls_listings_on_synced_at ON public.mls_listings USING btree (synced_at);


--
-- Name: index_nextcloud_share_links_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_nextcloud_share_links_on_created_by_id ON public.nextcloud_share_links USING btree (created_by_id);


--
-- Name: index_nextcloud_share_links_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_nextcloud_share_links_on_deleted_at ON public.nextcloud_share_links USING btree (deleted_at);


--
-- Name: index_nextcloud_share_links_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_nextcloud_share_links_on_expires_at ON public.nextcloud_share_links USING btree (expires_at);


--
-- Name: index_notes_on_crm_note_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notes_on_crm_note_id ON public.notes USING btree (crm_note_id) WHERE (crm_note_id IS NOT NULL);


--
-- Name: index_notes_on_notable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_notable ON public.notes USING btree (notable_type, notable_id);


--
-- Name: index_notes_on_sync_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_sync_state ON public.notes USING btree (sync_state);


--
-- Name: index_notes_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_user_id ON public.notes USING btree (user_id);


--
-- Name: index_notifications_on_archived_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_archived_at ON public.notifications USING btree (archived_at);


--
-- Name: index_notifications_on_notifiable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_notifiable ON public.notifications USING btree (notifiable_type, notifiable_id);


--
-- Name: index_notifications_on_read_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_read_at ON public.notifications USING btree (read_at);


--
-- Name: index_notifications_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id ON public.notifications USING btree (user_id);


--
-- Name: index_notifications_on_user_id_and_read_at_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id_and_read_at_and_created_at ON public.notifications USING btree (user_id, read_at, created_at);


--
-- Name: index_partner_agencies_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_partner_agencies_on_deleted_at ON public.partner_agencies USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: index_partner_agencies_on_feed_source_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_partner_agencies_on_feed_source_key ON public.partner_agencies USING btree (feed_source_key) WHERE (feed_source_key IS NOT NULL);


--
-- Name: index_partner_agencies_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_partner_agencies_on_slug ON public.partner_agencies USING btree (slug);


--
-- Name: index_phone_stop_lists_on_added_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_phone_stop_lists_on_added_by_user_id ON public.phone_stop_lists USING btree (added_by_user_id);


--
-- Name: index_phone_stop_lists_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_phone_stop_lists_on_expires_at ON public.phone_stop_lists USING btree (expires_at);


--
-- Name: index_phone_stop_lists_on_phone_last10; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_phone_stop_lists_on_phone_last10 ON public.phone_stop_lists USING btree (phone_last10) WHERE (deleted_at IS NULL);


--
-- Name: index_price_histories_on_change_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_change_type ON public.price_histories USING btree (change_type);


--
-- Name: index_price_histories_on_changed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_changed_by_id ON public.price_histories USING btree (changed_by_id);


--
-- Name: index_price_histories_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_created_at ON public.price_histories USING btree (created_at);


--
-- Name: index_price_histories_on_effective_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_effective_date ON public.price_histories USING btree (effective_date);


--
-- Name: index_price_histories_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_property_id ON public.price_histories USING btree (property_id);


--
-- Name: index_price_histories_on_property_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_property_id_and_created_at ON public.price_histories USING btree (property_id, created_at);


--
-- Name: index_price_histories_on_property_id_and_effective_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_histories_on_property_id_and_effective_date ON public.price_histories USING btree (property_id, effective_date);


--
-- Name: index_properties_on_area; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_area ON public.properties USING btree (area);


--
-- Name: index_properties_on_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_city ON public.properties USING btree (city);


--
-- Name: index_properties_on_commercial_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_commercial_type ON public.properties USING btree (commercial_type);


--
-- Name: index_properties_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_created_at ON public.properties USING btree (created_at);


--
-- Name: index_properties_on_deal_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_deal_state ON public.properties USING btree (deal_state);


--
-- Name: index_properties_on_deal_state_and_closed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_deal_state_and_closed_at ON public.properties USING btree (deal_state, closed_at);


--
-- Name: index_properties_on_deal_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_deal_type ON public.properties USING btree (deal_type);


--
-- Name: index_properties_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_deleted_at ON public.properties USING btree (deleted_at);


--
-- Name: index_properties_on_district; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_district ON public.properties USING btree (district);


--
-- Name: index_properties_on_external; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_properties_on_external ON public.properties USING btree (external_source, external_id);


--
-- Name: index_properties_on_force_archive; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_force_archive ON public.properties USING btree (force_archive) WHERE (force_archive = true);


--
-- Name: index_properties_on_force_publish; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_force_publish ON public.properties USING btree (force_publish) WHERE (force_publish = true);


--
-- Name: index_properties_on_in_ad; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_in_ad ON public.properties USING btree (in_ad);


--
-- Name: index_properties_on_in_mls; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_in_mls ON public.properties USING btree (in_mls);


--
-- Name: index_properties_on_is_featured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_is_featured ON public.properties USING btree (is_featured);


--
-- Name: index_properties_on_is_premium_true; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_is_premium_true ON public.properties USING btree (is_premium) WHERE (is_premium = true);


--
-- Name: index_properties_on_latitude_and_longitude; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_latitude_and_longitude ON public.properties USING btree (latitude, longitude);


--
-- Name: index_properties_on_metro_station; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_metro_station ON public.properties USING btree (metro_station);


--
-- Name: index_properties_on_moderated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_moderated_by_id ON public.properties USING btree (moderated_by_id);


--
-- Name: index_properties_on_owner_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_owner_user_id ON public.properties USING btree (owner_user_id);


--
-- Name: index_properties_on_price; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_price ON public.properties USING btree (price);


--
-- Name: index_properties_on_property_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_property_type_id ON public.properties USING btree (property_type_id);


--
-- Name: index_properties_on_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_published_at ON public.properties USING btree (published_at);


--
-- Name: index_properties_on_residential_complex_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_residential_complex_id ON public.properties USING btree (residential_complex_id);


--
-- Name: index_properties_on_rooms; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_rooms ON public.properties USING btree (rooms);


--
-- Name: index_properties_on_signed_agency_contract_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_signed_agency_contract_at ON public.properties USING btree (signed_agency_contract_at) WHERE (signed_agency_contract_at IS NOT NULL);


--
-- Name: index_properties_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_properties_on_slug ON public.properties USING btree (slug);


--
-- Name: index_properties_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_status ON public.properties USING btree (status);


--
-- Name: index_properties_on_status_and_deal_type_and_price; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_status_and_deal_type_and_price ON public.properties USING btree (status, deal_type, price);


--
-- Name: index_properties_on_status_and_is_featured_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_status_and_is_featured_and_created_at ON public.properties USING btree (status, is_featured, created_at);


--
-- Name: index_properties_on_synced_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_synced_at ON public.properties USING btree (synced_at);


--
-- Name: index_properties_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_properties_on_user_id ON public.properties USING btree (user_id);


--
-- Name: index_property_embeddings_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_property_embeddings_on_property_id ON public.property_embeddings USING btree (property_id);


--
-- Name: index_property_types_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_types_on_active ON public.property_types USING btree (active);


--
-- Name: index_property_types_on_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_types_on_position ON public.property_types USING btree ("position");


--
-- Name: index_property_types_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_property_types_on_slug ON public.property_types USING btree (slug);


--
-- Name: index_property_valuations_on_audit_mode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_audit_mode ON public.property_valuations USING btree (audit_mode);


--
-- Name: index_property_valuations_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_created_at ON public.property_valuations USING btree (created_at);


--
-- Name: index_property_valuations_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_email ON public.property_valuations USING btree (email);


--
-- Name: index_property_valuations_on_estimated_price; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_estimated_price ON public.property_valuations USING btree (estimated_price);


--
-- Name: index_property_valuations_on_evaluation_data; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_evaluation_data ON public.property_valuations USING gin (evaluation_data);


--
-- Name: index_property_valuations_on_latitude_and_longitude; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_latitude_and_longitude ON public.property_valuations USING btree (latitude, longitude);


--
-- Name: index_property_valuations_on_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_metadata ON public.property_valuations USING gin (metadata);


--
-- Name: index_property_valuations_on_property_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_property_type ON public.property_valuations USING btree (property_type);


--
-- Name: index_property_valuations_on_property_type_and_deal_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_property_type_and_deal_type ON public.property_valuations USING btree (property_type, deal_type);


--
-- Name: index_property_valuations_on_report_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_property_valuations_on_report_number ON public.property_valuations USING btree (report_number);


--
-- Name: index_property_valuations_on_staff_test; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_staff_test ON public.property_valuations USING btree (staff_test);


--
-- Name: index_property_valuations_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_status ON public.property_valuations USING btree (status);


--
-- Name: index_property_valuations_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_property_valuations_on_token ON public.property_valuations USING btree (token);


--
-- Name: index_property_valuations_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_valuations_on_user_id ON public.property_valuations USING btree (user_id);


--
-- Name: index_property_views_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_created_at ON public.property_views USING btree (created_at);


--
-- Name: index_property_views_on_device_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_device_type ON public.property_views USING btree (device_type);


--
-- Name: index_property_views_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_property_id ON public.property_views USING btree (property_id);


--
-- Name: index_property_views_on_property_id_and_created_at_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_property_id_and_created_at_and_user_id ON public.property_views USING btree (property_id, created_at, user_id);


--
-- Name: index_property_views_on_property_id_and_viewed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_property_id_and_viewed_at ON public.property_views USING btree (property_id, viewed_at);


--
-- Name: index_property_views_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_session_id ON public.property_views USING btree (session_id);


--
-- Name: index_property_views_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_source ON public.property_views USING btree (source);


--
-- Name: index_property_views_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_user_id ON public.property_views USING btree (user_id);


--
-- Name: index_property_views_on_user_id_and_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_user_id_and_property_id ON public.property_views USING btree (user_id, property_id);


--
-- Name: index_property_views_on_user_id_and_viewed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_user_id_and_viewed_at ON public.property_views USING btree (user_id, viewed_at);


--
-- Name: index_property_views_on_user_property_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_user_property_date ON public.property_views USING btree (user_id, property_id, viewed_at);


--
-- Name: index_property_views_on_viewed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_viewed_at ON public.property_views USING btree (viewed_at);


--
-- Name: index_property_views_on_viewed_at_and_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_property_views_on_viewed_at_and_property_id ON public.property_views USING btree (viewed_at, property_id);


--
-- Name: index_referrals_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_deleted_at ON public.referrals USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);


--
-- Name: index_referrals_on_external_listing_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_external_listing_id ON public.referrals USING btree (external_listing_id);


--
-- Name: index_referrals_on_inquiry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_inquiry_id ON public.referrals USING btree (inquiry_id);


--
-- Name: index_referrals_on_partner_agency_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_partner_agency_id ON public.referrals USING btree (partner_agency_id);


--
-- Name: index_referrals_on_partner_agency_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_partner_agency_id_and_status ON public.referrals USING btree (partner_agency_id, status);


--
-- Name: index_referrals_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_referrals_on_status ON public.referrals USING btree (status);


--
-- Name: index_residential_complexes_on_city_and_district_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_residential_complexes_on_city_and_district_slug ON public.residential_complexes USING btree (city, district_slug);


--
-- Name: index_residential_complexes_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_residential_complexes_on_deleted_at ON public.residential_complexes USING btree (deleted_at);


--
-- Name: index_residential_complexes_on_published; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_residential_complexes_on_published ON public.residential_complexes USING btree (published);


--
-- Name: index_residential_complexes_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_residential_complexes_on_slug ON public.residential_complexes USING btree (slug);


--
-- Name: index_reviews_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_agent_id ON public.reviews USING btree (agent_id);


--
-- Name: index_reviews_on_agent_id_and_status_and_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_agent_id_and_status_and_rating ON public.reviews USING btree (agent_id, status, rating);


--
-- Name: index_reviews_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_created_at ON public.reviews USING btree (created_at);


--
-- Name: index_reviews_on_featured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_featured ON public.reviews USING btree (featured);


--
-- Name: index_reviews_on_moderated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_moderated_by_id ON public.reviews USING btree (moderated_by_id);


--
-- Name: index_reviews_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_property_id ON public.reviews USING btree (property_id);


--
-- Name: index_reviews_on_property_id_and_status_and_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_property_id_and_status_and_published_at ON public.reviews USING btree (property_id, status, published_at);


--
-- Name: index_reviews_on_property_id_and_status_and_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_property_id_and_status_and_rating ON public.reviews USING btree (property_id, status, rating);


--
-- Name: index_reviews_on_published_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_published_at ON public.reviews USING btree (published_at);


--
-- Name: index_reviews_on_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_rating ON public.reviews USING btree (rating);


--
-- Name: index_reviews_on_responded_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_responded_by_id ON public.reviews USING btree (responded_by_id);


--
-- Name: index_reviews_on_review_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_review_type ON public.reviews USING btree (review_type);


--
-- Name: index_reviews_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_source ON public.reviews USING btree (source);


--
-- Name: index_reviews_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_status ON public.reviews USING btree (status);


--
-- Name: index_reviews_on_status_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_status_and_created_at ON public.reviews USING btree (status, created_at);


--
-- Name: index_reviews_on_submitted_via; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_submitted_via ON public.reviews USING btree (submitted_via);


--
-- Name: index_reviews_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_user_id ON public.reviews USING btree (user_id);


--
-- Name: index_reviews_on_user_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_user_id_and_created_at ON public.reviews USING btree (user_id, created_at);


--
-- Name: index_reviews_on_verified_purchase; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_verified_purchase ON public.reviews USING btree (verified_purchase);


--
-- Name: index_reviews_on_visible; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_visible ON public.reviews USING btree (visible);


--
-- Name: index_reviews_on_visible_and_status_and_rating; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reviews_on_visible_and_status_and_rating ON public.reviews USING btree (visible, status, rating);


--
-- Name: index_saved_searches_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_active ON public.saved_searches USING btree (active);


--
-- Name: index_saved_searches_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_created_at ON public.saved_searches USING btree (created_at);


--
-- Name: index_saved_searches_on_filters; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_filters ON public.saved_searches USING gin (filters);


--
-- Name: index_saved_searches_on_last_checked_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_last_checked_at ON public.saved_searches USING btree (last_checked_at);


--
-- Name: index_saved_searches_on_notify_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_notify_enabled ON public.saved_searches USING btree (notify_enabled);


--
-- Name: index_saved_searches_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_user_id ON public.saved_searches USING btree (user_id);


--
-- Name: index_saved_searches_on_user_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_user_id_and_active ON public.saved_searches USING btree (user_id, active);


--
-- Name: index_saved_searches_on_user_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_saved_searches_on_user_id_and_created_at ON public.saved_searches USING btree (user_id, created_at);


--
-- Name: index_service_orders_on_crm_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_orders_on_crm_id ON public.service_orders USING btree (crm_id);


--
-- Name: index_service_orders_on_service_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_orders_on_service_type_id ON public.service_orders USING btree (service_type_id);


--
-- Name: index_service_orders_on_service_type_id_and_deal_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_orders_on_service_type_id_and_deal_state ON public.service_orders USING btree (service_type_id, deal_state);


--
-- Name: index_service_orders_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_service_orders_on_user_id ON public.service_orders USING btree (user_id);


--
-- Name: index_service_types_on_crm_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_types_on_crm_type_id ON public.service_types USING btree (crm_type_id) WHERE (crm_type_id IS NOT NULL);


--
-- Name: index_service_types_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_service_types_on_slug ON public.service_types USING btree (slug);


--
-- Name: index_staff_metrics_on_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_metrics_on_date ON public.staff_metrics USING btree (date);


--
-- Name: index_staff_metrics_on_staff_id_and_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_staff_metrics_on_staff_id_and_date ON public.staff_metrics USING btree (staff_id, date);


--
-- Name: index_staff_questions_on_asked_by_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_asked_by_id_and_created_at ON public.staff_questions USING btree (asked_by_id, created_at);


--
-- Name: index_staff_questions_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_deleted_at ON public.staff_questions USING btree (deleted_at);


--
-- Name: index_staff_questions_on_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_kind ON public.staff_questions USING btree (kind);


--
-- Name: index_staff_questions_on_related_lead_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_related_lead_event_id ON public.staff_questions USING btree (related_lead_event_id);


--
-- Name: index_staff_questions_on_related_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_related_task_id ON public.staff_questions USING btree (related_task_id);


--
-- Name: index_staff_questions_on_tg_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_staff_questions_on_tg_message_id ON public.staff_questions USING btree (tg_message_id);


--
-- Name: index_task_batches_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_batches_on_created_at ON public.task_batches USING btree (created_at);


--
-- Name: index_task_batches_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_batches_on_created_by_id ON public.task_batches USING btree (created_by_id);


--
-- Name: index_task_batches_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_batches_on_deleted_at ON public.task_batches USING btree (deleted_at);


--
-- Name: index_task_batches_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_task_batches_on_status ON public.task_batches USING btree (status);


--
-- Name: index_tasks_on_assignee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_assignee_id ON public.tasks USING btree (assignee_id);


--
-- Name: index_tasks_on_assignee_id_and_completed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_assignee_id_and_completed_at ON public.tasks USING btree (assignee_id, completed_at);


--
-- Name: index_tasks_on_assignee_id_and_status_and_due_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_assignee_id_and_status_and_due_at ON public.tasks USING btree (assignee_id, status, due_at);


--
-- Name: index_tasks_on_attachments; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_attachments ON public.tasks USING gin (attachments);


--
-- Name: index_tasks_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_created_by_id ON public.tasks USING btree (created_by_id);


--
-- Name: index_tasks_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_deleted_at ON public.tasks USING btree (deleted_at);


--
-- Name: index_tasks_on_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_kind ON public.tasks USING btree (kind);


--
-- Name: index_tasks_on_last_pinged_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_last_pinged_at ON public.tasks USING btree (last_pinged_at);


--
-- Name: index_tasks_on_lead_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_lead_event_id ON public.tasks USING btree (lead_event_id);


--
-- Name: index_tasks_on_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_priority ON public.tasks USING btree (priority);


--
-- Name: index_tasks_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_status ON public.tasks USING btree (status);


--
-- Name: index_tasks_on_suspicious_flag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_suspicious_flag ON public.tasks USING btree (suspicious_flag) WHERE (suspicious_flag = true);


--
-- Name: index_tasks_on_task_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_task_batch_id ON public.tasks USING btree (task_batch_id);


--
-- Name: index_tasks_on_topnlab_id_and_topnlab_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tasks_on_topnlab_id_and_topnlab_type ON public.tasks USING btree (topnlab_id, topnlab_type);


--
-- Name: index_telegram_group_messages_on_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_group_messages_on_sent_at ON public.telegram_group_messages USING btree (sent_at);


--
-- Name: index_telegram_group_messages_on_tg_thread_id_and_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_group_messages_on_tg_thread_id_and_sent_at ON public.telegram_group_messages USING btree (tg_thread_id, sent_at);


--
-- Name: index_telegram_group_messages_on_tg_user_id_and_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_group_messages_on_tg_user_id_and_sent_at ON public.telegram_group_messages USING btree (tg_user_id, sent_at);


--
-- Name: index_telegram_users_on_assignable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_users_on_assignable ON public.telegram_users USING btree (assignable);


--
-- Name: index_telegram_users_on_dm_pending_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_users_on_dm_pending_action ON public.telegram_users USING gin (dm_pending_action);


--
-- Name: index_telegram_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_users_on_email ON public.telegram_users USING btree (email) WHERE (email IS NOT NULL);


--
-- Name: index_telegram_users_on_is_manager; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_users_on_is_manager ON public.telegram_users USING btree (is_manager);


--
-- Name: index_telegram_users_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_users_on_role ON public.telegram_users USING btree (role);


--
-- Name: index_telegram_users_on_tg_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_telegram_users_on_tg_user_id ON public.telegram_users USING btree (tg_user_id);


--
-- Name: index_telegram_users_on_topnlab_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_telegram_users_on_topnlab_user_id ON public.telegram_users USING btree (topnlab_user_id) WHERE (topnlab_user_id IS NOT NULL);


--
-- Name: index_telegram_webhook_acks_on_processed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_telegram_webhook_acks_on_processed_at ON public.telegram_webhook_acks USING btree (processed_at);


--
-- Name: index_telegram_webhook_acks_on_update_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_telegram_webhook_acks_on_update_id ON public.telegram_webhook_acks USING btree (update_id);


--
-- Name: index_tg_link_tokens_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tg_link_tokens_on_expires_at ON public.tg_link_tokens USING btree (expires_at);


--
-- Name: index_tg_link_tokens_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tg_link_tokens_on_source ON public.tg_link_tokens USING btree (source);


--
-- Name: index_tg_link_tokens_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tg_link_tokens_on_token ON public.tg_link_tokens USING btree (token);


--
-- Name: index_tg_link_tokens_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tg_link_tokens_on_user_id ON public.tg_link_tokens USING btree (user_id);


--
-- Name: index_topnlab_sync_runs_on_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_topnlab_sync_runs_on_started_at ON public.topnlab_sync_runs USING btree (started_at);


--
-- Name: index_topnlab_sync_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_topnlab_sync_runs_on_status ON public.topnlab_sync_runs USING btree (status);


--
-- Name: index_users_on_agent_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_agent_slug ON public.users USING btree (agent_slug) WHERE (agent_slug IS NOT NULL);


--
-- Name: index_users_on_confirmation_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_confirmation_token ON public.users USING btree (confirmation_token);


--
-- Name: index_users_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_created_at ON public.users USING btree (created_at);


--
-- Name: index_users_on_crm_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_crm_user_id ON public.users USING btree (crm_user_id) WHERE (crm_user_id IS NOT NULL);


--
-- Name: index_users_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_deleted_at ON public.users USING btree (deleted_at);


--
-- Name: index_users_on_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_department_id ON public.users USING btree (department_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_invited_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_invited_at ON public.users USING btree (invited_at) WHERE (invited_at IS NOT NULL);


--
-- Name: index_users_on_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_phone ON public.users USING btree (phone);


--
-- Name: index_users_on_provider_and_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_provider_and_uid ON public.users USING btree (provider, uid);


--
-- Name: index_users_on_public_profile_hidden_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_public_profile_hidden_at ON public.users USING btree (public_profile_hidden_at);


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON public.users USING btree (reset_password_token);


--
-- Name: index_users_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_role ON public.users USING btree (role);


--
-- Name: index_users_on_tg_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_tg_user_id ON public.users USING btree (tg_user_id) WHERE (tg_user_id IS NOT NULL);


--
-- Name: index_users_on_unlock_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_unlock_token ON public.users USING btree (unlock_token);


--
-- Name: index_viewing_schedules_on_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_agent_id ON public.viewing_schedules USING btree (agent_id);


--
-- Name: index_viewing_schedules_on_agent_id_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_agent_id_and_scheduled_at ON public.viewing_schedules USING btree (agent_id, scheduled_at);


--
-- Name: index_viewing_schedules_on_confirmation_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_viewing_schedules_on_confirmation_token ON public.viewing_schedules USING btree (confirmation_token);


--
-- Name: index_viewing_schedules_on_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_deleted_at ON public.viewing_schedules USING btree (deleted_at);


--
-- Name: index_viewing_schedules_on_inquiry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_inquiry_id ON public.viewing_schedules USING btree (inquiry_id);


--
-- Name: index_viewing_schedules_on_property_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_property_id ON public.viewing_schedules USING btree (property_id);


--
-- Name: index_viewing_schedules_on_property_id_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_property_id_and_scheduled_at ON public.viewing_schedules USING btree (property_id, scheduled_at);


--
-- Name: index_viewing_schedules_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_scheduled_at ON public.viewing_schedules USING btree (scheduled_at);


--
-- Name: index_viewing_schedules_on_scheduled_at_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_scheduled_at_and_status ON public.viewing_schedules USING btree (scheduled_at, status);


--
-- Name: index_viewing_schedules_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_status ON public.viewing_schedules USING btree (status);


--
-- Name: index_viewing_schedules_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_user_id ON public.viewing_schedules USING btree (user_id);


--
-- Name: index_viewing_schedules_on_user_id_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_user_id_and_scheduled_at ON public.viewing_schedules USING btree (user_id, scheduled_at);


--
-- Name: index_viewing_schedules_on_viewing_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_viewing_schedules_on_viewing_type ON public.viewing_schedules USING btree (viewing_type);


--
-- Name: tasks fk_rails_0016c50613; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_0016c50613 FOREIGN KEY (assignee_id) REFERENCES public.telegram_users(id);


--
-- Name: case_studies fk_rails_031161c67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_studies
    ADD CONSTRAINT fk_rails_031161c67c FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: viewing_schedules fk_rails_0c2935312d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules
    ADD CONSTRAINT fk_rails_0c2935312d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tasks fk_rails_0d008d4989; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_0d008d4989 FOREIGN KEY (lead_event_id) REFERENCES public.lead_events(id);


--
-- Name: messages fk_rails_12e9de2e48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_12e9de2e48 FOREIGN KEY (recipient_id) REFERENCES public.users(id);


--
-- Name: inquiries fk_rails_18a232bee4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT fk_rails_18a232bee4 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: messages fk_rails_1b38f09558; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_1b38f09558 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: listing_consents fk_rails_23f767c955; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_consents
    ADD CONSTRAINT fk_rails_23f767c955 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: tg_link_tokens fk_rails_28da5fa0f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tg_link_tokens
    ADD CONSTRAINT fk_rails_28da5fa0f5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: lead_event_embeddings fk_rails_2b90fd4f9a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_event_embeddings
    ADD CONSTRAINT fk_rails_2b90fd4f9a FOREIGN KEY (lead_event_id) REFERENCES public.lead_events(id) ON DELETE CASCADE;


--
-- Name: documents fk_rails_2be0318c46; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_2be0318c46 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: inquiries fk_rails_2ca4d31b08; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT fk_rails_2ca4d31b08 FOREIGN KEY (agent_id) REFERENCES public.users(id);


--
-- Name: price_histories fk_rails_3590d68c77; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_histories
    ADD CONSTRAINT fk_rails_3590d68c77 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: properties fk_rails_36e2ff0e8d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT fk_rails_36e2ff0e8d FOREIGN KEY (moderated_by_id) REFERENCES public.users(id);


--
-- Name: property_views fk_rails_3e8c6e5e1e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_views
    ADD CONSTRAINT fk_rails_3e8c6e5e1e FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: document_requirements fk_rails_3f5770aee4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_requirements
    ADD CONSTRAINT fk_rails_3f5770aee4 FOREIGN KEY (received_via_client_document_id) REFERENCES public.client_documents(id);


--
-- Name: property_embeddings fk_rails_409cf9426f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_embeddings
    ADD CONSTRAINT fk_rails_409cf9426f FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: conversations fk_rails_435181481e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_435181481e FOREIGN KEY (assigned_user_id) REFERENCES public.users(id);


--
-- Name: phone_stop_lists fk_rails_47c41b9e0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_stop_lists
    ADD CONSTRAINT fk_rails_47c41b9e0c FOREIGN KEY (added_by_user_id) REFERENCES public.users(id);


--
-- Name: price_histories fk_rails_4c1a87df16; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_histories
    ADD CONSTRAINT fk_rails_4c1a87df16 FOREIGN KEY (changed_by_id) REFERENCES public.users(id);


--
-- Name: reviews fk_rails_57ddbd8409; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_57ddbd8409 FOREIGN KEY (moderated_by_id) REFERENCES public.users(id);


--
-- Name: lead_events fk_rails_58c6df3c19; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT fk_rails_58c6df3c19 FOREIGN KEY (assigned_by_id) REFERENCES public.telegram_users(id);


--
-- Name: document_requirements fk_rails_5d4cb011e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_requirements
    ADD CONSTRAINT fk_rails_5d4cb011e3 FOREIGN KEY (lead_event_id) REFERENCES public.lead_events(id);


--
-- Name: referrals fk_rails_6016ecd3c1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT fk_rails_6016ecd3c1 FOREIGN KEY (external_listing_id) REFERENCES public.external_listings(id);


--
-- Name: saved_searches fk_rails_63c5382842; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_searches
    ADD CONSTRAINT fk_rails_63c5382842 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: lead_events fk_rails_6464244a76; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT fk_rails_6464244a76 FOREIGN KEY (assigned_to_id) REFERENCES public.telegram_users(id);


--
-- Name: document_requirements fk_rails_68262426de; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_requirements
    ADD CONSTRAINT fk_rails_68262426de FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: viewing_schedules fk_rails_6a96fae4fc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules
    ADD CONSTRAINT fk_rails_6a96fae4fc FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: chat_messages fk_rails_6ede0d6992; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT fk_rails_6ede0d6992 FOREIGN KEY (conversation_id) REFERENCES public.conversations(id);


--
-- Name: reviews fk_rails_74a66bd6c5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_74a66bd6c5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: conversations fk_rails_7c15d62a0a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_7c15d62a0a FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: notes fk_rails_7f2323ad43; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT fk_rails_7f2323ad43 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: inquiries fk_rails_7fdff2c1ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT fk_rails_7fdff2c1ec FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: documents fk_rails_8a2bbce10a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_8a2bbce10a FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: article_embeddings fk_rails_95f36a2235; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.article_embeddings
    ADD CONSTRAINT fk_rails_95f36a2235 FOREIGN KEY (article_id) REFERENCES public.articles(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: property_valuations fk_rails_9b03707424; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_valuations
    ADD CONSTRAINT fk_rails_9b03707424 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: inquiries fk_rails_a2644be315; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inquiries
    ADD CONSTRAINT fk_rails_a2644be315 FOREIGN KEY (external_listing_id) REFERENCES public.external_listings(id) ON DELETE SET NULL;


--
-- Name: documents fk_rails_a34e953de0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_a34e953de0 FOREIGN KEY (verified_by_id) REFERENCES public.users(id);


--
-- Name: tasks fk_rails_a362a150d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT fk_rails_a362a150d3 FOREIGN KEY (created_by_id) REFERENCES public.telegram_users(id);


--
-- Name: messages fk_rails_aafcb31dbf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_aafcb31dbf FOREIGN KEY (parent_id) REFERENCES public.messages(id);


--
-- Name: referrals fk_rails_ab17825245; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT fk_rails_ab17825245 FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: favorites fk_rails_ac406bc263; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT fk_rails_ac406bc263 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: referrals fk_rails_aeda7f10df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT fk_rails_aeda7f10df FOREIGN KEY (partner_agency_id) REFERENCES public.partner_agencies(id);


--
-- Name: notifications fk_rails_b080fb4855; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_rails_b080fb4855 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: telegram_group_message_embeddings fk_rails_b3496421d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telegram_group_message_embeddings
    ADD CONSTRAINT fk_rails_b3496421d8 FOREIGN KEY (telegram_group_message_id) REFERENCES public.telegram_group_messages(id) ON DELETE CASCADE;


--
-- Name: viewing_schedules fk_rails_b3cf689e60; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules
    ADD CONSTRAINT fk_rails_b3cf689e60 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: client_documents fk_rails_b6a3d76be6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_documents
    ADD CONSTRAINT fk_rails_b6a3d76be6 FOREIGN KEY (uploader_id) REFERENCES public.users(id);


--
-- Name: messages fk_rails_b8f26a382d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_b8f26a382d FOREIGN KEY (sender_id) REFERENCES public.users(id);


--
-- Name: case_studies fk_rails_bea0a6fb67; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_studies
    ADD CONSTRAINT fk_rails_bea0a6fb67 FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: activation_events fk_rails_bfaa241f6f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activation_events
    ADD CONSTRAINT fk_rails_bfaa241f6f FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: properties fk_rails_c049a2d607; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT fk_rails_c049a2d607 FOREIGN KEY (residential_complex_id) REFERENCES public.residential_complexes(id) ON DELETE SET NULL;


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: lead_events fk_rails_c91ddfdd52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT fk_rails_c91ddfdd52 FOREIGN KEY (routed_by_id) REFERENCES public.telegram_users(id);


--
-- Name: reviews fk_rails_cb5be69465; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_cb5be69465 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: reviews fk_rails_d0c68ab778; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_d0c68ab778 FOREIGN KEY (responded_by_id) REFERENCES public.users(id);


--
-- Name: messages fk_rails_d0f3f45650; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_d0f3f45650 FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: favorites fk_rails_d15744e438; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT fk_rails_d15744e438 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: chat_messages fk_rails_d688adc904; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT fk_rails_d688adc904 FOREIGN KEY (author_id) REFERENCES public.users(id);


--
-- Name: property_views fk_rails_d8581f5311; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_views
    ADD CONSTRAINT fk_rails_d8581f5311 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: listing_consents fk_rails_d9cae37e71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_consents
    ADD CONSTRAINT fk_rails_d9cae37e71 FOREIGN KEY (property_id) REFERENCES public.properties(id);


--
-- Name: reviews fk_rails_e0f0178b9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT fk_rails_e0f0178b9b FOREIGN KEY (agent_id) REFERENCES public.users(id);


--
-- Name: service_orders fk_rails_e14a51c793; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_orders
    ADD CONSTRAINT fk_rails_e14a51c793 FOREIGN KEY (service_type_id) REFERENCES public.service_types(id);


--
-- Name: properties fk_rails_e208203768; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT fk_rails_e208203768 FOREIGN KEY (owner_user_id) REFERENCES public.users(id);


--
-- Name: properties fk_rails_e41321a67c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT fk_rails_e41321a67c FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: articles fk_rails_e74ce85cbc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.articles
    ADD CONSTRAINT fk_rails_e74ce85cbc FOREIGN KEY (author_id) REFERENCES public.users(id);


--
-- Name: case_studies fk_rails_ee72776bd0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_studies
    ADD CONSTRAINT fk_rails_ee72776bd0 FOREIGN KEY (author_id) REFERENCES public.users(id);


--
-- Name: client_documents fk_rails_f619b0f9ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_documents
    ADD CONSTRAINT fk_rails_f619b0f9ca FOREIGN KEY (inquiry_id) REFERENCES public.inquiries(id);


--
-- Name: viewing_schedules fk_rails_fc0efacfbc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.viewing_schedules
    ADD CONSTRAINT fk_rails_fc0efacfbc FOREIGN KEY (agent_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260808210100'),
('20260808210000'),
('20260528100000'),
('20260528090000'),
('20260528080100'),
('20260528080000'),
('20260528070100'),
('20260528070000'),
('20260528060100'),
('20260528060000'),
('20260528050200'),
('20260528050100'),
('20260528050000'),
('20260528040000'),
('20260528031000'),
('20260528030000'),
('20260528020000'),
('20260528012000'),
('20260528011000'),
('20260528010000'),
('20260528009000'),
('20260528008000'),
('20260528007000'),
('20260528006000'),
('20260528005000'),
('20260528004000'),
('20260528003000'),
('20260528002000'),
('20260528001000'),
('20260528000200'),
('20260528000100'),
('20260528000000'),
('20260527040000'),
('20260527030000'),
('20260527020000'),
('20260527010000'),
('20260527000900'),
('20260527000800'),
('20260527000700'),
('20260527000600'),
('20260527000500'),
('20260527000400'),
('20260527000300'),
('20260527000200'),
('20260527000100'),
('20260527000000'),
('20260526000000'),
('20260525000000'),
('20260524000100'),
('20260524000000'),
('20260523000000'),
('20260522000100'),
('20260522000000'),
('20260521000100'),
('20260521000000'),
('20260520000000'),
('20260519010000'),
('20260519000000'),
('20260518000000'),
('20260517000000'),
('20260516000000'),
('20260515000000'),
('20260514100000'),
('20260514000932'),
('20260514000001'),
('20260513234136'),
('20260513000000'),
('20260512000000'),
('20260511180000'),
('20260511160000'),
('20260511150000'),
('20260511130000'),
('20260511100000'),
('20260510130000'),
('20260510120000'),
('20260510084807'),
('20260510084806'),
('20260509220000'),
('20260509211700'),
('20260509211600'),
('20260509211500'),
('20260509211400'),
('20260509175823'),
('20260509164339'),
('20260509152650'),
('20260509113517'),
('20260509113213'),
('20260509112858'),
('20260509111702'),
('20260509111138'),
('20260509104500'),
('20260509103442'),
('20260508212056'),
('20260508180000'),
('20260508170000'),
('20260508143012'),
('20240101120000'),
('20240101000011'),
('20240101000010'),
('20240101000009'),
('20240101000008'),
('20240101000007'),
('20240101000006'),
('20240101000005'),
('20240101000004'),
('20240101000003'),
('20240101000002'),
('20240101000001'),
('20240101000000');

