-- Read-only schema capture of the Knowledge Base public application objects.
-- No production rows, sequence values, login passwords or memberships exported.
-- Applies to empty/local/preview databases only until an explicit production adoption.
-- Existing objects fail closed; this migration never replaces an existing legacy table.
-- Exact source statements and schema-only provenance: docs/legacy-schema-inventory.json.

SET check_function_bodies = false;
SET search_path = public, extensions, pg_temp;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgroonga WITH SCHEMA extensions;

-- Portable privilege subjects, not production login identities. No membership copy.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'journals_reader') THEN
    CREATE ROLE journals_reader NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'out_user') THEN
    CREATE ROLE out_user NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END
$roles$;
GRANT USAGE ON SCHEMA public TO journals_reader;

CREATE TYPE "public"."lang" AS ENUM (
    'eng',
    'chi_sim',
    'chi_tra',
    'fra',
    'spa',
    'jpn',
    'kor',
    'deu'
);

CREATE FUNCTION "public"."esg_full_text"("meta_contains" "text") RETURNS TABLE("id" "uuid")
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions', 'pg_temp'
    AS E'\nBEGIN\n  RETURN QUERY\n  SELECT s.id \n  FROM public.esg_meta s\n  WHERE s.report_title &@~ meta_contains\n     OR s.company_name &@~ meta_contains\n     OR s.category_new &@~ meta_contains;\nEND;\n';

CREATE FUNCTION "public"."has_service_role"("user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS E'\r\n  SELECT EXISTS (\r\n    SELECT 1\r\n    FROM public.user_roles\r\n    WHERE user_id = $1\r\n    AND role = ''service_role''\r\n  );\r\n';

CREATE FUNCTION "public"."set_created_by"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
    NEW.created_by := current_user;
    NEW.created_time := now();
    RETURN NEW;
END;
$$;

CREATE FUNCTION "public"."set_last_updated_by"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NEW.last_updated_by IS DISTINCT FROM current_user THEN
        NEW.last_updated_by := current_user;
    END IF;
  NEW.last_updated_time := now();
    RETURN NEW;
END;
$$;

CREATE FUNCTION "public"."set_last_updated_time"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
    NEW.last_updated_time := now();
    RETURN NEW;
END;
$$;

CREATE FUNCTION "public"."standards_full_text"("meta_contains" "text") RETURNS TABLE("id" "uuid")
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'extensions', 'pg_temp'
    AS E'\nBEGIN\n  RETURN QUERY\n  SELECT s.id \n  FROM public.standards s\n  WHERE s.title &@~ meta_contains\n     OR s.issuing_organization &@~ meta_contains\n     OR s.standard_number &@~ meta_contains;\nEND;\n';

CREATE TABLE "public"."edu_meta" (
    "name" character varying(255),
    "chapter_number" integer,
    "description" "text",
    "course" character varying(255),
    "language" "public"."lang",
    "type" character varying(255),
    "embedding_time" timestamp with time zone,
    "upload_time" timestamp with time zone,
    "file_type" character varying(255),
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "fulltext_time" timestamp with time zone
);

CREATE TABLE "public"."edu_textbooks" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "title" character varying,
    "authors" "jsonb",
    "isbn_number" character varying,
    "publish_time" timestamp with time zone,
    "category" "jsonb",
    "language" "public"."lang",
    "embedding_time" timestamp with time zone,
    "fulltext_time" timestamp with time zone,
    "pdf_exist" boolean
);

CREATE TABLE "public"."esg_category" (
    "code" character(6) NOT NULL,
    "name" character varying
);

CREATE TABLE "public"."esg_country" (
    "code" character(3) NOT NULL,
    "name" character varying
);

CREATE TABLE "public"."esg_meta" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "created_by" character varying,
    "last_updated_by" character varying,
    "country" character varying,
    "company_name" character varying,
    "company_short_name" character varying,
    "report_title" character varying,
    "publication_date" timestamp with time zone,
    "report_start_date" timestamp with time zone,
    "report_end_date" timestamp with time zone,
    "language" "public"."lang",
    "report_url" "text",
    "nas_path" "text",
    "uploaded_time" timestamp with time zone,
    "embedded_time" timestamp with time zone,
    "created_time" timestamp with time zone,
    "last_updated_time" timestamp with time zone,
    "category_new" "jsonb",
    "fulltext_time" timestamp with time zone,
    "exchange_ticker" character varying,
    "company_name_en" character varying,
    "industry_group" character varying,
    "primary_sector" character varying,
    "sic_code" character(4),
    "unstructure_time" timestamp with time zone,
    "pdf_name" character varying(255)
);

ALTER TABLE ONLY "public"."esg_meta" FORCE ROW LEVEL SECURITY;

CREATE TABLE "public"."green_deal_meta" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "tags" "jsonb",
    "title" "text",
    "publish_date" timestamp with time zone,
    "issue_agency" character varying(255),
    "upload_time" timestamp with time zone,
    "embedding_time" timestamp with time zone,
    "fulltext_time" timestamp with time zone,
    "celex_number" character varying(255),
    "unstructure_time" timestamp with time zone,
    "form" character varying(255),
    "authors" character varying(255),
    "procedure_number" character varying(255),
    "date_of_end_of_validity" timestamp with time zone,
    "date_of_effect" "jsonb",
    "last_updated_time" timestamp with time zone,
    "responsible_body" character varying(255)
);

CREATE TABLE "public"."internal_use" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "title" character varying,
    "file_type" character varying,
    "uploaded_time" timestamp with time zone,
    "embedded_time" timestamp with time zone,
    "fulltext_time" timestamp with time zone,
    "created_time" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "unstructure_time" timestamp with time zone,
    "language" character varying(10),
    "tag" character varying
);

CREATE TABLE "public"."journals" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "journal" character varying(255),
    "title" "text",
    "authors" "jsonb",
    "doi" character varying(255) NOT NULL,
    "date" character varying(255),
    "upload_time" timestamp with time zone,
    "embedding_time" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "fulltext_time" timestamp with time zone,
    "abstract" "text"
);

CREATE TABLE "public"."journals_issn" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "journal" character varying(255),
    "issn1" character varying(9),
    "issn2" character varying(9)
);

CREATE TABLE "public"."kb_schema_migrations" (
    "version" "text" NOT NULL,
    "applied_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE "public"."reports" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "title" character varying,
    "language" "public"."lang",
    "issuing_organization" json,
    "release_date" timestamp with time zone,
    "url" "text",
    "category" character varying,
    "uploaded_time" timestamp with time zone,
    "embedded_time" timestamp with time zone,
    "fulltext_time" timestamp with time zone
);

CREATE TABLE "public"."standards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "standard_number" character varying,
    "title" "text",
    "name_original" "text",
    "name_english" "text",
    "standard_type" "text",
    "status" "text",
    "keywords" "jsonb",
    "ccs" "text",
    "ccs_chinese" "text",
    "ics" "text",
    "ics_chinese" "text",
    "published_date" timestamp(6) with time zone,
    "effective_date" timestamp(6) with time zone,
    "expiration_date" timestamp(6) with time zone,
    "issuing_unit" "jsonb",
    "issuing_organization" "jsonb",
    "drafting_organization" "jsonb",
    "language" "text",
    "applicable_scope" "text",
    "replacing_standard" "text",
    "replaced_standard" "text",
    "referenced_standards" "text",
    "country_code" "text",
    "sub_type" "text",
    "subtypeforce" "text",
    "domestic_foreign" "text",
    "page_number" smallint,
    "pdf_name" "text" DEFAULT ''::character varying,
    "a001" bigint,
    "url" "text",
    "uploaded_time" timestamp(6) with time zone,
    "embedded_time" timestamp(6) with time zone,
    "last_updated_time" timestamp(6) with time zone,
    "fulltext_time" timestamp(6) with time zone,
    "unstructure_time" timestamp(6) with time zone
);

CREATE TABLE "public"."user_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."internal_use"
    ADD CONSTRAINT "ali_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."edu_meta"
    ADD CONSTRAINT "edu_meta_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."edu_textbooks"
    ADD CONSTRAINT "edu_textbooks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."esg_category"
    ADD CONSTRAINT "esg_category_pkey" PRIMARY KEY ("code");

ALTER TABLE ONLY "public"."esg_country"
    ADD CONSTRAINT "esg_country_pkey" PRIMARY KEY ("code");

ALTER TABLE ONLY "public"."esg_meta"
    ADD CONSTRAINT "esg_meta_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."green_deal_meta"
    ADD CONSTRAINT "green_deal_meta_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."journals_issn"
    ADD CONSTRAINT "journals_issn_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."journals"
    ADD CONSTRAINT "journals_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."kb_schema_migrations"
    ADD CONSTRAINT "kb_schema_migrations_pkey" PRIMARY KEY ("version");

ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."standards"
    ADD CONSTRAINT "selected_stds_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "unique_user_role" UNIQUE ("user_id", "role");

ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");

CREATE UNIQUE INDEX "a001_idx" ON "public"."standards" USING "btree" ("a001");

CREATE INDEX "created_at_idx" ON "public"."journals" USING "btree" ("created_at");

CREATE UNIQUE INDEX "doi_idx" ON "public"."journals" USING "btree" ("doi");

CREATE INDEX "edu_textbooks_authors_pgroonga_idx" ON "public"."edu_textbooks" USING "pgroonga" ("authors");

CREATE INDEX "edu_textbooks_embedding_time_idx" ON "public"."edu_textbooks" USING "btree" ("embedding_time");

CREATE INDEX "edu_textbooks_fulltex_time_idx" ON "public"."edu_textbooks" USING "btree" ("fulltext_time");

CREATE INDEX "edu_textbooks_title_pgroonga_idx" ON "public"."edu_textbooks" USING "pgroonga" ("title");

CREATE INDEX "embedding_time_idx" ON "public"."journals" USING "btree" ("embedding_time");

CREATE INDEX "esg_category_pgroonga_idx" ON "public"."esg_meta" USING "pgroonga" ("category_new");

CREATE INDEX "esg_company_pgroonga_idx" ON "public"."esg_meta" USING "pgroonga" ("company_name");

CREATE INDEX "esg_title_pgroonga_idx" ON "public"."esg_meta" USING "pgroonga" ("report_title");

CREATE INDEX "fulltext_time_idx" ON "public"."journals" USING "btree" ("fulltext_time");

CREATE INDEX "green_deal_meta_publish_date_idx" ON "public"."green_deal_meta" USING "btree" ("publish_date");

CREATE INDEX "green_deal_meta_time_idx" ON "public"."green_deal_meta" USING "btree" ("upload_time", "embedding_time", "fulltext_time");

CREATE INDEX "idx" ON "public"."journals_issn" USING "btree" ("journal", "issn1", "issn2");

CREATE INDEX "internal_use_tag_idx" ON "public"."internal_use" USING "btree" ("tag");

CREATE INDEX "journals_abstract_fetch_candidates_idx" ON "public"."journals" USING "btree" ("created_at" DESC NULLS LAST, "doi") WHERE ((NULLIF("btrim"(("doi")::"text"), ''::"text") IS NOT NULL) AND (NULLIF("btrim"(("authors")::"text"), ''::"text") IS NOT NULL) AND (("abstract" IS NULL) OR (NULLIF("btrim"("abstract"), ''::"text") IS NULL)));

CREATE INDEX "upload_time_idx" ON "public"."journals" USING "btree" ("upload_time");

CREATE TRIGGER "set_created_by_trigger" BEFORE INSERT ON "public"."esg_meta" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_by"();

CREATE TRIGGER "set_last_updated_by_trigger" BEFORE UPDATE ON "public"."esg_meta" FOR EACH ROW EXECUTE FUNCTION "public"."set_last_updated_by"();

CREATE TRIGGER "set_last_updated_time_trigger" BEFORE UPDATE ON "public"."green_deal_meta" FOR EACH ROW EXECUTE FUNCTION "public"."set_last_updated_time"();

ALTER TABLE ONLY "public"."esg_meta"
    ADD CONSTRAINT "fk_country" FOREIGN KEY ("country") REFERENCES "public"."esg_country"("code");

ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

CREATE POLICY "Enable read access for all users" ON "public"."esg_category" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for all users" ON "public"."esg_country" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."edu_meta" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."edu_textbooks" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."internal_use" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."journals" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."journals_issn" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."reports" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Enable read access for authenticated users" ON "public"."standards" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Users can read their own roles" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."edu_meta" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."edu_textbooks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."esg_category" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."esg_country" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."esg_meta" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."green_deal_meta" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."internal_use" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."journals" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."journals_issn" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "journals_reader_can_select" ON "public"."journals" FOR SELECT TO "journals_reader" USING (true);

ALTER TABLE "public"."kb_schema_migrations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "select_policy" ON "public"."esg_meta" FOR SELECT TO "authenticated" USING (true);

ALTER TABLE "public"."standards" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;

GRANT ALL ON FUNCTION "public"."esg_full_text"("meta_contains" "text") TO "anon";

GRANT ALL ON FUNCTION "public"."esg_full_text"("meta_contains" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."esg_full_text"("meta_contains" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."has_service_role"("user_id" "uuid") TO "anon";

GRANT ALL ON FUNCTION "public"."has_service_role"("user_id" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."has_service_role"("user_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "public"."set_created_by"() TO "anon";

GRANT ALL ON FUNCTION "public"."set_created_by"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."set_created_by"() TO "service_role";

GRANT ALL ON FUNCTION "public"."set_last_updated_by"() TO "anon";

GRANT ALL ON FUNCTION "public"."set_last_updated_by"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."set_last_updated_by"() TO "service_role";

GRANT ALL ON FUNCTION "public"."set_last_updated_time"() TO "anon";

GRANT ALL ON FUNCTION "public"."set_last_updated_time"() TO "authenticated";

GRANT ALL ON FUNCTION "public"."set_last_updated_time"() TO "service_role";

GRANT ALL ON FUNCTION "public"."standards_full_text"("meta_contains" "text") TO "anon";

GRANT ALL ON FUNCTION "public"."standards_full_text"("meta_contains" "text") TO "authenticated";

GRANT ALL ON FUNCTION "public"."standards_full_text"("meta_contains" "text") TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_meta" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_meta" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_meta" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_textbooks" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_textbooks" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."edu_textbooks" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_category" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_category" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_category" TO "service_role";

GRANT SELECT ON TABLE "public"."esg_category" TO "out_user";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_country" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_country" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_country" TO "service_role";

GRANT SELECT ON TABLE "public"."esg_country" TO "out_user";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_meta" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_meta" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."esg_meta" TO "service_role";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."esg_meta" TO "out_user";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."green_deal_meta" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."green_deal_meta" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."green_deal_meta" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."internal_use" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."internal_use" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."internal_use" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals" TO "service_role";

GRANT SELECT ON TABLE "public"."journals" TO "journals_reader";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals_issn" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals_issn" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."journals_issn" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."kb_schema_migrations" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."kb_schema_migrations" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."kb_schema_migrations" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."reports" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."reports" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."reports" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."standards" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."standards" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."standards" TO "service_role";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."user_roles" TO "anon";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."user_roles" TO "authenticated";

GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."user_roles" TO "service_role";
-- PostgreSQL 17 fresh defaults include MAINTAIN; production grants do not.
REVOKE MAINTAIN ON TABLE public."edu_meta" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."edu_textbooks" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."esg_category" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."esg_country" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."esg_meta" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."green_deal_meta" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."internal_use" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."journals" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."journals_issn" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."reports" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."standards" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."user_roles" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_schema_migrations" FROM anon, authenticated, service_role;

-- Match production ACLs for the existing KB tables as well as the captured tables.
REVOKE MAINTAIN ON TABLE public."kb_api_keys" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_audit_events" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_collections" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_documents" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_grants" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_group_members" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_groups" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_index_records" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_jobs" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_query_logs" FROM anon, authenticated, service_role;
REVOKE MAINTAIN ON TABLE public."kb_search_partitions" FROM anon, authenticated, service_role;
SET check_function_bodies = true;
