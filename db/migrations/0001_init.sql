-- =====================================================================
-- CardioEMR  migration 0001_init   (draft v0.1, 2026-11-22)
-- PostgreSQL 16+.  Run as the schema owner role (cardioemr_owner).
-- Sections:
--   00 foundation: extensions, schemas, roles, session context, row meta
--   01 iam            02 ref            03 clinical: patients & consent
--   04 clinical: encounters, history     05 investigations & documents
--   06 medications    07 registry engine 08 heart failure 09 lipids
--   10 CAD procedures 11 clinical events & adjudication
--   12 audit          13 research        14 RLS            15 grants
--   16 reference seed data (DRAFT - clinical lead to verify)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 00  FOUNDATION
-- ---------------------------------------------------------------------
SET check_function_bodies = off;   -- wrappers may precede the helpers they call
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid, digest, hmac
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy name search within a centre

CREATE SCHEMA IF NOT EXISTS app;       -- helper functions only, no data
CREATE SCHEMA IF NOT EXISTS iam;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS clinical;
CREATE SCHEMA IF NOT EXISTS registry;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS research;

-- Database roles ------------------------------------------------------
-- cardioemr_api  : the only login the API uses. Owns nothing, NOBYPASSRLS,
--                  NOINHERIT: it has no privileges until it SET LOCAL ROLEs
--                  into exactly one group role per request.
-- r_*            : one group role per PRD user type. Never LOGIN.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['r_assistant','r_nurse','r_clinician',
      'r_research_coordinator','r_principal_investigator',
      'r_centre_admin','r_platform_admin','r_audit_reader'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOBYPASSRLS', r);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cardioemr_api') THEN
    CREATE ROLE cardioemr_api LOGIN NOINHERIT NOBYPASSRLS;
  END IF;
END $$;

GRANT r_assistant, r_nurse, r_clinician, r_research_coordinator,
      r_principal_investigator, r_centre_admin, r_platform_admin,
      r_audit_reader TO cardioemr_api;

-- Session context -----------------------------------------------------
-- Per request, inside the transaction, the API runs:
--   SET LOCAL ROLE r_clinician;
--   SELECT set_config('app.user_id',   '<uuid from verified JWT>', true);
--   SELECT set_config('app.centre_id', '<active centre uuid>',     true);
--   SELECT set_config('app.change_reason', '<optional text>',     true);
CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app.current_centre_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.centre_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app.change_reason() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.change_reason', true), '')
$$;

-- Maps the active database role back to the application role name.
CREATE OR REPLACE FUNCTION app.current_app_role() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_user::text LIKE 'r\_%' THEN substr(current_user::text, 3) END
$$;

-- Row metadata trigger: stamps updated_at/updated_by and bumps row_version.
CREATE OR REPLACE FUNCTION app.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at  := now();
  NEW.updated_by  := app.current_user_id();
  NEW.row_version := OLD.row_version + 1;
  NEW.created_at  := OLD.created_at;   -- creation stamp can never change
  NEW.created_by  := OLD.created_by;
  RETURN NEW;
END $$;

-- Insert-only guard for event-style tables (medication_events, audit, ...).
-- One exception: a confirmed patient link/merge cascades a new patient_id
-- into child rows; a change to patient_id alone is allowed.
CREATE OR REPLACE FUNCTION app.forbid_update_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'patient_id') = (to_jsonb(OLD) - 'patient_id') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION '% on %.% is not allowed: table is append-only',
    TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'insufficient_privilege';
END $$;
-- ---------------------------------------------------------------------
-- 01  IAM: organisations, centres, users, roles, study memberships
-- ---------------------------------------------------------------------
CREATE TABLE iam.organisations (
  organisation_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_name  text NOT NULL CHECK (length(organisation_name) BETWEEN 2 AND 200),
  organisation_type  text NOT NULL CHECK (organisation_type IN
                       ('solo_practice','clinic','hospital','hospital_group','research_network')),
  address            text,
  country_code       char(2) NOT NULL DEFAULT 'IN',
  subscription_plan  text CHECK (subscription_plan IN ('solo','clinic','hospital','research_network','enterprise','trial')),
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','closed')),
  closed_at          timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);

CREATE TABLE iam.centres (
  centre_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES iam.organisations ON DELETE RESTRICT,
  centre_name     text NOT NULL,
  centre_code     text NOT NULL CHECK (centre_code ~ '^[A-Z0-9]{2,10}$'),  -- used in local patient codes
  address         text,
  state_code      text,                          -- Indian state, for analytics
  contact_email   citext,
  contact_phone   text CHECK (contact_phone ~ '^\+?[0-9 ]{8,20}$'),
  timezone        text NOT NULL DEFAULT 'Asia/Kolkata',
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','closed')),
  closed_at       timestamptz,                   -- closing never deletes data
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (centre_code),
  UNIQUE (organisation_id, centre_id)            -- target for composite FKs
);

-- Users are global: one login can hold roles at centres of several
-- organisations (e.g. a cardiologist consulting at two hospitals, or a
-- network PI).  Organisation of record is kept for billing only.
CREATE TABLE iam.users (
  user_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_organisation_id uuid REFERENCES iam.organisations,
  full_name          text NOT NULL,
  email              citext NOT NULL UNIQUE,
  mobile             text,
  auth_provider      text NOT NULL DEFAULT 'oidc',
  auth_subject       text NOT NULL,              -- 'sub' claim from the identity provider
  professional_reg_no text,                      -- NMC / state medical council number
  platform_role      text CHECK (platform_role IN ('platform_admin')),
  mfa_required       boolean NOT NULL DEFAULT true,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('invited','active','suspended','deactivated')),
  last_login_at      timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (auth_provider, auth_subject)
);

-- Centre-specific permissions (PRD 8.1).  A user may hold several roles
-- at one centre; the API picks one per request and SET LOCAL ROLEs to r_<role>.
CREATE TABLE iam.user_centre_roles (
  user_centre_role_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES iam.users,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  role            text NOT NULL CHECK (role IN ('assistant','nurse','clinician',
                    'research_coordinator','principal_investigator','centre_admin')),
  valid_from      date NOT NULL DEFAULT current_date,
  valid_to        date,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  granted_by      uuid REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (organisation_id, centre_id) REFERENCES iam.centres (organisation_id, centre_id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX user_centre_roles_one_active
  ON iam.user_centre_roles (user_id, centre_id, role) WHERE status = 'active';
CREATE INDEX user_centre_roles_centre ON iam.user_centre_roles (centre_id);

-- Security-definer lookups used inside RLS policies.  Owned by the schema
-- owner so they read iam tables without recursing into iam RLS.
CREATE OR REPLACE FUNCTION app.user_has_role_at(p_centre uuid, p_role text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT EXISTS (
    SELECT 1 FROM iam.user_centre_roles ucr
    JOIN iam.users u USING (user_id)
    JOIN iam.centres c ON c.centre_id = ucr.centre_id
    WHERE ucr.user_id = app.current_user_id()
      AND ucr.centre_id = p_centre
      AND ucr.role = p_role
      AND ucr.status = 'active'
      AND current_date >= ucr.valid_from
      AND (ucr.valid_to IS NULL OR current_date <= ucr.valid_to)
      AND u.status = 'active'
      AND c.status <> 'closed')
$$;

-- IMPORTANT: current_user inside a SECURITY DEFINER function is the
-- owner, so anything that inspects the caller's role is an INVOKER
-- wrapper around a narrow DEFINER lookup that takes the role as input.

-- The one centre whose rows this request may touch: the active centre,
-- but only if the user really holds the role the API switched into.
CREATE OR REPLACE FUNCTION app.visible_centre() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN app.user_has_role_at(app.current_centre_id(), app.current_app_role())
              THEN app.current_centre_id() END
$$;

CREATE OR REPLACE FUNCTION app._centre_organisation(p_centre uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT organisation_id FROM iam.centres WHERE centre_id = p_centre
$$;

CREATE OR REPLACE FUNCTION app.visible_organisation() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT app._centre_organisation(app.visible_centre())
$$;

CREATE OR REPLACE FUNCTION app._user_is_platform_admin(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT EXISTS (SELECT 1 FROM iam.users WHERE user_id = p_user
                 AND platform_role = 'platform_admin' AND status = 'active')
$$;

CREATE OR REPLACE FUNCTION app.is_platform_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT current_user::text = 'r_platform_admin' AND app._user_is_platform_admin(app.current_user_id())
$$;
-- ---------------------------------------------------------------------
-- 02  REF: terminology, analytes, drugs, versioned clinical rule tables
-- Read-only to clinical roles; written by platform admins (reference
-- curators).  Rows are never edited once 'active': publish a new version.
-- ---------------------------------------------------------------------

-- Local controlled terminology with mappings to ICD-10 / ICD-11 / SNOMED CT.
CREATE TABLE ref.concepts (
  concept_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  concept_code   text NOT NULL UNIQUE,          -- stable local code, e.g. 'DX_HF', 'CX_CHEST_PAIN'
  domain         text NOT NULL CHECK (domain IN ('diagnosis','complaint','procedure','aetiology',
                   'event','reason','finding','category','risk_factor','other')),
  display_name   text NOT NULL,
  parent_concept_id uuid REFERENCES ref.concepts,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','retired')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);

CREATE TABLE ref.concept_mappings (
  concept_id   uuid NOT NULL REFERENCES ref.concepts,
  code_system  text NOT NULL CHECK (code_system IN ('ICD-10','ICD-11','SNOMED-CT','LOINC','ATC','FHIR')),
  code         text NOT NULL,
  map_type     text NOT NULL DEFAULT 'equivalent' CHECK (map_type IN ('equivalent','broader','narrower')),
  PRIMARY KEY (concept_id, code_system, code)
);

-- Which diagnosis concepts prompt which registry's eligibility check (PRD 10.3).
CREATE TABLE ref.concept_registry_triggers (
  concept_id    uuid NOT NULL REFERENCES ref.concepts,
  registry_code text NOT NULL CHECK (registry_code IN ('HF','LIPID','CAD')),
  PRIMARY KEY (concept_id, registry_code)
);

-- Laboratory and measurement analytes.
CREATE TABLE ref.analytes (
  analyte_code    text PRIMARY KEY,             -- 'LDL_C', 'NT_PROBNP', 'EGFR' ...
  analyte_name    text NOT NULL,
  loinc_code      text,
  panel           text CHECK (panel IN ('lipid','renal','biomarker','diabetes','haematology',
                    'electrolyte','liver','muscle','thyroid','other')),
  canonical_unit  text NOT NULL,
  value_kind      text NOT NULL DEFAULT 'numeric' CHECK (value_kind IN ('numeric','text','coded')),
  plausible_min   numeric,                      -- hard validation limits in canonical unit
  plausible_max   numeric,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);

CREATE TABLE ref.unit_conversions (
  analyte_code   text NOT NULL REFERENCES ref.analytes,
  from_unit      text NOT NULL,
  factor_to_canonical numeric NOT NULL CHECK (factor_to_canonical > 0),  -- canonical = value * factor
  PRIMARY KEY (analyte_code, from_unit)
);

-- Drugs.  One row per generic medicinal concept, including fixed-dose
-- combinations (sacubitril/valsartan, rosuvastatin/ezetimibe).  Dose
-- arithmetic uses the drug's reference ingredient and unit.
CREATE TABLE ref.drugs (
  drug_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  drug_code          text NOT NULL UNIQUE,      -- 'SACUBITRIL_VALSARTAN'
  generic_name       text NOT NULL,
  atc_code           text,
  is_combination     boolean NOT NULL DEFAULT false,
  reference_ingredient text NOT NULL,           -- 'sacubitril+valsartan (labelled total)', 'rosuvastatin'
  reference_unit     text NOT NULL DEFAULT 'mg',
  default_route      text NOT NULL DEFAULT 'oral',
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);

-- A drug can sit in several classes (combination products).
CREATE TABLE ref.drug_classes (
  drug_class_code text PRIMARY KEY,             -- 'ARNI','ACEI','ARB','BETA_BLOCKER','MRA','SGLT2I','STATIN',...
  display_name    text NOT NULL
);
CREATE TABLE ref.drug_class_members (
  drug_id         uuid NOT NULL REFERENCES ref.drugs,
  drug_class_code text NOT NULL REFERENCES ref.drug_classes,
  PRIMARY KEY (drug_id, drug_class_code)
);

-- Branded products available in India (optional on a prescription).
CREATE TABLE ref.drug_products (
  product_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  drug_id           uuid NOT NULL REFERENCES ref.drugs,
  brand_name        text NOT NULL,
  manufacturer      text,
  strength_label    text NOT NULL,              -- as printed: '49/51 mg', '10 mg'
  reference_strength numeric NOT NULL CHECK (reference_strength > 0),  -- in drugs.reference_unit
  dose_form         text NOT NULL DEFAULT 'tablet',
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
CREATE INDEX drug_products_brand_trgm ON ref.drug_products USING gin (brand_name gin_trgm_ops);

-- Generic version container for every rule table below (PRD 4.4: target
-- doses "configurable, version-controlled").
CREATE TABLE ref.rule_sets (
  rule_set_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_kind      text NOT NULL CHECK (rule_kind IN ('hf_target_dose','statin_intensity','ldl_target')),
  rule_set_code  text NOT NULL,                 -- 'ESC_HF_2021', 'ACC_AHA_2018', 'ESC_EAS_2019'
  version        integer NOT NULL CHECK (version > 0),
  title          text NOT NULL,
  source_citation text,
  effective_from date NOT NULL,
  effective_to   date,
  status         text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','retired')),
  approved_by    uuid,
  approved_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (rule_kind, rule_set_code, version),
  CHECK (status <> 'active' OR approved_at IS NOT NULL)
);

-- HF GDMT: which drugs count toward which pillar, and their target dose.
CREATE TABLE ref.gdmt_pillars (
  pillar_code  text PRIMARY KEY CHECK (pillar_code IN ('RASI','BB','MRA','SGLT2I')),
  display_name text NOT NULL,
  sort_order   smallint NOT NULL
);

CREATE TABLE ref.hf_target_doses (
  rule_set_id        uuid NOT NULL REFERENCES ref.rule_sets,
  drug_id            uuid NOT NULL REFERENCES ref.drugs,
  pillar_code        text NOT NULL REFERENCES ref.gdmt_pillars,
  evidence_based     boolean NOT NULL DEFAULT true,  -- e.g. metoprolol tartrate = false
  target_daily_dose  numeric NOT NULL CHECK (target_daily_dose > 0),  -- in drug reference unit
  target_frequency   text,                     -- 'BD', 'OD' (display only)
  start_daily_dose   numeric,
  notes              text,                     -- e.g. 'carvedilol 50 mg BD if weight > 85 kg'
  PRIMARY KEY (rule_set_id, drug_id)
);

-- Which pillars count as "eligible" per HF phenotype (decision D9).
CREATE TABLE ref.hf_pillar_eligibility (
  rule_set_id  uuid NOT NULL REFERENCES ref.rule_sets,
  hf_phenotype text NOT NULL CHECK (hf_phenotype IN ('HFrEF','HFmrEF','HFpEF','HFimpEF')),
  pillar_code  text NOT NULL REFERENCES ref.gdmt_pillars,
  recommendation_class text,                   -- 'I', 'IIa', 'IIb'
  PRIMARY KEY (rule_set_id, hf_phenotype, pillar_code)
);

CREATE TABLE ref.statin_intensity_rules (
  rule_set_id    uuid NOT NULL REFERENCES ref.rule_sets,
  drug_id        uuid NOT NULL REFERENCES ref.drugs,
  min_daily_dose numeric NOT NULL,
  max_daily_dose numeric NOT NULL,
  intensity      text NOT NULL CHECK (intensity IN ('low','moderate','high')),
  PRIMARY KEY (rule_set_id, drug_id, min_daily_dose),
  CHECK (max_daily_dose >= min_daily_dose)
);

CREATE TABLE ref.ldl_target_rules (
  rule_set_id        uuid NOT NULL REFERENCES ref.rule_sets,
  risk_category      text NOT NULL,             -- 'very_high','high','moderate','low','extreme_a' ...
  ldl_target_mg_dl   numeric NOT NULL CHECK (ldl_target_mg_dl > 0),
  target_operator    text NOT NULL DEFAULT '<' CHECK (target_operator IN ('<','<=')),
  min_pct_reduction  numeric CHECK (min_pct_reduction BETWEEN 0 AND 100),  -- e.g. 50
  non_hdl_target_mg_dl numeric,
  apob_target_mg_dl  numeric,
  PRIMARY KEY (rule_set_id, risk_category)
);

-- Stent catalogue for the CAD registry.
CREATE TABLE ref.stent_devices (
  stent_device_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manufacturer    text NOT NULL,
  platform_name   text NOT NULL,
  device_type     text NOT NULL CHECK (device_type IN ('DES','BMS','BVS','DCB','covered')),
  drug            text,
  strut_material  text,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  UNIQUE (manufacturer, platform_name)
);
-- ---------------------------------------------------------------------
-- 03  CLINICAL: patients, centre registrations, identity linkage, consent
-- Identity model (decision D1): `patients` is a bare master person record
-- with no identifiers.  Each centre holds its own registration with its
-- own copy of demographics.  Centre B never reads centre A's registration.
-- ---------------------------------------------------------------------
CREATE SEQUENCE clinical.master_patient_seq;

CREATE TABLE clinical.patients (
  patient_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  master_patient_code text NOT NULL UNIQUE
                      DEFAULT 'CE' || lpad(nextval('clinical.master_patient_seq')::text, 9, '0'),
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','merged','entered_in_error')),
  merged_into_patient_id uuid REFERENCES clinical.patients,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  CHECK ((status = 'merged') = (merged_into_patient_id IS NOT NULL))
);

-- PRD "patient_centre_links", extended to hold the centre's demographics.
CREATE TABLE clinical.patient_registrations (
  registration_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id         uuid NOT NULL REFERENCES clinical.patients ON UPDATE CASCADE,
  organisation_id    uuid NOT NULL,
  centre_id          uuid NOT NULL,
  local_patient_code text NOT NULL,              -- centre's own MRN / UHID
  registration_date  date NOT NULL DEFAULT current_date,
  first_name         text NOT NULL,
  middle_name        text,
  last_name          text,                       -- optional: many patients have a single name
  date_of_birth      date,
  dob_precision      text NOT NULL DEFAULT 'day' CHECK (dob_precision IN ('day','month','year','estimated_from_age')),
  sex                text NOT NULL CHECK (sex IN ('male','female','other','unknown')),
  mobile             text CHECK (mobile ~ '^\+?[0-9]{10,15}$'),
  alternate_mobile   text CHECK (alternate_mobile ~ '^\+?[0-9]{10,15}$'),
  email              citext,
  address_line       text,
  city               text,
  district           text,
  state_code         text,
  pincode            text CHECK (pincode ~ '^[1-9][0-9]{5}$'),
  abha_number        text CHECK (abha_number ~ '^[0-9]{14}$'),
  abha_address       text,
  emergency_contact_name     text,
  emergency_contact_relation text,
  emergency_contact_phone    text,
  occupation         text,
  referral_source    text CHECK (referral_source IN ('self','physician','cardiologist','hospital',
                       'camp','insurer','other')),
  referral_detail    text,
  linkage_status     text NOT NULL DEFAULT 'unlinked'
                     CHECK (linkage_status IN ('unlinked','possible_match','linked','confirmed_distinct')),
  status             text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','inactive','transferred_out','deceased','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (organisation_id, centre_id) REFERENCES iam.centres (organisation_id, centre_id),
  UNIQUE (centre_id, local_patient_code),
  UNIQUE (patient_id, centre_id),                -- one registration per person per centre; FK target
  CHECK (date_of_birth IS NULL OR date_of_birth BETWEEN date '1900-01-01' AND current_date)
);
CREATE INDEX patient_registrations_centre_name_trgm ON clinical.patient_registrations
  USING gin ((lower(first_name || ' ' || coalesce(last_name, ''))) gin_trgm_ops);
CREATE INDEX patient_registrations_centre_mobile ON clinical.patient_registrations (centre_id, mobile);
CREATE INDEX patient_registrations_centre_dob ON clinical.patient_registrations (centre_id, date_of_birth);

-- Per-centre counter for local codes like 'PUN1-000123'.
CREATE TABLE clinical.centre_code_counters (
  centre_id  uuid PRIMARY KEY REFERENCES iam.centres,
  last_value bigint NOT NULL DEFAULT 0
);

-- Cross-centre matching without exposing identifiers (PRD 9).  The API
-- computes HMAC-SHA256(normalised value, pepper) with a pepper held in the
-- cloud KMS, never in the database.  No application role can SELECT this
-- table; matching runs only through clinical.find_match_candidates().
CREATE TABLE clinical.patient_match_keys (
  registration_id uuid NOT NULL REFERENCES clinical.patient_registrations ON DELETE CASCADE,
  key_type        text NOT NULL CHECK (key_type IN ('abha','mobile','name_dob','name_yob_sex')),
  key_hmac        bytea NOT NULL,
  PRIMARY KEY (registration_id, key_type)
);
CREATE INDEX patient_match_keys_lookup ON clinical.patient_match_keys (key_type, key_hmac);

CREATE TABLE clinical.patient_link_requests (
  link_request_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registration_id    uuid NOT NULL REFERENCES clinical.patient_registrations,
  organisation_id    uuid NOT NULL,
  centre_id          uuid NOT NULL,              -- requesting centre
  candidate_patient_id uuid NOT NULL REFERENCES clinical.patients,
  matched_key_types  text[] NOT NULL,
  linkage_consent_id uuid,                       -- FK added below (cross_centre_linkage consent)
  status             text NOT NULL DEFAULT 'proposed'
                     CHECK (status IN ('proposed','confirmed','rejected','withdrawn')),
  decided_by         uuid REFERENCES iam.users,
  decided_at         timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);

-- Consent.  Clinical care and research are separate rows (PRD 8.2, 14).
CREATE TABLE clinical.patient_consents (
  consent_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  consent_type     text NOT NULL CHECK (consent_type IN ('clinical_care','research_registry',
                     'cross_centre_linkage','external_data_sharing','ai_processing','recontact')),
  protocol_id      uuid,                         -- FK added in section 07
  consent_form_version text NOT NULL,            -- version of the EC-approved form / notice
  consent_language text,
  consent_date     date NOT NULL,
  consent_method   text NOT NULL CHECK (consent_method IN ('written','electronic','audio_video',
                     'verbal_witnessed','waiver_approved')),
  signed_by        text NOT NULL DEFAULT 'patient' CHECK (signed_by IN ('patient','legally_authorised_rep')),
  lar_name         text,
  lar_relation     text,
  witness_name     text,
  document_id      uuid,                         -- scanned form; FK added in section 05
  consent_status   text NOT NULL DEFAULT 'active'
                   CHECK (consent_status IN ('active','refused','withdrawn','expired','superseded')),
  withdrawal_date  date,
  withdrawal_scope text CHECK (withdrawal_scope IN ('no_further_contact','no_further_collection',
                     'exclude_collected_data')),
  withdrawal_reason text,
  recorded_by      uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  CHECK ((consent_type = 'research_registry') = (protocol_id IS NOT NULL)),
  CHECK ((consent_status = 'withdrawn') = (withdrawal_date IS NOT NULL AND withdrawal_scope IS NOT NULL)),
  CHECK (withdrawal_date IS NULL OR withdrawal_date >= consent_date),
  CHECK (signed_by = 'patient' OR lar_name IS NOT NULL)
);
CREATE INDEX patient_consents_patient ON clinical.patient_consents (patient_id, consent_type);
CREATE INDEX patient_consents_centre ON clinical.patient_consents (centre_id);
CREATE INDEX patient_consents_protocol ON clinical.patient_consents (protocol_id) WHERE protocol_id IS NOT NULL;

ALTER TABLE clinical.patient_link_requests
  ADD FOREIGN KEY (linkage_consent_id) REFERENCES clinical.patient_consents;

-- Appointments (in the PRD's navigation and dashboard, missing from Part C).
CREATE TABLE clinical.appointments (
  appointment_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  clinician_id     uuid REFERENCES iam.users,
  scheduled_start  timestamptz NOT NULL,
  duration_minutes smallint NOT NULL DEFAULT 15 CHECK (duration_minutes BETWEEN 5 AND 480),
  appointment_type text NOT NULL CHECK (appointment_type IN ('new','follow_up','registry_visit',
                     'investigation','procedure','teleconsultation')),
  registry_assessment_id uuid,                   -- FK added in section 07
  encounter_id     uuid,                         -- FK added in section 04
  status           text NOT NULL DEFAULT 'booked' CHECK (status IN ('booked','confirmed','arrived',
                     'in_consultation','completed','cancelled','no_show','rescheduled')),
  notes            text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);
CREATE INDEX appointments_centre_day ON clinical.appointments (centre_id, scheduled_start);
CREATE INDEX appointments_patient ON clinical.appointments (patient_id);
-- ---------------------------------------------------------------------
-- 04  CLINICAL: encounters, vitals, clinical status, diagnoses, history
-- Every patient-data table carries patient_id + centre_id with a composite
-- FK to the centre's registration (ON UPDATE CASCADE so a confirmed link
-- or merge re-points rows in one statement).
-- ---------------------------------------------------------------------
CREATE TABLE clinical.encounters (
  encounter_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  clinician_id     uuid NOT NULL REFERENCES iam.users,      -- responsible clinician
  encounter_type   text NOT NULL CHECK (encounter_type IN ('new_consultation','follow_up',
                     'registry_visit','teleconsultation','telephone','inpatient_review',
                     'emergency','procedure','retrospective_entry')),
  setting          text NOT NULL DEFAULT 'outpatient' CHECK (setting IN ('outpatient','inpatient','emergency','remote')),
  encounter_start  timestamptz NOT NULL DEFAULT now(),
  encounter_end    timestamptz,
  presenting_complaint text,
  history_present_illness text,
  clinical_history text,
  examination_cvs  text,
  examination_resp text,
  examination_other text,
  assessment       text,
  plan             text,
  lifestyle_advice text,
  patient_education text,
  referral_to      text,
  follow_up_date   date,
  ai_draft_id      uuid,                         -- FK added in section 05
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','signed','amended','entered_in_error')),
  signed_at        timestamptz,
  signed_by        uuid REFERENCES iam.users,
  error_reason     text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  UNIQUE (encounter_id, patient_id, centre_id),  -- FK target so children cannot cross patients
  CHECK ((status IN ('signed','amended')) = (signed_at IS NOT NULL AND signed_by IS NOT NULL)
         OR status = 'entered_in_error'),
  CHECK (status <> 'entered_in_error' OR error_reason IS NOT NULL),
  CHECK (encounter_end IS NULL OR encounter_end >= encounter_start)
);
CREATE INDEX encounters_patient_time ON clinical.encounters (patient_id, encounter_start DESC);
CREATE INDEX encounters_centre_time ON clinical.encounters (centre_id, encounter_start DESC);
CREATE INDEX encounters_clinician ON clinical.encounters (clinician_id, encounter_start DESC);

ALTER TABLE clinical.appointments
  ADD FOREIGN KEY (encounter_id) REFERENCES clinical.encounters;

-- Corrections to a signed encounter never overwrite it (PRD 14, 18).
CREATE TABLE clinical.encounter_amendments (
  amendment_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  encounter_id   uuid NOT NULL,
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  field_name     text NOT NULL,
  previous_value text,
  amended_value  text,
  reason         text NOT NULL CHECK (length(reason) >= 5),
  amended_by     uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  amended_at     timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE
);
CREATE INDEX encounter_amendments_encounter ON clinical.encounter_amendments (encounter_id);

-- Structured presenting complaints (PRD Module 2A).
CREATE TABLE clinical.encounter_complaints (
  encounter_complaint_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  encounter_id   uuid NOT NULL,
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  complaint_concept_id uuid NOT NULL REFERENCES ref.concepts,
  duration_value numeric CHECK (duration_value >= 0),
  duration_unit  text CHECK (duration_unit IN ('hours','days','weeks','months','years')),
  detail         text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (encounter_id, complaint_concept_id)
);

CREATE TABLE clinical.vital_signs (
  vital_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  encounter_id   uuid,
  measured_at    timestamptz NOT NULL DEFAULT now(),
  height_cm      numeric(4,1) CHECK (height_cm BETWEEN 50 AND 250),
  weight_kg      numeric(5,1) CHECK (weight_kg BETWEEN 2 AND 350),
  bmi            numeric(4,1) GENERATED ALWAYS AS
                   (round(weight_kg / ((height_cm / 100.0) ^ 2), 1)) STORED,
  waist_cm       numeric(4,1) CHECK (waist_cm BETWEEN 30 AND 250),
  systolic_bp    smallint CHECK (systolic_bp BETWEEN 50 AND 300),
  diastolic_bp   smallint CHECK (diastolic_bp BETWEEN 20 AND 200),
  bp_position    text CHECK (bp_position IN ('sitting','supine','standing')),
  heart_rate     smallint CHECK (heart_rate BETWEEN 20 AND 300),
  pulse_rhythm   text CHECK (pulse_rhythm IN ('regular','irregular')),
  respiratory_rate smallint CHECK (respiratory_rate BETWEEN 4 AND 80),
  spo2           smallint CHECK (spo2 BETWEEN 40 AND 100),
  temperature_c  numeric(3,1) CHECK (temperature_c BETWEEN 30 AND 45),
  source         text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','device','ai_extracted','imported')),
  recorded_by    uuid DEFAULT app.current_user_id() REFERENCES iam.users,
  status         text NOT NULL DEFAULT 'final' CHECK (status IN ('final','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (diastolic_bp IS NULL OR systolic_bp IS NULL OR diastolic_bp < systolic_bp)
);
CREATE INDEX vital_signs_patient_time ON clinical.vital_signs (patient_id, measured_at DESC);
CREATE INDEX vital_signs_centre ON clinical.vital_signs (centre_id);

-- Structured clinical classification per encounter (PRD Module 2C-D).
CREATE TABLE clinical.clinical_assessments (
  clinical_assessment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  encounter_id   uuid NOT NULL,
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  nyha_class     text CHECK (nyha_class IN ('I','II','III','IV')),
  ccs_class      text CHECK (ccs_class IN ('0','I','II','III','IV')),
  killip_class   text CHECK (killip_class IN ('I','II','III','IV')),
  jvp            text CHECK (jvp IN ('normal','raised','not_assessable')),
  jvp_cm         numeric(3,1),
  peripheral_oedema text CHECK (peripheral_oedema IN ('none','ankle','below_knee','above_knee','sacral','anasarca')),
  pulmonary_rales boolean,
  s3_gallop      boolean,
  orthopnoea     boolean,
  pnd            boolean,
  congestion_status text CHECK (congestion_status IN ('euvolaemic','mild','moderate','severe')),
  hf_phenotype   text CHECK (hf_phenotype IN ('HFrEF','HFmrEF','HFpEF','HFimpEF')),
  hf_phenotype_basis_lvef_id uuid,               -- echo_reports row it was based on (section 05)
  cv_risk_category text,
  cv_risk_rule_set_id uuid REFERENCES ref.rule_sets,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (encounter_id)
);
CREATE INDEX clinical_assessments_patient ON clinical.clinical_assessments (patient_id);

-- Diagnoses and comorbidities.  DM, HTN, CKD, AF, anaemia, stroke, PAD are
-- all rows here, distinguished by concept, so registries derive them.
CREATE TABLE clinical.diagnoses (
  diagnosis_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  encounter_id   uuid,
  concept_id     uuid REFERENCES ref.concepts,
  diagnosis_text text NOT NULL,                  -- as written by the clinician
  icd10_code     text,                           -- snapshot at time of coding
  icd11_code     text,
  diagnosis_role text NOT NULL CHECK (diagnosis_role IN ('working','final','comorbidity',
                   'past_history','complication')),
  certainty      text NOT NULL DEFAULT 'confirmed' CHECK (certainty IN ('suspected','confirmed','refuted')),
  is_principal   boolean NOT NULL DEFAULT false,
  onset_date     date,
  onset_precision text CHECK (onset_precision IN ('day','month','year')),
  resolved_date  date,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','resolved','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (concept_id IS NOT NULL OR icd10_code IS NOT NULL OR diagnosis_role = 'working'),
  CHECK ((onset_date IS NULL) = (onset_precision IS NULL)),
  CHECK (resolved_date IS NULL OR onset_date IS NULL OR resolved_date >= onset_date)
);
CREATE INDEX diagnoses_patient ON clinical.diagnoses (patient_id, status);
CREATE INDEX diagnoses_concept ON clinical.diagnoses (concept_id) WHERE status = 'active';
CREATE INDEX diagnoses_centre ON clinical.diagnoses (centre_id);

-- Tobacco, alcohol, activity: dated observations, not patient columns.
CREATE TABLE clinical.lifestyle_observations (
  lifestyle_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  encounter_id   uuid,
  observed_on    date NOT NULL DEFAULT current_date,
  smoking_status text CHECK (smoking_status IN ('never','former','current','unknown')),
  smoking_forms  text[] CHECK (smoking_forms <@ ARRAY['cigarette','bidi','hookah','cigar','e_cigarette']),
  pack_years     numeric(4,1) CHECK (pack_years BETWEEN 0 AND 200),
  smoking_quit_year smallint,
  smokeless_tobacco_status text CHECK (smokeless_tobacco_status IN ('never','former','current','unknown')),
  smokeless_forms text[],                        -- gutka, khaini, paan with tobacco ...
  alcohol_status text CHECK (alcohol_status IN ('never','former','occasional','regular','heavy','unknown')),
  alcohol_units_per_week numeric(4,1),
  physical_activity text CHECK (physical_activity IN ('sedentary','low','moderate','high','unknown')),
  activity_minutes_per_week smallint,
  diet_pattern   text CHECK (diet_pattern IN ('vegetarian','non_vegetarian','eggetarian','vegan','other')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);
CREATE INDEX lifestyle_patient ON clinical.lifestyle_observations (patient_id, observed_on DESC);

CREATE TABLE clinical.family_history (
  family_history_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  relation       text NOT NULL CHECK (relation IN ('father','mother','brother','sister','son','daughter',
                   'grandparent','other_first_degree','other')),
  condition_concept_id uuid REFERENCES ref.concepts,
  condition_text text NOT NULL,
  age_at_onset   smallint CHECK (age_at_onset BETWEEN 0 AND 120),
  is_premature   boolean,      -- derived: male < 55, female < 65 for ASCVD
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);

CREATE TABLE clinical.allergies (
  allergy_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  allergen_type  text NOT NULL CHECK (allergen_type IN ('drug','drug_class','contrast','food','other')),
  drug_id        uuid REFERENCES ref.drugs,
  drug_class_code text REFERENCES ref.drug_classes,
  allergen_text  text NOT NULL,
  reaction       text,
  severity       text CHECK (severity IN ('mild','moderate','severe','anaphylaxis')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);
CREATE INDEX allergies_patient ON clinical.allergies (patient_id) WHERE status = 'active';

-- Implanted cardiac devices (HF data dictionary: ICD, CRT-P, CRT-D, pacemaker).
CREATE TABLE clinical.cardiac_devices (
  device_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  device_type    text NOT NULL CHECK (device_type IN ('PPM','ICD','CRT_P','CRT_D','CSP','CCM','LVAD','ILR','WCD')),
  indication     text CHECK (indication IN ('primary_prevention','secondary_prevention','bradycardia',
                   'resynchronisation','diagnostic','other')),
  implant_date   date,
  implant_date_precision text CHECK (implant_date_precision IN ('day','month','year')),
  explant_date   date,
  manufacturer   text,
  model          text,
  implanting_centre_text text,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','explanted','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  CHECK (explant_date IS NULL OR implant_date IS NULL OR explant_date >= implant_date)
);
CREATE INDEX cardiac_devices_patient ON clinical.cardiac_devices (patient_id);
-- ---------------------------------------------------------------------
-- 05  CLINICAL: documents, AI extraction, investigations, results
-- Every measurement carries value, unit, collection date, source,
-- reporting centre/facility and verification status (PRD Module 3).
-- ---------------------------------------------------------------------
CREATE TABLE clinical.documents (
  document_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  encounter_id    uuid,
  storage_key     text NOT NULL UNIQUE,          -- object-store key; never a public URL
  mime_type       text NOT NULL CHECK (mime_type IN ('application/pdf','image/jpeg','image/png',
                    'audio/webm','audio/mpeg','audio/wav')),
  size_bytes      bigint NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 52428800),  -- 50 MB cap
  sha256          bytea NOT NULL CHECK (length(sha256) = 32),
  document_category text NOT NULL CHECK (document_category IN ('echo_report','lab_report','ecg',
                    'angiography_report','pci_report','ct_report','discharge_summary','prescription',
                    'referral_letter','consent_form','dictation_audio','other')),
  document_date   date,                          -- date on the report, not upload date
  external_facility text,                        -- outside lab / hospital that produced it
  uploaded_by     uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  uploaded_at     timestamptz NOT NULL DEFAULT now(),
  malware_scan_status text NOT NULL DEFAULT 'pending' CHECK (malware_scan_status IN ('pending','clean','infected')),
  verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN ('unverified','verified','rejected')),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE
);
CREATE INDEX documents_patient ON clinical.documents (patient_id, document_date DESC);
CREATE INDEX documents_centre ON clinical.documents (centre_id);
CREATE UNIQUE INDEX documents_no_duplicate_upload ON clinical.documents (patient_id, sha256)
  WHERE status = 'active';

ALTER TABLE clinical.patient_consents ADD FOREIGN KEY (document_id) REFERENCES clinical.documents;

-- AI runs: dictation structuring and report extraction (PRD Part E).
CREATE TABLE clinical.ai_jobs (
  ai_job_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  job_type        text NOT NULL CHECK (job_type IN ('dictation_transcription','consultation_structuring',
                    'report_extraction')),
  document_id     uuid REFERENCES clinical.documents,   -- source report or audio
  encounter_id    uuid,
  model_provider  text NOT NULL,
  model_name      text NOT NULL,
  model_version   text,
  prompt_version  text NOT NULL,
  requested_by    uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  requested_at    timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  status          text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','completed','failed','discarded')),
  output_text     text,                          -- transcript or structured draft (JSON as text)
  error_message   text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);
CREATE INDEX ai_jobs_patient ON clinical.ai_jobs (patient_id);

ALTER TABLE clinical.encounters ADD FOREIGN KEY (ai_draft_id) REFERENCES clinical.ai_jobs;

-- One row per value the AI proposes.  Nothing reaches a clinical table
-- until a human accepts it; written_table/written_row_id then point at it.
CREATE TABLE clinical.ai_extracted_fields (
  extracted_field_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ai_job_id       uuid NOT NULL REFERENCES clinical.ai_jobs ON DELETE CASCADE,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  target_table    text NOT NULL,                 -- 'lab_results','echo_reports','vital_signs','medication_events',...
  target_field    text NOT NULL,                 -- 'lvef','LDL_C', ...
  extracted_text  text NOT NULL,                 -- verbatim value as found
  extracted_numeric numeric,
  extracted_unit  text,
  confidence      numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
  source_page     smallint,
  source_snippet  text,
  extracted_at    timestamptz NOT NULL DEFAULT now(),
  review_status   text NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending','accepted','edited','rejected')),
  reviewed_by     uuid REFERENCES iam.users,
  reviewed_at     timestamptz,
  accepted_value_text text,
  written_table   text,
  written_row_id  uuid,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  CHECK (review_status = 'pending' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)),
  CHECK (review_status NOT IN ('accepted','edited') OR written_row_id IS NOT NULL)
);
CREATE INDEX ai_extracted_fields_job ON clinical.ai_extracted_fields (ai_job_id);
CREATE INDEX ai_extracted_fields_pending ON clinical.ai_extracted_fields (centre_id) WHERE review_status = 'pending';

CREATE TABLE clinical.investigations (
  investigation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,                 -- centre that holds this record
  encounter_id    uuid,                          -- optional: results often arrive between visits
  investigation_type text NOT NULL CHECK (investigation_type IN ('ecg','echo','lab','holter',
                    'stress_test','ctca','coronary_angiography','cmr','nuclear','chest_xray','other')),
  order_status    text NOT NULL DEFAULT 'resulted' CHECK (order_status IN ('ordered','resulted','cancelled')),
  ordered_by      uuid REFERENCES iam.users,
  ordered_at      timestamptz,
  performed_on    date,                          -- collection / test date
  performed_at_time timestamptz,
  reporting_centre_id uuid REFERENCES iam.centres,     -- when done at a CardioEMR centre
  reporting_facility text,                       -- outside lab / hospital name
  source          text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ai_extracted','lab_interface',
                    'device','imported')),
  source_document_id uuid REFERENCES clinical.documents,
  ai_job_id       uuid REFERENCES clinical.ai_jobs,
  verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN ('unverified','verified','rejected')),
  verified_by     uuid REFERENCES iam.users,
  verified_at     timestamptz,
  summary         text,
  status          text NOT NULL DEFAULT 'final' CHECK (status IN ('preliminary','final','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (investigation_id, patient_id, centre_id),
  CHECK (order_status <> 'resulted' OR performed_on IS NOT NULL),
  CHECK (source <> 'ai_extracted' OR ai_job_id IS NOT NULL),
  CHECK ((verification_status = 'verified') = (verified_by IS NOT NULL AND verified_at IS NOT NULL)
         OR verification_status = 'rejected')
);
CREATE INDEX investigations_patient_type_date ON clinical.investigations (patient_id, investigation_type, performed_on DESC);
CREATE INDEX investigations_centre ON clinical.investigations (centre_id);
CREATE INDEX investigations_unverified ON clinical.investigations (centre_id) WHERE verification_status = 'unverified';

-- One row per analyte (PRD 8.4): serial results are a simple time series.
CREATE TABLE clinical.lab_results (
  result_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  investigation_id uuid NOT NULL,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  analyte_code    text NOT NULL REFERENCES ref.analytes,
  collected_at    timestamptz NOT NULL,
  comparator      text NOT NULL DEFAULT '=' CHECK (comparator IN ('=','<','<=','>','>=')),
  value_reported  numeric,                       -- as printed on the report
  unit_reported   text,
  value_text      text,                          -- for qualitative results
  value_canonical numeric,                       -- converted by trigger to analytes.canonical_unit
  method          text CHECK (method IN ('direct','friedewald','martin_hopkins','sampson','calculated',
                    'immunoassay','other')),
  fasting         boolean,
  reference_low   numeric,
  reference_high  numeric,
  reference_text  text,
  abnormal_flag   text CHECK (abnormal_flag IN ('N','L','H','LL','HH','A')),
  source          text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ai_extracted','lab_interface','calculated','imported')),
  verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN ('unverified','verified','rejected')),
  verified_by     uuid REFERENCES iam.users,
  verified_at     timestamptz,
  status          text NOT NULL DEFAULT 'final' CHECK (status IN ('preliminary','final','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (investigation_id, patient_id, centre_id)
    REFERENCES clinical.investigations (investigation_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (value_reported IS NOT NULL OR value_text IS NOT NULL),
  CHECK (value_reported IS NULL OR unit_reported IS NOT NULL)
);
CREATE INDEX lab_results_patient_analyte_time ON clinical.lab_results (patient_id, analyte_code, collected_at DESC)
  WHERE status <> 'entered_in_error';
CREATE INDEX lab_results_centre ON clinical.lab_results (centre_id);

CREATE OR REPLACE FUNCTION clinical.lab_result_canonicalise() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_canonical text; v_factor numeric; v_min numeric; v_max numeric;
BEGIN
  IF NEW.value_reported IS NULL THEN NEW.value_canonical := NULL; RETURN NEW; END IF;
  SELECT canonical_unit, plausible_min, plausible_max INTO v_canonical, v_min, v_max
    FROM ref.analytes WHERE analyte_code = NEW.analyte_code;
  IF NEW.unit_reported = v_canonical THEN
    v_factor := 1;
  ELSE
    SELECT factor_to_canonical INTO v_factor FROM ref.unit_conversions
     WHERE analyte_code = NEW.analyte_code AND from_unit = NEW.unit_reported;
    IF v_factor IS NULL THEN
      RAISE EXCEPTION 'Unknown unit % for analyte %', NEW.unit_reported, NEW.analyte_code
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  NEW.value_canonical := round(NEW.value_reported * v_factor, 4);
  IF (v_min IS NOT NULL AND NEW.value_canonical < v_min) OR (v_max IS NOT NULL AND NEW.value_canonical > v_max) THEN
    RAISE EXCEPTION '% = % % is outside plausible range', NEW.analyte_code, NEW.value_reported, NEW.unit_reported
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER lab_results_canonicalise BEFORE INSERT OR UPDATE OF value_reported, unit_reported, analyte_code
  ON clinical.lab_results FOR EACH ROW EXECUTE FUNCTION clinical.lab_result_canonicalise();

CREATE TABLE clinical.ecg_reports (
  investigation_id uuid PRIMARY KEY,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  rhythm          text CHECK (rhythm IN ('sinus','atrial_fibrillation','atrial_flutter','paced',
                    'junctional','svt','vt','other')),
  heart_rate      smallint CHECK (heart_rate BETWEEN 20 AND 300),
  pr_ms           smallint CHECK (pr_ms BETWEEN 40 AND 600),
  qrs_ms          smallint CHECK (qrs_ms BETWEEN 40 AND 300),
  qtc_ms          smallint CHECK (qtc_ms BETWEEN 200 AND 700),
  qtc_formula     text CHECK (qtc_formula IN ('bazett','fridericia','framingham','hodges','machine')),
  qrs_morphology  text CHECK (qrs_morphology IN ('normal','LBBB','RBBB','IVCD','paced','other')),
  qrs_axis_deg    smallint CHECK (qrs_axis_deg BETWEEN -180 AND 180),
  pathological_q_waves boolean,
  lvh             boolean,
  st_t_changes    text,
  interpretation  text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (investigation_id, patient_id, centre_id)
    REFERENCES clinical.investigations (investigation_id, patient_id, centre_id) ON UPDATE CASCADE
);

CREATE TABLE clinical.echo_reports (
  investigation_id uuid PRIMARY KEY,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  modality        text NOT NULL DEFAULT 'TTE' CHECK (modality IN ('TTE','TEE','stress','POCUS')),
  lvef            numeric(4,1) CHECK (lvef BETWEEN 5 AND 90),
  lvef_method     text CHECK (lvef_method IN ('biplane_simpson','3d','teichholz','visual','other')),
  lvedd_mm        numeric(4,1) CHECK (lvedd_mm BETWEEN 20 AND 100),
  lvesd_mm        numeric(4,1) CHECK (lvesd_mm BETWEEN 10 AND 90),
  lvedv_ml        numeric(5,1),
  lvesv_ml        numeric(5,1),
  ivs_mm          numeric(3,1),
  pw_mm           numeric(3,1),
  lv_mass_index_g_m2 numeric(5,1),
  rwma            boolean,
  rwma_description text,
  la_diameter_mm  numeric(4,1),
  la_volume_index_ml_m2 numeric(5,1) CHECK (la_volume_index_ml_m2 BETWEEN 5 AND 300),
  tapse_mm        numeric(4,1) CHECK (tapse_mm BETWEEN 2 AND 40),
  rv_s_prime_cm_s numeric(4,1),
  rv_function     text CHECK (rv_function IN ('normal','mildly_reduced','moderately_reduced','severely_reduced')),
  rv_dilated      boolean,
  e_over_a        numeric(4,2),
  e_over_e_prime_avg numeric(4,1),
  diastolic_grade text CHECK (diastolic_grade IN ('normal','grade_I','grade_II','grade_III','indeterminate')),
  tr_velocity_m_s numeric(3,1),
  pasp_mmhg       smallint CHECK (pasp_mmhg BETWEEN 10 AND 150),
  ivc_mm          numeric(3,1),
  ivc_collapse_gt50 boolean,
  pericardial_effusion text CHECK (pericardial_effusion IN ('none','trivial','small','moderate','large')),
  lv_thrombus     boolean,
  interpretation  text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (investigation_id, patient_id, centre_id)
    REFERENCES clinical.investigations (investigation_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (lvesd_mm IS NULL OR lvedd_mm IS NULL OR lvesd_mm < lvedd_mm)
);
CREATE INDEX echo_reports_patient ON clinical.echo_reports (patient_id);

ALTER TABLE clinical.clinical_assessments
  ADD FOREIGN KEY (hf_phenotype_basis_lvef_id) REFERENCES clinical.echo_reports;

CREATE TABLE clinical.echo_valve_findings (
  valve_finding_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  investigation_id uuid NOT NULL REFERENCES clinical.echo_reports ON DELETE CASCADE,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  valve           text NOT NULL CHECK (valve IN ('mitral','aortic','tricuspid','pulmonary')),
  lesion          text NOT NULL CHECK (lesion IN ('stenosis','regurgitation','prosthetic','repaired','prolapse')),
  severity        text CHECK (severity IN ('trivial','mild','moderate','moderate_severe','severe')),
  aetiology       text CHECK (aetiology IN ('rheumatic','degenerative','functional','congenital',
                    'endocarditis','prosthetic','other')),
  mean_gradient_mmhg numeric(4,1),
  valve_area_cm2  numeric(3,2),
  notes           text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (investigation_id, valve, lesion)
);
-- ---------------------------------------------------------------------
-- 06  CLINICAL: medications.  A course = one drug for one patient from
-- start to stop.  Every change is a new, immutable medication_event
-- (PRD Module 4, 8.5).  Current therapy is a view over the latest events.
-- ---------------------------------------------------------------------
CREATE TABLE clinical.medication_courses (
  course_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  drug_id         uuid NOT NULL REFERENCES ref.drugs,
  indication      text,
  started_on      date NOT NULL,
  started_on_precision text NOT NULL DEFAULT 'day' CHECK (started_on_precision IN ('day','month','year')),
  stopped_on      date,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','on_hold','stopped','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  UNIQUE (course_id, patient_id, centre_id),
  CHECK (stopped_on IS NULL OR stopped_on >= started_on),
  CHECK ((status = 'stopped') = (stopped_on IS NOT NULL) OR status = 'entered_in_error')
);
CREATE INDEX medication_courses_patient ON clinical.medication_courses (patient_id, status);
CREATE INDEX medication_courses_centre ON clinical.medication_courses (centre_id);

CREATE TABLE clinical.medication_events (
  medication_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id       uuid NOT NULL,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  encounter_id    uuid,
  event_type      text NOT NULL CHECK (event_type IN ('initiate','increase','decrease','change_frequency',
                    'switch_product','hold','resume','discontinue','reconcile_continue',
                    'record_external','void')),
  effective_date  date NOT NULL,
  drug_id         uuid NOT NULL REFERENCES ref.drugs,
  product_id      uuid REFERENCES ref.drug_products,
  brand_name_text text,
  strength_label  text,                          -- '49/51 mg'
  dose_quantity   numeric CHECK (dose_quantity > 0),        -- e.g. 1 (tablet), 0.5
  dose_unit       text CHECK (dose_unit IN ('tablet','capsule','mg','mcg','ml','unit','puff','sachet','injection')),
  frequency_code  text CHECK (frequency_code IN ('OD','BD','TDS','QID','HS','Q2W','Q4W','Q6M','weekly','SOS','other')),
  doses_per_day   numeric CHECK (doses_per_day > 0),
  daily_dose      numeric CHECK (daily_dose > 0),  -- in ref.drugs.reference_unit; drives % target dose
  route           text NOT NULL DEFAULT 'oral' CHECK (route IN ('oral','sublingual','iv','sc','im','inhaled',
                    'transdermal','topical','other')),
  duration_days   integer CHECK (duration_days > 0),
  instructions    text,
  reason_concept_id uuid REFERENCES ref.concepts,  -- why started / changed / stopped
  reason_text     text,
  prescribed_by   uuid REFERENCES iam.users,
  prescriber_source text NOT NULL DEFAULT 'this_centre' CHECK (prescriber_source IN ('this_centre',
                    'other_cardioemr_centre','external','patient_reported')),
  voids_event_id  uuid REFERENCES clinical.medication_events,
  ai_extracted_field_id uuid REFERENCES clinical.ai_extracted_fields,
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  FOREIGN KEY (course_id, patient_id, centre_id)
    REFERENCES clinical.medication_courses (course_id, patient_id, centre_id) ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK ((event_type = 'void') = (voids_event_id IS NOT NULL)),
  CHECK (event_type NOT IN ('initiate','increase','decrease','change_frequency','switch_product','resume','record_external')
         OR (daily_dose IS NOT NULL AND frequency_code IS NOT NULL)),
  CHECK (event_type NOT IN ('initiate','increase','decrease','change_frequency','switch_product','resume')
         OR prescriber_source <> 'this_centre' OR prescribed_by IS NOT NULL),
  CHECK (event_type NOT IN ('discontinue','hold') OR reason_concept_id IS NOT NULL OR reason_text IS NOT NULL)
);
CREATE INDEX medication_events_course ON clinical.medication_events (course_id, effective_date, recorded_at);
CREATE INDEX medication_events_patient ON clinical.medication_events (patient_id, effective_date DESC);
CREATE INDEX medication_events_centre ON clinical.medication_events (centre_id);

CREATE TRIGGER medication_events_append_only BEFORE UPDATE OR DELETE ON clinical.medication_events
  FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();

-- Keeps the course header in step with its events.
CREATE OR REPLACE FUNCTION clinical.medication_event_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.drug_id IS DISTINCT FROM (SELECT drug_id FROM clinical.medication_courses WHERE course_id = NEW.course_id) THEN
    RAISE EXCEPTION 'medication event drug does not match its course' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.event_type = 'discontinue' THEN
    UPDATE clinical.medication_courses SET status = 'stopped', stopped_on = NEW.effective_date
     WHERE course_id = NEW.course_id;
  ELSIF NEW.event_type = 'hold' THEN
    UPDATE clinical.medication_courses SET status = 'on_hold' WHERE course_id = NEW.course_id;
  ELSIF NEW.event_type = 'resume' THEN
    UPDATE clinical.medication_courses SET status = 'active', stopped_on = NULL WHERE course_id = NEW.course_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER medication_events_apply AFTER INSERT ON clinical.medication_events
  FOR EACH ROW EXECUTE FUNCTION clinical.medication_event_apply();

-- Dose in force for any course on any date: latest non-voided dosing event.
CREATE OR REPLACE FUNCTION clinical.course_dose_on(p_course uuid, p_date date)
RETURNS TABLE (medication_event_id uuid, daily_dose numeric, frequency_code text, effective_date date)
LANGUAGE sql STABLE AS $$
  SELECT e.medication_event_id, e.daily_dose, e.frequency_code, e.effective_date
  FROM clinical.medication_events e
  WHERE e.course_id = p_course
    AND e.effective_date <= p_date
    AND e.event_type IN ('initiate','increase','decrease','change_frequency','switch_product',
                         'resume','record_external','reconcile_continue','hold','discontinue')
    AND NOT EXISTS (SELECT 1 FROM clinical.medication_events v
                    WHERE v.voids_event_id = e.medication_event_id)
  ORDER BY e.effective_date DESC, e.recorded_at DESC
  LIMIT 1
$$;

CREATE TABLE clinical.medication_adherence (
  adherence_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  encounter_id    uuid,
  course_id       uuid,                          -- NULL = overall adherence
  assessed_on     date NOT NULL DEFAULT current_date,
  adherence       text NOT NULL CHECK (adherence IN ('good','partial','poor','unknown')),
  method          text CHECK (method IN ('self_report','pill_count','refill_record','questionnaire','caregiver')),
  barrier         text[] CHECK (barrier <@ ARRAY['cost','side_effects','forgetfulness','pill_burden',
                    'availability','belief','other']),
  notes           text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (course_id, patient_id, centre_id)
    REFERENCES clinical.medication_courses (course_id, patient_id, centre_id) ON UPDATE CASCADE
);
CREATE INDEX medication_adherence_patient ON clinical.medication_adherence (patient_id, assessed_on DESC);

CREATE TABLE clinical.adverse_drug_reactions (
  adr_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  course_id       uuid,
  drug_id         uuid NOT NULL REFERENCES ref.drugs,
  reaction_concept_id uuid REFERENCES ref.concepts,
  reaction_text   text NOT NULL,                 -- myalgia, hyperkalaemia, hypotension, cough, angioedema ...
  onset_date      date NOT NULL,
  severity        text NOT NULL CHECK (severity IN ('mild','moderate','severe','life_threatening')),
  action_taken    text NOT NULL CHECK (action_taken IN ('none','dose_reduced','held','discontinued','switched')),
  causality       text CHECK (causality IN ('certain','probable','possible','unlikely','unassessable')),
  supporting_result_id uuid REFERENCES clinical.lab_results,   -- e.g. CK or K+ value
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','resolved','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  FOREIGN KEY (course_id, patient_id, centre_id)
    REFERENCES clinical.medication_courses (course_id, patient_id, centre_id) ON UPDATE CASCADE
);
CREATE INDEX adr_patient ON clinical.adverse_drug_reactions (patient_id);
-- ---------------------------------------------------------------------
-- 07  REGISTRY ENGINE: types, versioned protocols, sites, study access,
-- visit schedules, versioned variable definitions, enrolments,
-- assessments, generic values, endpoint definitions, suggestions.
-- ---------------------------------------------------------------------
CREATE TABLE registry.registry_types (
  registry_type_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_code   text NOT NULL UNIQUE CHECK (registry_code ~ '^[A-Z_]{2,20}$'),   -- 'HF','LIPID','CAD'
  registry_name   text NOT NULL,
  description     text,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);

-- Versioned protocol.  A new version is a new row; enrolments keep the
-- version they were enrolled under.
CREATE TABLE registry.registry_protocols (
  protocol_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_type_id  uuid NOT NULL REFERENCES registry.registry_types,
  protocol_code     text NOT NULL,               -- 'CEMR-HF'
  protocol_version  integer NOT NULL CHECK (protocol_version > 0),
  protocol_title    text NOT NULL,
  sponsor_organisation_id uuid REFERENCES iam.organisations,
  is_multicentre    boolean NOT NULL DEFAULT false,
  ctri_number       text,                        -- Clinical Trials Registry - India, if registered
  inclusion_text    text NOT NULL,
  exclusion_text    text,
  inclusion_rules   jsonb NOT NULL DEFAULT '[]', -- machine-readable checks the UI pre-fills
  exclusion_rules   jsonb NOT NULL DEFAULT '[]',
  requires_research_consent boolean NOT NULL DEFAULT true,
  hf_target_dose_rule_set_id  uuid REFERENCES ref.rule_sets,
  statin_rule_set_id          uuid REFERENCES ref.rule_sets,
  ldl_target_rule_set_id      uuid REFERENCES ref.rule_sets,
  effective_from    date NOT NULL,
  effective_to      date,
  supersedes_protocol_id uuid REFERENCES registry.registry_protocols,
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','closed_to_enrolment','closed','superseded')),
  approved_by       uuid REFERENCES iam.users,
  approved_at       timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (protocol_code, protocol_version),
  CHECK (status = 'draft' OR approved_at IS NOT NULL)
);

ALTER TABLE clinical.patient_consents
  ADD FOREIGN KEY (protocol_id) REFERENCES registry.registry_protocols;

-- Participating centres per protocol, with their ethics approval.
CREATE TABLE registry.protocol_sites (
  protocol_id     uuid NOT NULL REFERENCES registry.registry_protocols,
  centre_id       uuid NOT NULL REFERENCES iam.centres,
  site_pi_user_id uuid REFERENCES iam.users,
  ethics_committee_name text,
  ethics_approval_ref   text,
  ethics_approval_date  date,
  ethics_approval_expiry date,
  site_status     text NOT NULL DEFAULT 'pending_approval'
                  CHECK (site_status IN ('pending_approval','active','enrolment_paused','closed')),
  activated_on    date,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (protocol_id, centre_id),
  CHECK (site_status <> 'active' OR ethics_approval_ref IS NOT NULL)
);

-- Study-level access (PRD 9, level 2).  Grants a user pseudonymised data
-- for one protocol, at some or all participating centres.
CREATE TABLE registry.study_memberships (
  membership_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES iam.users,
  protocol_id     uuid NOT NULL REFERENCES registry.registry_protocols,
  study_role      text NOT NULL CHECK (study_role IN ('chief_investigator','co_investigator',
                    'statistician','data_manager','adjudicator','monitor')),
  centre_scope    uuid[],                        -- NULL = all participating sites
  can_export      boolean NOT NULL DEFAULT false,
  valid_from      date NOT NULL DEFAULT current_date,
  valid_to        date,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  approved_by     uuid NOT NULL REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX study_memberships_one_active ON registry.study_memberships (user_id, protocol_id, study_role)
  WHERE status = 'active';

CREATE OR REPLACE FUNCTION app._study_centres(p_user uuid, p_protocol uuid) RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, registry AS $$
  -- Centres whose data this user may see for this protocol (NULL = none).
  WITH m AS (
    SELECT centre_scope FROM registry.study_memberships
    WHERE user_id = p_user AND protocol_id = p_protocol AND status = 'active'
      AND current_date >= valid_from AND (valid_to IS NULL OR current_date <= valid_to))
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM m) THEN NULL
    WHEN EXISTS (SELECT 1 FROM m WHERE centre_scope IS NULL)
      THEN (SELECT array_agg(centre_id) FROM registry.protocol_sites WHERE protocol_id = p_protocol)
    ELSE (SELECT array_agg(DISTINCT c) FROM m, unnest(m.centre_scope) c
          WHERE c IN (SELECT centre_id FROM registry.protocol_sites WHERE protocol_id = p_protocol))
  END
$$;

CREATE OR REPLACE FUNCTION app.study_centres(p_protocol uuid) RETURNS uuid[]
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_user::text IN ('r_principal_investigator','r_research_coordinator')
              THEN app._study_centres(app.current_user_id(), p_protocol) END
$$;

CREATE TABLE registry.visit_schedule (
  protocol_id     uuid NOT NULL REFERENCES registry.registry_protocols,
  visit_code      text NOT NULL CHECK (visit_code ~ '^[A-Z0-9_]{1,12}$'),   -- 'BL','M1','M3','M6','M12','ANNUAL'
  visit_label     text NOT NULL,
  anchor          text NOT NULL DEFAULT 'index_date' CHECK (anchor IN ('index_date','enrolment_date')),
  target_day      integer NOT NULL CHECK (target_day >= 0),
  window_before_days integer NOT NULL DEFAULT 0 CHECK (window_before_days >= 0),
  window_after_days  integer NOT NULL DEFAULT 0 CHECK (window_after_days >= 0),
  repeats_every_days integer CHECK (repeats_every_days > 0),   -- 'ANNUAL' = 365 after M12
  sort_order      smallint NOT NULL,
  PRIMARY KEY (protocol_id, visit_code)
);

CREATE TABLE registry.variable_definitions (
  variable_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_type_id uuid NOT NULL REFERENCES registry.registry_types,
  variable_code    text NOT NULL CHECK (variable_code ~ '^[a-z][a-z0-9_]{1,62}$'),
  definition_version integer NOT NULL DEFAULT 1 CHECK (definition_version > 0),
  category         text NOT NULL,                -- data-dictionary category: 'Demographics','Echo',...
  variable_label   text NOT NULL,
  description      text,
  data_type        text NOT NULL CHECK (data_type IN ('numeric','integer','text','date','boolean','coded','multi_coded')),
  unit             text,
  allowed_values   jsonb,                        -- [{"code":"I","label":"NYHA I"}, ...] for coded types
  min_value        numeric,
  max_value        numeric,
  source_kind      text NOT NULL CHECK (source_kind IN ('emr_derived','entered','calculated')),
  derivation_key   text,                         -- name of the engine rule that fills it
  emr_source       text,                         -- human-readable: 'echo_reports.lvef, latest within 90 d'
  fhir_mapping     text,
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','retired')),
  supersedes_variable_id uuid REFERENCES registry.variable_definitions,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (registry_type_id, variable_code, definition_version),
  CHECK (data_type NOT IN ('coded','multi_coded') OR allowed_values IS NOT NULL),
  CHECK (source_kind = 'entered' OR derivation_key IS NOT NULL)
);

-- Which variable versions a protocol collects, at which visits.
CREATE TABLE registry.protocol_variables (
  protocol_id   uuid NOT NULL REFERENCES registry.registry_protocols,
  variable_id   uuid NOT NULL REFERENCES registry.variable_definitions,
  visit_code    text NOT NULL DEFAULT '*',       -- '*' = every visit
  requirement   text NOT NULL CHECK (requirement IN ('mandatory','conditional','optional')),
  condition_text text,                           -- e.g. 'if hf_phenotype = HFrEF'
  sort_order    smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (protocol_id, variable_id, visit_code)
);

CREATE TABLE registry.enrolments (
  enrolment_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  registry_type_id uuid NOT NULL REFERENCES registry.registry_types,
  protocol_id      uuid NOT NULL REFERENCES registry.registry_protocols,
  screening_date   date NOT NULL DEFAULT current_date,
  enrolment_date   date,
  index_date       date,                         -- time zero for follow-up windows and outcomes
  eligibility_status text NOT NULL DEFAULT 'pending_review'
                   CHECK (eligibility_status IN ('pending_review','eligible','ineligible')),
  eligibility_checklist jsonb,                   -- answers to inclusion/exclusion rules
  eligibility_confirmed_by uuid REFERENCES iam.users,
  eligibility_confirmed_at timestamptz,
  consent_id       uuid REFERENCES clinical.patient_consents,
  enrolment_status text NOT NULL DEFAULT 'screening' CHECK (enrolment_status IN ('screening','screen_failed',
                     'enrolled','completed','withdrawn','lost_to_follow_up','deceased')),
  status_changed_on date,
  withdrawal_reason text,
  enrolled_by      uuid REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  UNIQUE (enrolment_id, patient_id, centre_id),
  CHECK (enrolment_status IN ('screening','screen_failed')
         OR (enrolment_date IS NOT NULL AND index_date IS NOT NULL AND eligibility_status = 'eligible'
             AND eligibility_confirmed_by IS NOT NULL AND enrolled_by IS NOT NULL)),
  CHECK (enrolment_status NOT IN ('withdrawn','lost_to_follow_up','deceased','completed') OR status_changed_on IS NOT NULL)
);
CREATE UNIQUE INDEX enrolments_one_per_protocol ON registry.enrolments (patient_id, protocol_id)
  WHERE enrolment_status NOT IN ('screen_failed');
CREATE INDEX enrolments_centre_registry ON registry.enrolments (centre_id, registry_type_id, enrolment_status);
CREATE INDEX enrolments_protocol ON registry.enrolments (protocol_id, enrolment_status);

-- No silent research enrolment (PRD 10.3): an enrolled patient must have
-- an active research consent for this protocol, unless the protocol has an
-- approved consent waiver, and the protocol must be active at this site.
CREATE OR REPLACE FUNCTION registry.enrolment_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry, clinical AS $$
DECLARE v_requires boolean; v_type uuid; c record;
BEGIN
  SELECT requires_research_consent, registry_type_id INTO v_requires, v_type
    FROM registry.registry_protocols WHERE protocol_id = NEW.protocol_id;
  IF v_type <> NEW.registry_type_id THEN
    RAISE EXCEPTION 'protocol belongs to a different registry' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.enrolment_status = 'enrolled' AND (TG_OP = 'INSERT' OR OLD.enrolment_status <> 'enrolled') THEN
    IF NOT EXISTS (SELECT 1 FROM registry.protocol_sites
                   WHERE protocol_id = NEW.protocol_id AND centre_id = NEW.centre_id AND site_status = 'active') THEN
      RAISE EXCEPTION 'protocol is not active at this centre' USING ERRCODE = 'check_violation';
    END IF;
    IF v_requires THEN
      SELECT * INTO c FROM clinical.patient_consents WHERE consent_id = NEW.consent_id;
      IF c IS NULL OR c.patient_id <> NEW.patient_id OR c.consent_type <> 'research_registry'
         OR c.protocol_id <> NEW.protocol_id OR c.consent_status <> 'active' THEN
        RAISE EXCEPTION 'enrolment requires an active research consent for this protocol'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER enrolments_guard BEFORE INSERT OR UPDATE ON registry.enrolments
  FOR EACH ROW EXECUTE FUNCTION registry.enrolment_guard();

-- When research consent is withdrawn, active enrolments under it close.
CREATE OR REPLACE FUNCTION registry.consent_withdrawal_cascade() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry AS $$
BEGIN
  IF NEW.consent_status = 'withdrawn' AND OLD.consent_status <> 'withdrawn' THEN
    UPDATE registry.enrolments
       SET enrolment_status = 'withdrawn', status_changed_on = NEW.withdrawal_date,
           withdrawal_reason = coalesce(NEW.withdrawal_reason, 'consent withdrawn')
     WHERE consent_id = NEW.consent_id AND enrolment_status = 'enrolled';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER patient_consents_withdrawal AFTER UPDATE OF consent_status ON clinical.patient_consents
  FOR EACH ROW EXECUTE FUNCTION registry.consent_withdrawal_cascade();

-- Registry suggestions raised by diagnoses (PRD 10.3).  A suggestion is
-- only a prompt; enrolment still needs eligibility + consent.
CREATE TABLE registry.registry_suggestions (
  suggestion_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  registry_code    text NOT NULL,
  trigger_diagnosis_id uuid REFERENCES clinical.diagnoses,
  suggested_at     timestamptz NOT NULL DEFAULT now(),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','screening_started','dismissed','not_eligible')),
  actioned_by      uuid REFERENCES iam.users,
  actioned_at      timestamptz,
  dismiss_reason   text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE
);
CREATE UNIQUE INDEX registry_suggestions_one_open ON registry.registry_suggestions (patient_id, centre_id, registry_code)
  WHERE status = 'open';

CREATE OR REPLACE FUNCTION registry.suggest_from_diagnosis() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry, ref AS $$
BEGIN
  INSERT INTO registry.registry_suggestions (patient_id, organisation_id, centre_id, registry_code, trigger_diagnosis_id)
  SELECT NEW.patient_id, NEW.organisation_id, NEW.centre_id, t.registry_code, NEW.diagnosis_id
  FROM ref.concept_registry_triggers t
  WHERE t.concept_id = NEW.concept_id
    AND NEW.certainty = 'confirmed' AND NEW.status = 'active'
    AND NOT EXISTS (SELECT 1 FROM registry.enrolments e JOIN registry.registry_types rt USING (registry_type_id)
                    WHERE e.patient_id = NEW.patient_id AND rt.registry_code = t.registry_code
                      AND e.enrolment_status IN ('screening','enrolled'))
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;
CREATE TRIGGER diagnoses_registry_suggestion AFTER INSERT ON clinical.diagnoses
  FOR EACH ROW WHEN (NEW.concept_id IS NOT NULL) EXECUTE FUNCTION registry.suggest_from_diagnosis();

CREATE TABLE registry.assessments (
  assessment_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrolment_id     uuid NOT NULL,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  encounter_id     uuid,                         -- NULL for telephone / records-only follow-up
  visit_code       text NOT NULL,                -- from visit_schedule, or 'UNSCHED'
  assessment_type  text NOT NULL CHECK (assessment_type IN ('baseline','scheduled','unscheduled',
                     'event_triggered','end_of_study')),
  contact_mode     text NOT NULL DEFAULT 'in_person' CHECK (contact_mode IN ('in_person','telephone',
                     'video','records_review','proxy')),
  assessment_date  date NOT NULL,
  days_from_index  integer,                      -- set by trigger
  within_window    boolean,                      -- set by trigger
  completion_status text NOT NULL DEFAULT 'partial' CHECK (completion_status IN ('partial','complete',
                     'missed','not_applicable')),
  missed_reason    text,
  completed_by     uuid REFERENCES iam.users,
  locked_at        timestamptz,                  -- data lock after monitoring; values then immutable
  locked_by        uuid REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (enrolment_id, patient_id, centre_id)
    REFERENCES registry.enrolments (enrolment_id, patient_id, centre_id) ON UPDATE CASCADE,
  FOREIGN KEY (encounter_id, patient_id, centre_id)
    REFERENCES clinical.encounters (encounter_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (assessment_id, patient_id, centre_id),
  CHECK (completion_status <> 'missed' OR missed_reason IS NOT NULL)
);
CREATE UNIQUE INDEX assessments_one_per_scheduled_visit ON registry.assessments (enrolment_id, visit_code)
  WHERE assessment_type IN ('baseline','scheduled');
CREATE INDEX assessments_centre_date ON registry.assessments (centre_id, assessment_date);

ALTER TABLE clinical.appointments
  ADD FOREIGN KEY (registry_assessment_id) REFERENCES registry.assessments;

CREATE OR REPLACE FUNCTION registry.assessment_window() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE e record; v record;
BEGIN
  SELECT * INTO e FROM registry.enrolments WHERE enrolment_id = NEW.enrolment_id;
  NEW.days_from_index := NEW.assessment_date - e.index_date;
  SELECT * INTO v FROM registry.visit_schedule WHERE protocol_id = e.protocol_id AND visit_code = NEW.visit_code;
  IF v IS NULL THEN
    NEW.within_window := NULL;
  ELSE
    NEW.within_window := NEW.days_from_index BETWEEN v.target_day - v.window_before_days
                                                 AND v.target_day + v.window_after_days;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.locked_at IS NOT NULL AND NEW.locked_at IS NOT NULL
     AND (to_jsonb(NEW) - 'patient_id' - 'updated_at' - 'updated_by' - 'row_version')
         <> (to_jsonb(OLD) - 'patient_id' - 'updated_at' - 'updated_by' - 'row_version') THEN
    RAISE EXCEPTION 'assessment is locked' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER assessments_window BEFORE INSERT OR UPDATE ON registry.assessments
  FOR EACH ROW EXECUTE FUNCTION registry.assessment_window();

-- Generic entity-attribute-value store for protocol variables that have no
-- typed column.  Exactly one value column is filled when value_status = 'present'.
CREATE TABLE registry.variable_values (
  value_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id   uuid NOT NULL,
  patient_id      uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id       uuid NOT NULL,
  variable_id     uuid NOT NULL REFERENCES registry.variable_definitions,
  value_status    text NOT NULL DEFAULT 'present' CHECK (value_status IN ('present','not_done','unknown',
                    'not_applicable','declined')),
  numeric_value   numeric,
  text_value      text,
  date_value      date,
  boolean_value   boolean,
  coded_value     text,
  coded_values    text[],
  source_kind     text NOT NULL DEFAULT 'entered' CHECK (source_kind IN ('entered','emr_derived','calculated','ai_extracted')),
  source_table    text,
  source_row_id   uuid,
  verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN ('unverified','verified','queried')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (assessment_id, patient_id, centre_id)
    REFERENCES registry.assessments (assessment_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (assessment_id, variable_id),
  CHECK ((value_status = 'present') =
         (num_nonnulls(numeric_value, text_value, date_value, boolean_value, coded_value, coded_values) = 1)),
  CHECK (source_kind = 'entered' OR source_table IS NOT NULL)
);
CREATE INDEX variable_values_variable ON registry.variable_values (variable_id);
CREATE INDEX variable_values_centre ON registry.variable_values (centre_id);

CREATE OR REPLACE FUNCTION registry.variable_value_validate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d record;
BEGIN
  SELECT * INTO d FROM registry.variable_definitions WHERE variable_id = NEW.variable_id;
  IF NEW.value_status <> 'present' THEN RETURN NEW; END IF;
  IF (d.data_type IN ('numeric','integer') AND NEW.numeric_value IS NULL)
  OR (d.data_type = 'text' AND NEW.text_value IS NULL)
  OR (d.data_type = 'date' AND NEW.date_value IS NULL)
  OR (d.data_type = 'boolean' AND NEW.boolean_value IS NULL)
  OR (d.data_type = 'coded' AND NEW.coded_value IS NULL)
  OR (d.data_type = 'multi_coded' AND NEW.coded_values IS NULL) THEN
    RAISE EXCEPTION 'variable % expects a % value', d.variable_code, d.data_type USING ERRCODE = 'check_violation';
  END IF;
  IF d.data_type = 'integer' AND NEW.numeric_value <> trunc(NEW.numeric_value) THEN
    RAISE EXCEPTION 'variable % expects an integer', d.variable_code USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.numeric_value < d.min_value OR NEW.numeric_value > d.max_value THEN
    RAISE EXCEPTION 'variable % value % outside % to %', d.variable_code, NEW.numeric_value, d.min_value, d.max_value
      USING ERRCODE = 'check_violation';
  END IF;
  IF d.data_type = 'coded' AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(d.allowed_values) a WHERE a->>'code' = NEW.coded_value) THEN
    RAISE EXCEPTION 'variable % does not allow code %', d.variable_code, NEW.coded_value USING ERRCODE = 'check_violation';
  END IF;
  IF d.data_type = 'multi_coded' AND EXISTS (
       SELECT 1 FROM unnest(NEW.coded_values) v
       WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(d.allowed_values) a WHERE a->>'code' = v)) THEN
    RAISE EXCEPTION 'variable % has a code outside its allowed values', d.variable_code USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM registry.assessments WHERE assessment_id = NEW.assessment_id AND locked_at IS NOT NULL) THEN
    RAISE EXCEPTION 'assessment is locked' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER variable_values_validate BEFORE INSERT OR UPDATE ON registry.variable_values
  FOR EACH ROW EXECUTE FUNCTION registry.variable_value_validate();

-- Protocol-specific endpoint definitions, including composites (PRD 4.6, 6.5).
CREATE TABLE registry.endpoint_definitions (
  endpoint_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  protocol_id       uuid NOT NULL REFERENCES registry.registry_protocols,
  endpoint_code     text NOT NULL,               -- 'MACE3', 'HF_HOSP', 'TLF', 'BARC_3_5'
  endpoint_label    text NOT NULL,
  endpoint_kind     text NOT NULL CHECK (endpoint_kind IN ('component','composite')),
  classification_system text CHECK (classification_system IN ('ARC-2','BARC','UDMI-4','HF-ARC',
                      'VARC-3','MVARC','custom')),
  event_types       text[],                      -- for components: matching clinical_events.event_type
  qualifying_classifications text[],             -- e.g. BARC {'3a','3b','3c','5a','5b'}
  definition_text   text NOT NULL,
  requires_adjudication boolean NOT NULL DEFAULT true,
  is_primary        boolean NOT NULL DEFAULT false,
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','retired')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (protocol_id, endpoint_code),
  CHECK (endpoint_kind = 'composite' OR event_types IS NOT NULL)
);

CREATE TABLE registry.endpoint_components (
  composite_endpoint_id uuid NOT NULL REFERENCES registry.endpoint_definitions,
  component_endpoint_id uuid NOT NULL REFERENCES registry.endpoint_definitions,
  PRIMARY KEY (composite_endpoint_id, component_endpoint_id),
  CHECK (composite_endpoint_id <> component_endpoint_id)
);
-- ---------------------------------------------------------------------
-- 08  HEART FAILURE REGISTRY: typed tables for the high-use variables,
-- GDMT four-pillar matrix, and the calculation functions behind it.
-- ---------------------------------------------------------------------
CREATE TABLE registry.hf_enrolment_details (
  enrolment_id       uuid PRIMARY KEY,
  patient_id         uuid NOT NULL,
  organisation_id    uuid NOT NULL,
  centre_id          uuid NOT NULL,
  hf_status_at_enrolment text NOT NULL CHECK (hf_status_at_enrolment IN ('newly_diagnosed','prevalent',
                       'post_discharge')),
  hf_diagnosis_date  date,
  hf_diagnosis_date_precision text CHECK (hf_diagnosis_date_precision IN ('day','month','year')),
  index_admission_date  date,                    -- for post_discharge enrolments
  index_discharge_date  date,
  primary_aetiology  text NOT NULL CHECK (primary_aetiology IN ('ischaemic','dilated_non_ischaemic',
                       'hypertensive','valvular','rheumatic_valvular','tachycardia_induced','peripartum',
                       'myocarditis','infiltrative','hypertrophic','chemotherapy_related','alcohol_related',
                       'congenital','other','unknown')),
  secondary_aetiologies text[],
  baseline_lvef      numeric(4,1) CHECK (baseline_lvef BETWEEN 5 AND 90),
  baseline_lvef_investigation_id uuid REFERENCES clinical.echo_reports,
  prior_lowest_lvef  numeric(4,1) CHECK (prior_lowest_lvef BETWEEN 5 AND 90),   -- needed to call HFimpEF
  baseline_phenotype text NOT NULL CHECK (baseline_phenotype IN ('HFrEF','HFmrEF','HFpEF','HFimpEF')),
  phenotype_confirmed_by uuid REFERENCES iam.users,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (enrolment_id, patient_id, centre_id)
    REFERENCES registry.enrolments (enrolment_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (hf_status_at_enrolment <> 'post_discharge' OR index_discharge_date IS NOT NULL),
  CHECK (index_discharge_date IS NULL OR index_admission_date IS NULL OR index_discharge_date >= index_admission_date)
);

-- One row per HF registry assessment: typed, indexed copies of the
-- variables the dashboards use, each with a pointer to its EMR source row.
CREATE TABLE registry.hf_assessment_data (
  assessment_id     uuid PRIMARY KEY,
  patient_id        uuid NOT NULL,
  organisation_id   uuid NOT NULL,
  centre_id         uuid NOT NULL,
  nyha_class        text CHECK (nyha_class IN ('I','II','III','IV')),
  systolic_bp       smallint CHECK (systolic_bp BETWEEN 50 AND 300),
  diastolic_bp      smallint CHECK (diastolic_bp BETWEEN 20 AND 200),
  heart_rate        smallint CHECK (heart_rate BETWEEN 20 AND 300),
  weight_kg         numeric(5,1),
  bmi               numeric(4,1),
  congestion_status text CHECK (congestion_status IN ('euvolaemic','mild','moderate','severe')),
  vitals_source_id  uuid REFERENCES clinical.vital_signs,
  lvef              numeric(4,1) CHECK (lvef BETWEEN 5 AND 90),
  lvedd_mm          numeric(4,1),
  lvesd_mm          numeric(4,1),
  la_volume_index_ml_m2 numeric(5,1),
  tapse_mm          numeric(4,1),
  rv_function       text,
  echo_source_id    uuid REFERENCES clinical.echo_reports,
  hf_phenotype      text CHECK (hf_phenotype IN ('HFrEF','HFmrEF','HFpEF','HFimpEF')),
  nt_probnp_pg_ml   numeric CHECK (nt_probnp_pg_ml >= 0),
  nt_probnp_result_id uuid REFERENCES clinical.lab_results,
  haemoglobin_g_dl  numeric(4,1),
  creatinine_mg_dl  numeric(5,2),
  egfr_ml_min       numeric(5,1),
  sodium_mmol_l     numeric(4,1),
  potassium_mmol_l  numeric(3,1),
  has_diabetes      boolean,
  has_hypertension  boolean,
  has_ckd           boolean,
  has_af            boolean,
  has_cad           boolean,
  has_anaemia       boolean,
  device_types      text[],                      -- snapshot of active devices: {'ICD','CRT_D'}
  gdmt_rule_set_id  uuid REFERENCES ref.rule_sets,
  pillars_eligible  smallint CHECK (pillars_eligible BETWEEN 0 AND 4),
  pillars_prescribed smallint CHECK (pillars_prescribed BETWEEN 0 AND 4),
  pillars_at_target smallint CHECK (pillars_at_target BETWEEN 0 AND 4),
  calculated_at     timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (assessment_id, patient_id, centre_id)
    REFERENCES registry.assessments (assessment_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (pillars_at_target IS NULL OR pillars_prescribed IS NULL OR pillars_at_target <= pillars_prescribed)
);
CREATE INDEX hf_assessment_data_centre_phenotype ON registry.hf_assessment_data (centre_id, hf_phenotype);

-- Four-pillar GDMT matrix (PRD 4.4): one row per assessment per pillar.
CREATE TABLE registry.hf_gdmt_status (
  assessment_id     uuid NOT NULL,
  pillar_code       text NOT NULL REFERENCES ref.gdmt_pillars,
  patient_id        uuid NOT NULL,
  organisation_id   uuid NOT NULL,
  centre_id         uuid NOT NULL,
  eligible          boolean NOT NULL,            -- per phenotype, from ref.hf_pillar_eligibility
  prescribed        boolean NOT NULL,
  course_id         uuid,
  drug_id           uuid REFERENCES ref.drugs,
  daily_dose        numeric,
  target_daily_dose numeric,
  pct_target_dose   numeric(5,1) CHECK (pct_target_dose >= 0),
  evidence_based_drug boolean,
  initiation_date   date,
  last_titration_date date,
  dose_status       text NOT NULL CHECK (dose_status IN ('at_target','below_target_uptitrating',
                      'below_target_max_tolerated','not_prescribed','not_indicated')),
  rule_set_id       uuid NOT NULL REFERENCES ref.rule_sets,
  source            text NOT NULL DEFAULT 'engine' CHECK (source IN ('engine','clinician_override')),
  override_reason   text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (assessment_id, pillar_code),
  FOREIGN KEY (assessment_id, patient_id, centre_id)
    REFERENCES registry.assessments (assessment_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (prescribed = (drug_id IS NOT NULL)),
  CHECK (NOT prescribed OR daily_dose IS NOT NULL),
  CHECK (source = 'engine' OR override_reason IS NOT NULL),
  CHECK (dose_status <> 'at_target' OR prescribed)
);
CREATE INDEX hf_gdmt_status_centre ON registry.hf_gdmt_status (centre_id, pillar_code, dose_status);

-- Why a pillar is not prescribed or not at target (multi-select).
CREATE TABLE registry.hf_gdmt_reasons (
  assessment_id  uuid NOT NULL,
  pillar_code    text NOT NULL,
  reason_code    text NOT NULL CHECK (reason_code IN ('contraindication','intolerance','hypotension',
                   'hyperkalaemia','renal_dysfunction','bradycardia','worsening_hf','patient_refusal',
                   'financial','drug_unavailable','titration_in_progress','recently_initiated',
                   'not_indicated_for_phenotype','other')),
  detail         text,
  patient_id     uuid NOT NULL,
  organisation_id uuid NOT NULL,
  centre_id      uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  PRIMARY KEY (assessment_id, pillar_code, reason_code),
  FOREIGN KEY (assessment_id, pillar_code) REFERENCES registry.hf_gdmt_status ON UPDATE CASCADE,
  CHECK (reason_code <> 'other' OR detail IS NOT NULL)
);

-- HF phenotype from LVEF (Universal Definition of HF, 2021).
CREATE OR REPLACE FUNCTION registry.classify_hf_phenotype(p_lvef numeric, p_prior_lowest_lvef numeric DEFAULT NULL)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_lvef IS NULL THEN NULL
    WHEN p_lvef <= 40 THEN 'HFrEF'
    WHEN p_prior_lowest_lvef IS NOT NULL AND p_prior_lowest_lvef <= 40
         AND p_lvef - p_prior_lowest_lvef >= 10 THEN 'HFimpEF'
    WHEN p_lvef < 50 THEN 'HFmrEF'
    ELSE 'HFpEF' END
$$;

-- GDMT engine: for a patient on a date, the best-dosed drug in each
-- pillar, its % of target from the given versioned rule set, and dates of
-- initiation and last titration.  Centre-scoped by RLS like any query.
CREATE OR REPLACE FUNCTION registry.compute_gdmt(p_patient uuid, p_as_of date, p_rule_set uuid, p_phenotype text)
RETURNS TABLE (pillar_code text, eligible boolean, prescribed boolean, course_id uuid, drug_id uuid,
               daily_dose numeric, target_daily_dose numeric, pct_target_dose numeric,
               evidence_based_drug boolean, initiation_date date, last_titration_date date)
LANGUAGE sql STABLE AS $$
  WITH active AS (
    SELECT c.course_id, c.drug_id, t.pillar_code, t.target_daily_dose, t.evidence_based,
           d.daily_dose, d.event_type_last
    FROM clinical.medication_courses c
    JOIN ref.hf_target_doses t ON t.drug_id = c.drug_id AND t.rule_set_id = p_rule_set
    CROSS JOIN LATERAL (
      SELECT e.daily_dose, e.event_type AS event_type_last
      FROM clinical.medication_events e
      WHERE e.course_id = c.course_id AND e.effective_date <= p_as_of AND e.event_type <> 'void'
        AND NOT EXISTS (SELECT 1 FROM clinical.medication_events v WHERE v.voids_event_id = e.medication_event_id)
      ORDER BY e.effective_date DESC, e.recorded_at DESC LIMIT 1) d
    WHERE c.patient_id = p_patient AND c.status <> 'entered_in_error'
      AND c.started_on <= p_as_of
      AND d.event_type_last NOT IN ('discontinue','hold')
  ),
  dosed AS (
    SELECT a.*,
           -- carry the dose forward from the last dosing event if the latest event was a reconciliation
           coalesce(a.daily_dose, (SELECT e.daily_dose FROM clinical.medication_events e
                                    WHERE e.course_id = a.course_id AND e.daily_dose IS NOT NULL
                                      AND e.effective_date <= p_as_of
                                    ORDER BY e.effective_date DESC, e.recorded_at DESC LIMIT 1)) AS dose
    FROM active a
  ),
  best AS (
    SELECT DISTINCT ON (pillar_code) *
    FROM dosed
    ORDER BY pillar_code, evidence_based DESC, dose / target_daily_dose DESC NULLS LAST
  )
  SELECT p.pillar_code,
         EXISTS (SELECT 1 FROM ref.hf_pillar_eligibility el
                 WHERE el.rule_set_id = p_rule_set AND el.hf_phenotype = p_phenotype
                   AND el.pillar_code = p.pillar_code) AS eligible,
         b.course_id IS NOT NULL,
         b.course_id, b.drug_id, b.dose, b.target_daily_dose,
         round(100.0 * b.dose / b.target_daily_dose, 1),
         b.evidence_based,
         (SELECT min(e.effective_date) FROM clinical.medication_events e
           JOIN clinical.medication_courses c2 ON c2.course_id = e.course_id
           JOIN ref.hf_target_doses t2 ON t2.drug_id = c2.drug_id AND t2.rule_set_id = p_rule_set
          WHERE c2.patient_id = p_patient AND t2.pillar_code = p.pillar_code
            AND e.event_type IN ('initiate','record_external') AND e.effective_date <= p_as_of),
         (SELECT max(e.effective_date) FROM clinical.medication_events e
          WHERE e.course_id = b.course_id AND e.event_type IN ('increase','decrease')
            AND e.effective_date <= p_as_of)
  FROM ref.gdmt_pillars p
  LEFT JOIN best b ON b.pillar_code = p.pillar_code
  ORDER BY p.sort_order
$$;

-- Time from index date to first assessment with all eligible pillars prescribed.
CREATE OR REPLACE VIEW registry.hf_four_pillar_timing AS
SELECT e.enrolment_id, e.patient_id, e.centre_id, e.index_date,
       min(a.assessment_date) FILTER (WHERE h.pillars_prescribed = h.pillars_eligible AND h.pillars_eligible > 0)
         AS first_all_eligible_pillars_date,
       min(a.assessment_date) FILTER (WHERE h.pillars_prescribed = h.pillars_eligible AND h.pillars_eligible > 0)
         - e.index_date AS days_to_all_eligible_pillars
FROM registry.enrolments e
JOIN registry.assessments a ON a.enrolment_id = e.enrolment_id
JOIN registry.hf_assessment_data h ON h.assessment_id = a.assessment_id
GROUP BY e.enrolment_id, e.patient_id, e.centre_id, e.index_date;
ALTER VIEW registry.hf_four_pillar_timing SET (security_invoker = true);
-- ---------------------------------------------------------------------
-- 09  LIPID MANAGEMENT REGISTRY
-- ---------------------------------------------------------------------
CREATE TABLE registry.lipid_enrolment_details (
  enrolment_id        uuid PRIMARY KEY,
  patient_id          uuid NOT NULL,
  organisation_id     uuid NOT NULL,
  centre_id           uuid NOT NULL,
  prevention_type     text NOT NULL CHECK (prevention_type IN ('primary','secondary')),
  categories          text[] NOT NULL CHECK (cardinality(categories) >= 1 AND categories <@ ARRAY[
                        'primary_prevention','secondary_prevention','established_cad','post_mi','post_pci',
                        'post_cabg','diabetes','familial_hypercholesterolaemia','elevated_lpa',
                        'statin_intolerance','ckd','stroke_tia','pad']),
  fh_diagnosis_basis  text CHECK (fh_diagnosis_basis IN ('dlcn','simon_broome','genetic','clinical')),
  dlcn_score          smallint CHECK (dlcn_score BETWEEN 0 AND 30),
  statin_intolerance_type text CHECK (statin_intolerance_type IN ('partial','complete')),
  -- Baseline LDL (decision D7): which value counts as baseline is explicit.
  baseline_ldl_kind   text NOT NULL CHECK (baseline_ldl_kind IN ('untreated','on_treatment_at_enrolment',
                        'imputed_untreated')),
  baseline_ldl_mg_dl  numeric(5,1) CHECK (baseline_ldl_mg_dl BETWEEN 5 AND 1000),
  baseline_ldl_result_id uuid REFERENCES clinical.lab_results,
  baseline_on_llt     boolean NOT NULL,
  baseline_statin_intensity text CHECK (baseline_statin_intensity IN ('none','low','moderate','high')),
  lpa_value           numeric CHECK (lpa_value >= 0),
  lpa_unit            text CHECK (lpa_unit IN ('nmol/L','mg/dL')),   -- not inter-convertible; stored as reported
  lpa_result_id       uuid REFERENCES clinical.lab_results,
  lpa_elevated        boolean,                   -- >= 50 mg/dL or >= 125 nmol/L
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (enrolment_id, patient_id, centre_id)
    REFERENCES registry.enrolments (enrolment_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK (NOT ('familial_hypercholesterolaemia' = ANY (categories)) OR fh_diagnosis_basis IS NOT NULL),
  CHECK (NOT ('statin_intolerance' = ANY (categories)) OR statin_intolerance_type IS NOT NULL),
  CHECK ((lpa_value IS NULL) = (lpa_unit IS NULL))
);

CREATE TABLE registry.lipid_assessment_data (
  assessment_id       uuid PRIMARY KEY,
  patient_id          uuid NOT NULL,
  organisation_id     uuid NOT NULL,
  centre_id           uuid NOT NULL,
  -- PRD 5.6: separate "not at target despite therapy" from "no repeat test".
  lipid_test_status   text NOT NULL CHECK (lipid_test_status IN ('tested_in_window','tested_outside_window',
                        'not_tested')),
  lipid_collected_on  date,
  ldl_mg_dl           numeric(5,1) CHECK (ldl_mg_dl BETWEEN 1 AND 1000),
  ldl_method          text CHECK (ldl_method IN ('direct','friedewald','martin_hopkins','sampson')),
  ldl_result_id       uuid REFERENCES clinical.lab_results,
  total_chol_mg_dl    numeric(5,1),
  hdl_mg_dl           numeric(5,1),
  tg_mg_dl            numeric(6,1),
  non_hdl_mg_dl       numeric(5,1) GENERATED ALWAYS AS (total_chol_mg_dl - hdl_mg_dl) STORED,
  apob_mg_dl          numeric(5,1),
  -- target logic, frozen at the time of assessment
  ldl_rule_set_id     uuid REFERENCES ref.rule_sets,
  risk_category       text,
  ldl_target_mg_dl    numeric(5,1),
  ldl_target_met      boolean,
  ldl_abs_reduction_mg_dl numeric(5,1),          -- baseline - current
  ldl_pct_reduction   numeric(5,1),              -- (baseline - current) / baseline * 100
  reduction_50pct_met boolean,
  target_status       text CHECK (target_status IN ('at_target','not_at_target_on_max_tolerated',
                        'not_at_target_escalation_pending','not_at_target_adherence_issue','no_repeat_test')),
  -- therapy in force on the assessment date
  statin_drug_id      uuid REFERENCES ref.drugs,
  statin_daily_dose_mg numeric(5,1),
  statin_intensity    text CHECK (statin_intensity IN ('none','low','moderate','high')),
  statin_rule_set_id  uuid REFERENCES ref.rule_sets,
  on_ezetimibe        boolean,
  on_pcsk9_mab        boolean,
  on_inclisiran       boolean,
  on_bempedoic_acid   boolean,
  therapy_change      text CHECK (therapy_change IN ('none','statin_initiated','statin_intensified',
                        'non_statin_added','reduced','stopped')),
  non_intensification_reason text CHECK (non_intensification_reason IN ('at_target','intolerance',
                        'cost','patient_refusal','clinician_judgement','awaiting_repeat_test','other')),
  adherence           text CHECK (adherence IN ('good','partial','poor','unknown')),
  muscle_symptoms     text CHECK (muscle_symptoms IN ('none','myalgia','myositis','rhabdomyolysis')),
  ck_u_l              numeric,
  alt_u_l             numeric,
  calculated_at       timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (assessment_id, patient_id, centre_id)
    REFERENCES registry.assessments (assessment_id, patient_id, centre_id) ON UPDATE CASCADE,
  CHECK ((lipid_test_status = 'not_tested') = (ldl_mg_dl IS NULL)),
  CHECK ((lipid_test_status = 'not_tested') = (target_status = 'no_repeat_test')),
  CHECK (ldl_target_met IS NULL OR (ldl_rule_set_id IS NOT NULL AND risk_category IS NOT NULL
                                    AND ldl_target_mg_dl IS NOT NULL))
);
CREATE INDEX lipid_assessment_data_centre ON registry.lipid_assessment_data (centre_id, target_status);

-- Calculations (PRD 5.4).  Pure functions so they can be unit-tested
-- against independent reference values (PRD 18, clinical validation).
CREATE OR REPLACE FUNCTION registry.ldl_pct_reduction(p_baseline numeric, p_followup numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_baseline IS NULL OR p_followup IS NULL OR p_baseline <= 0 THEN NULL
              ELSE round((p_baseline - p_followup) / p_baseline * 100, 1) END
$$;

CREATE OR REPLACE FUNCTION registry.statin_intensity(p_rule_set uuid, p_drug uuid, p_daily_dose numeric)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT intensity FROM ref.statin_intensity_rules
                   WHERE rule_set_id = p_rule_set AND drug_id = p_drug
                     AND p_daily_dose BETWEEN min_daily_dose AND max_daily_dose
                   ORDER BY min_daily_dose DESC LIMIT 1),
                  CASE WHEN p_daily_dose IS NULL THEN 'none' END)
$$;

CREATE OR REPLACE FUNCTION registry.ldl_target_met(p_rule_set uuid, p_risk_category text,
                                                   p_ldl numeric, p_pct_reduction numeric)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_ldl IS NULL THEN NULL ELSE
    (CASE r.target_operator WHEN '<' THEN p_ldl < r.ldl_target_mg_dl ELSE p_ldl <= r.ldl_target_mg_dl END)
    AND (r.min_pct_reduction IS NULL OR p_pct_reduction IS NULL OR p_pct_reduction >= r.min_pct_reduction)
  END
  FROM ref.ldl_target_rules r
  WHERE r.rule_set_id = p_rule_set AND r.risk_category = p_risk_category
$$;

-- Friedewald, for when the lab reports TC/HDL/TG only.  Martin-Hopkins
-- needs its 180-cell factor table and is left to the application layer.
CREATE OR REPLACE FUNCTION registry.ldl_friedewald(p_tc numeric, p_hdl numeric, p_tg numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_tg IS NULL OR p_tg >= 400 THEN NULL
              ELSE round(p_tc - p_hdl - p_tg / 5.0, 1) END
$$;
-- ---------------------------------------------------------------------
-- 10  CAD: angiography, PCI procedures, lesions, stents.  Clinical
-- tables (not registry-only) because PCI is care, and the CAD registry
-- reads them.  One patient -> many procedures -> many lesions -> stents.
-- ---------------------------------------------------------------------
CREATE TABLE registry.cad_enrolment_details (
  enrolment_id     uuid PRIMARY KEY,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  presentation     text NOT NULL CHECK (presentation IN ('chronic_coronary_syndrome','STEMI','NSTEMI',
                     'unstable_angina','prior_mi_stable','prior_revascularisation_stable','other')),
  categories       text[] NOT NULL CHECK (categories <@ ARRAY['chronic_coronary_syndrome','acute_coronary_syndrome',
                     'STEMI','NSTEMI','unstable_angina','previous_mi','previous_pci','previous_cabg',
                     'multivessel','left_main','cto','bifurcation']),
  index_event_date date NOT NULL,
  killip_class_at_presentation text CHECK (killip_class_at_presentation IN ('I','II','III','IV')),
  ccs_class_at_enrolment text CHECK (ccs_class_at_enrolment IN ('0','I','II','III','IV')),
  initial_strategy text CHECK (initial_strategy IN ('medical','pci','cabg','pci_planned','cabg_planned','hybrid')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (enrolment_id, patient_id, centre_id)
    REFERENCES registry.enrolments (enrolment_id, patient_id, centre_id) ON UPDATE CASCADE
);

CREATE TABLE clinical.coronary_angiograms (
  investigation_id uuid PRIMARY KEY,             -- investigations row of type coronary_angiography / ctca
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  dominance        text CHECK (dominance IN ('right','left','codominant')),
  disease_extent   text CHECK (disease_extent IN ('normal','non_obstructive','SVD','DVD','TVD')),
  left_main_disease boolean,
  syntax_score     numeric(4,1),
  cadrads          text,                         -- CT only
  findings         text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (investigation_id, patient_id, centre_id)
    REFERENCES clinical.investigations (investigation_id, patient_id, centre_id) ON UPDATE CASCADE
);

CREATE TABLE clinical.coronary_segment_findings (
  finding_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  investigation_id uuid NOT NULL REFERENCES clinical.coronary_angiograms,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  vessel           text NOT NULL CHECK (vessel IN ('LM','LAD','LCX','RCA','RAMUS','DIAGONAL','OM','PDA','PLV',
                     'SVG','LIMA','RIMA','RADIAL_GRAFT')),
  segment_code     text,                         -- SCCT/SYNTAX segment number, e.g. '6','7'
  stenosis_pct     smallint CHECK (stenosis_pct BETWEEN 0 AND 100),
  is_cto           boolean NOT NULL DEFAULT false,
  is_bifurcation   boolean NOT NULL DEFAULT false,
  medina           text CHECK (medina ~ '^[01],[01],[01]$'),
  calcification    text CHECK (calcification IN ('none','mild','moderate','severe')),
  thrombus         boolean,
  ffr              numeric(3,2) CHECK (ffr BETWEEN 0.3 AND 1.0),
  ifr              numeric(3,2) CHECK (ifr BETWEEN 0.3 AND 1.2),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1
);

CREATE TABLE clinical.pci_procedures (
  procedure_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  encounter_id     uuid,
  angiogram_investigation_id uuid REFERENCES clinical.coronary_angiograms,
  procedure_date   date NOT NULL,
  performed_at_facility text,                    -- when done outside a CardioEMR centre
  indication       text NOT NULL CHECK (indication IN ('primary_pci_stemi','pharmacoinvasive','rescue_pci',
                     'nstemi','unstable_angina','chronic_coronary_syndrome','staged','silent_ischaemia','other')),
  urgency          text CHECK (urgency IN ('elective','urgent','emergency','salvage')),
  access_site      text CHECK (access_site IN ('radial','distal_radial','femoral','brachial','ulnar')),
  operator_name    text,
  imaging_guidance text NOT NULL DEFAULT 'none' CHECK (imaging_guidance IN ('none','IVUS','OCT','IVUS_and_OCT')),
  physiology       text NOT NULL DEFAULT 'none' CHECK (physiology IN ('none','FFR','iFR','RFR','QFR','other')),
  mechanical_support text CHECK (mechanical_support IN ('none','IABP','Impella','ECMO')),
  contrast_ml      smallint,
  fluoroscopy_min  numeric(5,1),
  procedural_success boolean,
  complications    text[] CHECK (complications <@ ARRAY['none','dissection','perforation','no_reflow',
                     'side_branch_occlusion','acute_stent_thrombosis','access_bleeding','haematoma',
                     'pseudoaneurysm','contrast_nephropathy','arrhythmia','stroke','death','other']),
  source           text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ai_extracted','imported')),
  source_document_id uuid REFERENCES clinical.documents,
  status           text NOT NULL DEFAULT 'final' CHECK (status IN ('draft','final','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  UNIQUE (procedure_id, patient_id, centre_id)
);
CREATE INDEX pci_procedures_patient ON clinical.pci_procedures (patient_id, procedure_date DESC);
CREATE INDEX pci_procedures_centre ON clinical.pci_procedures (centre_id, procedure_date DESC);

CREATE TABLE clinical.pci_lesions (
  lesion_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  procedure_id     uuid NOT NULL,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  lesion_number    smallint NOT NULL CHECK (lesion_number > 0),
  vessel           text NOT NULL CHECK (vessel IN ('LM','LAD','LCX','RCA','RAMUS','DIAGONAL','OM','PDA','PLV',
                     'SVG','LIMA','RIMA','RADIAL_GRAFT')),
  segment_code     text,
  lesion_type_acc_aha text CHECK (lesion_type_acc_aha IN ('A','B1','B2','C')),
  lesion_length_mm numeric(4,1) CHECK (lesion_length_mm BETWEEN 1 AND 200),
  reference_diameter_mm numeric(3,2) CHECK (reference_diameter_mm BETWEEN 1.5 AND 7.0),
  pre_stenosis_pct smallint CHECK (pre_stenosis_pct BETWEEN 0 AND 100),
  pre_timi_flow    smallint CHECK (pre_timi_flow BETWEEN 0 AND 3),
  calcification    text CHECK (calcification IN ('none','mild','moderate','severe')),
  is_cto           boolean NOT NULL DEFAULT false,
  j_cto_score      smallint CHECK (j_cto_score BETWEEN 0 AND 5),
  is_bifurcation   boolean NOT NULL DEFAULT false,
  medina           text CHECK (medina ~ '^[01],[01],[01]$'),
  bifurcation_technique text CHECK (bifurcation_technique IN ('provisional','TAP','culotte','DK_crush',
                     'mini_crush','T_stenting','V_stenting','other')),
  is_in_stent_restenosis boolean NOT NULL DEFAULT false,
  thrombus         boolean,
  lesion_preparation text[] CHECK (lesion_preparation <@ ARRAY['predilatation','cutting_balloon',
                     'scoring_balloon','rotational_atherectomy','orbital_atherectomy','IVL','laser']),
  post_dilatation  boolean,
  pre_physiology_value  numeric(3,2),
  post_physiology_value numeric(3,2),
  final_timi_flow  smallint CHECK (final_timi_flow BETWEEN 0 AND 3),
  residual_stenosis_pct smallint CHECK (residual_stenosis_pct BETWEEN 0 AND 100),
  treatment        text NOT NULL CHECK (treatment IN ('stent','DCB','POBA','failed','deferred_by_physiology')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (procedure_id, patient_id, centre_id)
    REFERENCES clinical.pci_procedures (procedure_id, patient_id, centre_id) ON UPDATE CASCADE,
  UNIQUE (procedure_id, lesion_number),
  CHECK (NOT is_bifurcation OR medina IS NOT NULL),
  CHECK (j_cto_score IS NULL OR is_cto)
);
CREATE INDEX pci_lesions_patient_vessel ON clinical.pci_lesions (patient_id, vessel);

CREATE TABLE clinical.pci_stents (
  stent_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lesion_id        uuid NOT NULL REFERENCES clinical.pci_lesions,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  sequence_number  smallint NOT NULL CHECK (sequence_number > 0),
  stent_device_id  uuid REFERENCES ref.stent_devices,
  device_text      text,                         -- when not in catalogue
  diameter_mm      numeric(3,2) NOT NULL CHECK (diameter_mm BETWEEN 1.5 AND 6.0),
  length_mm        numeric(4,1) NOT NULL CHECK (length_mm BETWEEN 6 AND 60),
  deployment_atm   smallint CHECK (deployment_atm BETWEEN 4 AND 30),
  post_dilatation_balloon_mm numeric(3,2),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  UNIQUE (lesion_id, sequence_number),
  CHECK (stent_device_id IS NOT NULL OR device_text IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 11  CLINICAL EVENTS and protocol-specific ADJUDICATION
-- An event is recorded once, as a clinical fact.  Each protocol then
-- adjudicates it against its own endpoint definitions (PRD 4.6, 6.5).
-- Historical events (prior MI, prior PCI reported at registration) live
-- here too, flagged is_historical, so baseline history and outcomes share
-- one vocabulary.
-- ---------------------------------------------------------------------
CREATE TABLE clinical.clinical_events (
  event_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  event_type       text NOT NULL CHECK (event_type IN ('death','mi','stroke','tia','hf_hospitalisation',
                     'urgent_hf_visit','worsening_hf_outpatient','pci','cabg','stent_thrombosis',
                     'bleeding','hyperkalaemia','hypotension','renal_deterioration','arrhythmia',
                     'device_therapy','other_cv_hospitalisation','non_cv_hospitalisation','other')),
  event_date       date NOT NULL,
  event_date_precision text NOT NULL DEFAULT 'day' CHECK (event_date_precision IN ('day','month','year')),
  is_historical    boolean NOT NULL DEFAULT false,
  description      text,
  hospitalised     boolean,
  admission_date   date,
  discharge_date   date,
  facility_name    text,
  severity         text CHECK (severity IN ('mild','moderate','severe','life_threatening','fatal')),
  outcome          text CHECK (outcome IN ('recovered','recovered_with_sequelae','ongoing','fatal','unknown')),
  -- type-specific detail (nullable)
  death_cause      text CHECK (death_cause IN ('cardiovascular','non_cardiovascular','undetermined')),
  death_cv_mode    text CHECK (death_cv_mode IN ('sudden','heart_failure','mi','stroke','procedural',
                     'other_cv')),
  mi_type          text CHECK (mi_type IN ('1','2','3','4a','4b','4c','5')),
  stroke_type      text CHECK (stroke_type IN ('ischaemic','haemorrhagic','undetermined')),
  bleeding_site    text,
  pci_procedure_id uuid REFERENCES clinical.pci_procedures,  -- the revascularisation itself
  target_lesion_id uuid REFERENCES clinical.pci_lesions,     -- lesion revascularised / thrombosed
  potassium_mmol_l numeric(3,1),
  creatinine_result_id uuid REFERENCES clinical.lab_results,
  source           text NOT NULL CHECK (source IN ('site_clinician','patient_report','relative_report',
                     'hospital_records','death_certificate','follow_up_call','imported')),
  source_document_id uuid REFERENCES clinical.documents,
  reported_by      uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  status           text NOT NULL DEFAULT 'reported' CHECK (status IN ('reported','source_verified','entered_in_error')),
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  FOREIGN KEY (patient_id, centre_id) REFERENCES clinical.patient_registrations (patient_id, centre_id)
    ON UPDATE CASCADE,
  CHECK (event_type <> 'death' OR death_cause IS NOT NULL),
  CHECK (death_cv_mode IS NULL OR death_cause = 'cardiovascular'),
  CHECK (mi_type IS NULL OR event_type = 'mi'),
  CHECK (discharge_date IS NULL OR admission_date IS NULL OR discharge_date >= admission_date),
  CHECK (event_type NOT IN ('hf_hospitalisation','other_cv_hospitalisation','non_cv_hospitalisation')
         OR hospitalised)
);
CREATE INDEX clinical_events_patient ON clinical.clinical_events (patient_id, event_date);
CREATE INDEX clinical_events_centre_type ON clinical.clinical_events (centre_id, event_type, event_date);
CREATE UNIQUE INDEX clinical_events_one_death ON clinical.clinical_events (patient_id, centre_id)
  WHERE event_type = 'death' AND status <> 'entered_in_error';

CREATE TABLE registry.event_adjudications (
  adjudication_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id         uuid NOT NULL REFERENCES clinical.clinical_events,
  protocol_id      uuid NOT NULL REFERENCES registry.registry_protocols,
  endpoint_id      uuid REFERENCES registry.endpoint_definitions,
  patient_id       uuid NOT NULL,
  organisation_id  uuid NOT NULL,
  centre_id        uuid NOT NULL,
  adjudication_status text NOT NULL DEFAULT 'pending' CHECK (adjudication_status IN ('pending','in_review',
                     'adjudicated','not_an_event','insufficient_data')),
  classification   text,                         -- 'BARC_3a', 'ARC2_ST_definite', 'UDMI_type1', ...
  meets_endpoint   boolean,
  adjudicated_by   uuid REFERENCES iam.users,    -- always a human (PRD 11.3)
  adjudicated_at   timestamptz,
  committee_reference text,
  notes            text,
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid DEFAULT app.current_user_id(),
  updated_at timestamptz, updated_by uuid, row_version integer NOT NULL DEFAULT 1,
  CHECK (adjudication_status NOT IN ('adjudicated','not_an_event')
         OR (adjudicated_by IS NOT NULL AND adjudicated_at IS NOT NULL AND meets_endpoint IS NOT NULL))
);
CREATE UNIQUE INDEX event_adjudications_unique ON registry.event_adjudications
  (event_id, protocol_id, coalesce(endpoint_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX event_adjudications_protocol ON registry.event_adjudications (protocol_id, adjudication_status);
-- ---------------------------------------------------------------------
-- 12  AUDIT: append-only, hash-chained per centre, written only by a
-- security-definer trigger.  No application role can UPDATE, DELETE or
-- TRUNCATE it; a trigger blocks even the owner.  Partitioned by month.
-- ---------------------------------------------------------------------
CREATE TABLE audit.audit_log (
  audit_id       bigint GENERATED ALWAYS AS IDENTITY,
  occurred_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  transaction_id bigint NOT NULL DEFAULT txid_current(),
  db_role        text NOT NULL DEFAULT current_user,
  user_id        uuid,
  active_centre_id uuid,
  centre_id      uuid,                           -- centre of the row changed
  schema_name    text NOT NULL,
  table_name     text NOT NULL,
  row_pk         text NOT NULL,
  action         text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_values     jsonb,                          -- changed columns only, for UPDATE
  new_values     jsonb,
  reason         text,
  chain_key      text NOT NULL,
  prev_hash      bytea,
  row_hash       bytea NOT NULL,
  PRIMARY KEY (audit_id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE TABLE audit.audit_log_default PARTITION OF audit.audit_log DEFAULT;
CREATE INDEX audit_log_entity ON audit.audit_log (schema_name, table_name, row_pk);
CREATE INDEX audit_log_chain ON audit.audit_log (chain_key, audit_id DESC);
CREATE INDEX audit_log_user_time ON audit.audit_log (user_id, occurred_at);

CREATE OR REPLACE FUNCTION audit.capture() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, audit AS $$
DECLARE
  v_old jsonb; v_new jsonb; v_row jsonb; v_pk text; v_key text; v_prev bytea; v_hash bytea;
  v_old_changed jsonb; v_new_changed jsonb; k text;
BEGIN
  IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;
  v_row := coalesce(v_new, v_old);

  IF TG_OP = 'UPDATE' THEN
    v_old_changed := '{}'; v_new_changed := '{}';
    FOR k IN SELECT jsonb_object_keys(v_new) LOOP
      IF k NOT IN ('updated_at','updated_by','row_version') AND (v_new->k) IS DISTINCT FROM (v_old->k) THEN
        v_old_changed := v_old_changed || jsonb_build_object(k, v_old->k);
        v_new_changed := v_new_changed || jsonb_build_object(k, v_new->k);
      END IF;
    END LOOP;
    IF v_new_changed = '{}' THEN RETURN NULL; END IF;
    v_old := v_old_changed; v_new := v_new_changed;
  END IF;

  SELECT string_agg(v_row->>a, '|' ORDER BY a) INTO v_pk FROM unnest(TG_ARGV) a;
  v_key := coalesce(v_row->>'centre_id', 'global');
  PERFORM pg_advisory_xact_lock(hashtextextended('audit:' || v_key, 0));
  SELECT row_hash INTO v_prev FROM audit.audit_log WHERE chain_key = v_key ORDER BY audit_id DESC LIMIT 1;
  v_hash := public.digest(coalesce(encode(v_prev, 'hex'), '') || TG_TABLE_SCHEMA || TG_TABLE_NAME || v_pk || TG_OP
                   || coalesce(v_old::text, '') || coalesce(v_new::text, '') || coalesce(app.current_user_id()::text, ''),
                   'sha256');
  INSERT INTO audit.audit_log (user_id, active_centre_id, centre_id, schema_name, table_name, row_pk, action,
                               old_values, new_values, reason, chain_key, prev_hash, row_hash)
  VALUES (app.current_user_id(), app.current_centre_id(), (v_row->>'centre_id')::uuid, TG_TABLE_SCHEMA,
          TG_TABLE_NAME, v_pk, TG_OP, v_old, v_new, app.change_reason(), v_key, v_prev, v_hash);
  RETURN NULL;
END $$;

CREATE TRIGGER audit_log_immutable BEFORE UPDATE OR DELETE ON audit.audit_log
  FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();
CREATE OR REPLACE FUNCTION audit.forbid_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'audit tables cannot be truncated' USING ERRCODE = 'insufficient_privilege'; END $$;
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION audit.forbid_truncate();

-- Reads that matter (record opened, export downloaded, document viewed),
-- written by the API.  Same append-only protection.
CREATE TABLE audit.access_log (
  access_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  user_id        uuid NOT NULL DEFAULT app.current_user_id(),
  db_role        text NOT NULL DEFAULT current_user,
  active_centre_id uuid DEFAULT app.current_centre_id(),
  access_type    text NOT NULL CHECK (access_type IN ('patient_record_view','document_view','document_download',
                   'export_download','search','login','logout','failed_login','permission_denied')),
  patient_id     uuid,
  entity_name    text,
  entity_id      text,
  client_ip      inet,
  user_agent     text,
  detail         jsonb
);
CREATE INDEX access_log_patient ON audit.access_log (patient_id, occurred_at);
CREATE TRIGGER access_log_immutable BEFORE UPDATE OR DELETE ON audit.access_log
  FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();
CREATE TRIGGER access_log_no_truncate BEFORE TRUNCATE ON audit.access_log
  FOR EACH STATEMENT EXECUTE FUNCTION audit.forbid_truncate();

-- Chain verifier: recomputes every row's hash and checks each link.
-- ok = false marks a row whose content or position was altered.
CREATE OR REPLACE FUNCTION audit.verify_chain(p_chain_key text)
RETURNS TABLE (audit_id bigint, ok boolean) LANGUAGE sql STABLE AS $$
  SELECT a.audit_id,
         a.prev_hash IS NOT DISTINCT FROM lag(a.row_hash) OVER (ORDER BY a.audit_id)
         AND a.row_hash = public.digest(coalesce(encode(a.prev_hash, 'hex'), '') || a.schema_name || a.table_name
               || a.row_pk || a.action || coalesce(a.old_values::text, '') || coalesce(a.new_values::text, '')
               || coalesce(a.user_id::text, ''), 'sha256')
  FROM audit.audit_log a WHERE a.chain_key = p_chain_key ORDER BY a.audit_id
$$;

-- ---------------------------------------------------------------------
-- 13  RESEARCH: study pseudonyms, export jobs, pseudonymised views.
-- Views are owned by the schema owner (bypass RLS) and do their own
-- filtering: only protocols and centres in the caller's study membership,
-- only enrolled patients, never patients whose consent withdrawal asked
-- for their data to be excluded.  No names, contacts, codes or exact dates.
-- ---------------------------------------------------------------------
CREATE TABLE research.study_subjects (
  enrolment_id       uuid PRIMARY KEY REFERENCES registry.enrolments,
  protocol_id        uuid NOT NULL REFERENCES registry.registry_protocols,
  study_subject_code text NOT NULL UNIQUE,       -- e.g. 'HF-7K3Q9P'
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION research.assign_study_subject() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, research, registry AS $$
DECLARE v_prefix text; v_code text;
BEGIN
  IF NEW.enrolment_status = 'enrolled' THEN
    SELECT rt.registry_code INTO v_prefix FROM registry.registry_types rt WHERE rt.registry_type_id = NEW.registry_type_id;
    LOOP
      v_code := v_prefix || '-' || upper(substr(translate(encode(public.gen_random_bytes(8), 'base64'), '+/=0O1Il', ''), 1, 6));
      EXIT WHEN length(v_code) = length(v_prefix) + 7
            AND NOT EXISTS (SELECT 1 FROM research.study_subjects WHERE study_subject_code = v_code);
    END LOOP;
    INSERT INTO research.study_subjects (enrolment_id, protocol_id, study_subject_code)
    VALUES (NEW.enrolment_id, NEW.protocol_id, v_code) ON CONFLICT (enrolment_id) DO NOTHING;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER enrolments_study_subject AFTER INSERT OR UPDATE OF enrolment_status ON registry.enrolments
  FOR EACH ROW EXECUTE FUNCTION research.assign_study_subject();

CREATE TABLE research.export_jobs (
  export_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  protocol_id      uuid NOT NULL REFERENCES registry.registry_protocols,
  requested_by     uuid NOT NULL DEFAULT app.current_user_id() REFERENCES iam.users,
  requested_at     timestamptz NOT NULL DEFAULT now(),
  purpose          text NOT NULL,
  centre_ids       uuid[],                       -- NULL = all centres the requester may see
  cohort_filter    jsonb NOT NULL DEFAULT '{}',
  index_date_rule  text NOT NULL DEFAULT 'enrolment_index_date',
  visit_codes      text[],
  variable_codes   text[] NOT NULL,
  deidentification text NOT NULL CHECK (deidentification IN ('pseudonymised_relative_days',
                     'pseudonymised_year_only','aggregate_only')),
  file_format      text NOT NULL CHECK (file_format IN ('csv','xlsx','spss_csv','r_csv','stata_csv')),
  missing_value_codes jsonb NOT NULL DEFAULT '{"not_done":-97,"unknown":-98,"not_applicable":-99,"missing":""}',
  include_data_dictionary boolean NOT NULL DEFAULT true,
  status           text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','approved','rejected',
                     'running','completed','failed','expired')),
  approved_by      uuid REFERENCES iam.users,
  approved_at      timestamptz,
  row_count        integer,
  file_storage_key text,
  file_sha256      bytea,
  completed_at     timestamptz,
  expires_at       timestamptz,
  CHECK (status NOT IN ('approved','running','completed') OR approved_by IS NOT NULL),
  CHECK (approved_by IS NULL OR approved_by <> requested_by)          -- four-eyes rule
);

CREATE OR REPLACE VIEW research.v_enrolments AS
SELECT s.study_subject_code, p.protocol_code, p.protocol_version, rt.registry_code, c.centre_code,
       r.sex,
       CASE WHEN r.date_of_birth IS NULL THEN NULL
            ELSE extract(year FROM age(e.index_date, r.date_of_birth))::int END AS age_at_index,
       extract(year FROM e.index_date)::int AS index_year,
       e.enrolment_date - e.index_date AS enrolment_day,
       e.enrolment_status,
       e.status_changed_on - e.index_date AS status_change_day
FROM registry.enrolments e
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
JOIN registry.registry_protocols p ON p.protocol_id = e.protocol_id
JOIN registry.registry_types rt ON rt.registry_type_id = e.registry_type_id
JOIN iam.centres c ON c.centre_id = e.centre_id
JOIN clinical.patient_registrations r ON r.patient_id = e.patient_id AND r.centre_id = e.centre_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_hf_assessments AS
SELECT s.study_subject_code, a.visit_code, a.days_from_index, a.within_window, a.completion_status,
       h.nyha_class, h.systolic_bp, h.diastolic_bp, h.heart_rate, h.bmi, h.congestion_status,
       h.lvef, h.lvedd_mm, h.lvesd_mm, h.la_volume_index_ml_m2, h.tapse_mm, h.rv_function, h.hf_phenotype,
       h.nt_probnp_pg_ml, h.haemoglobin_g_dl, h.creatinine_mg_dl, h.egfr_ml_min, h.sodium_mmol_l,
       h.potassium_mmol_l, h.has_diabetes, h.has_hypertension, h.has_ckd, h.has_af, h.has_cad, h.has_anaemia,
       h.device_types, h.pillars_eligible, h.pillars_prescribed, h.pillars_at_target
FROM registry.hf_assessment_data h
JOIN registry.assessments a ON a.assessment_id = h.assessment_id
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_hf_gdmt AS
SELECT s.study_subject_code, a.visit_code, a.days_from_index, g.pillar_code, g.eligible, g.prescribed,
       d.generic_name AS drug, g.daily_dose, g.target_daily_dose, g.pct_target_dose, g.dose_status,
       g.initiation_date - e.index_date AS initiation_day, g.last_titration_date - e.index_date AS last_titration_day,
       rs.rule_set_code || ' v' || rs.version AS target_dose_reference,
       (SELECT array_agg(reason_code ORDER BY reason_code) FROM registry.hf_gdmt_reasons r
         WHERE r.assessment_id = g.assessment_id AND r.pillar_code = g.pillar_code) AS reasons
FROM registry.hf_gdmt_status g
JOIN registry.assessments a ON a.assessment_id = g.assessment_id
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
JOIN ref.rule_sets rs ON rs.rule_set_id = g.rule_set_id
LEFT JOIN ref.drugs d ON d.drug_id = g.drug_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_lipid_assessments AS
SELECT s.study_subject_code, a.visit_code, a.days_from_index, l.lipid_test_status,
       l.lipid_collected_on - e.index_date AS lipid_day, l.ldl_mg_dl, l.ldl_method, l.total_chol_mg_dl,
       l.hdl_mg_dl, l.tg_mg_dl, l.non_hdl_mg_dl, l.apob_mg_dl,
       rs.rule_set_code || ' v' || rs.version AS ldl_guideline, l.risk_category, l.ldl_target_mg_dl,
       l.ldl_target_met, l.ldl_abs_reduction_mg_dl, l.ldl_pct_reduction, l.reduction_50pct_met, l.target_status,
       l.statin_intensity, l.statin_daily_dose_mg, l.on_ezetimibe, l.on_pcsk9_mab, l.on_inclisiran,
       l.on_bempedoic_acid, l.therapy_change, l.non_intensification_reason, l.adherence, l.muscle_symptoms
FROM registry.lipid_assessment_data l
JOIN registry.assessments a ON a.assessment_id = l.assessment_id
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
LEFT JOIN ref.rule_sets rs ON rs.rule_set_id = l.ldl_rule_set_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_events AS
SELECT s.study_subject_code, p.protocol_code, ev.event_type, ev.event_date - e.index_date AS event_day,
       ev.is_historical OR ev.event_date < e.index_date AS before_index, ev.hospitalised,
       ev.discharge_date - ev.admission_date AS length_of_stay_days, ev.death_cause, ev.death_cv_mode,
       ev.mi_type, ev.stroke_type, ev.severity, ev.outcome, ev.source,
       ed.endpoint_code, adj.adjudication_status, adj.classification, adj.meets_endpoint
FROM clinical.clinical_events ev
JOIN registry.enrolments e ON e.patient_id = ev.patient_id AND e.centre_id = ev.centre_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
JOIN registry.registry_protocols p ON p.protocol_id = e.protocol_id
LEFT JOIN registry.event_adjudications adj ON adj.event_id = ev.event_id AND adj.protocol_id = e.protocol_id
LEFT JOIN registry.endpoint_definitions ed ON ed.endpoint_id = adj.endpoint_id
WHERE ev.status <> 'entered_in_error'
  AND e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');
-- ---------------------------------------------------------------------
-- 14a  CROSS-CUTTING TRIGGERS
-- ---------------------------------------------------------------------
-- organisation_id always follows centre_id: the API never supplies it.
CREATE OR REPLACE FUNCTION app.set_organisation_from_centre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
BEGIN
  SELECT organisation_id INTO NEW.organisation_id FROM iam.centres WHERE centre_id = NEW.centre_id;
  IF NEW.organisation_id IS NULL THEN
    RAISE EXCEPTION 'unknown centre %', NEW.centre_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END $$;

-- Signed encounters are frozen.  Allowed changes: status -> amended or
-- entered_in_error (with reason), and patient_id via a confirmed merge.
CREATE OR REPLACE FUNCTION clinical.encounter_signed_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE allowed text[] := ARRAY['status','error_reason','patient_id','updated_at','updated_by','row_version'];
BEGIN
  IF OLD.status IN ('signed','amended','entered_in_error') THEN
    IF (to_jsonb(NEW) - allowed) <> (to_jsonb(OLD) - allowed)
       OR (NEW.status <> OLD.status AND NEW.status NOT IN ('amended','entered_in_error'))
       OR OLD.status = 'entered_in_error' AND NEW.status <> OLD.status THEN
      RAISE EXCEPTION 'encounter % is signed; record an amendment instead', OLD.encounter_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  IF NEW.status = 'signed' AND OLD.status = 'draft' AND NEW.signed_by IS DISTINCT FROM app.current_user_id() THEN
    RAISE EXCEPTION 'only the signing user can sign' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER encounters_signed_guard BEFORE UPDATE ON clinical.encounters
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_signed_guard();

-- Children written into a signed encounter are frozen with it.
CREATE OR REPLACE FUNCTION clinical.encounter_child_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'patient_id') = (to_jsonb(OLD) - 'patient_id') THEN
    RETURN NEW;
  END IF;
  IF NEW.encounter_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM clinical.encounters WHERE encounter_id = NEW.encounter_id
         AND status IN ('signed','amended','entered_in_error')) THEN
    RAISE EXCEPTION '% belongs to a signed encounter; record an amendment instead', TG_TABLE_NAME
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER encounter_complaints_guard BEFORE INSERT OR UPDATE ON clinical.encounter_complaints
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_child_guard();
CREATE TRIGGER clinical_assessments_guard BEFORE INSERT OR UPDATE ON clinical.clinical_assessments
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_child_guard();
CREATE TRIGGER vital_signs_guard BEFORE INSERT OR UPDATE ON clinical.vital_signs
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_child_guard();

CREATE TRIGGER encounter_amendments_append_only BEFORE UPDATE OR DELETE ON clinical.encounter_amendments
  FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();
CREATE TRIGGER hf_gdmt_reasons_append_only BEFORE UPDATE OR DELETE ON registry.hf_gdmt_reasons
  FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();

-- Amendment insert flips the encounter to 'amended'.
CREATE OR REPLACE FUNCTION clinical.encounter_amendment_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clinical.encounters WHERE encounter_id = NEW.encounter_id
                   AND status IN ('signed','amended')) THEN
    RAISE EXCEPTION 'only signed encounters take amendments; edit the draft instead' USING ERRCODE = 'check_violation';
  END IF;
  UPDATE clinical.encounters SET status = 'amended' WHERE encounter_id = NEW.encounter_id AND status = 'signed';
  RETURN NEW;
END $$;
CREATE TRIGGER encounter_amendments_apply AFTER INSERT ON clinical.encounter_amendments
  FOR EACH ROW EXECUTE FUNCTION clinical.encounter_amendment_apply();

-- Attach row-meta, organisation and audit triggers to every table.
DO $$
DECLARE t record; pk text[];
BEGIN
  FOR t IN
    SELECT c.oid, n.nspname, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p') AND n.nspname IN ('iam','ref','clinical','registry','research')
  LOOP
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t.oid AND attname = 'row_version' AND NOT attisdropped) THEN
      EXECUTE format('CREATE TRIGGER zz_touch_row BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION app.touch_row()',
                     t.nspname, t.relname);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t.oid AND attname = 'organisation_id' AND NOT attisdropped)
       AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = t.oid AND attname = 'centre_id' AND NOT attisdropped)
       AND t.nspname <> 'iam' THEN
      EXECUTE format('CREATE TRIGGER aa_set_organisation BEFORE INSERT OR UPDATE OF centre_id ON %I.%I '
                     'FOR EACH ROW EXECUTE FUNCTION app.set_organisation_from_centre()', t.nspname, t.relname);
    END IF;
    SELECT array_agg(a.attname ORDER BY a.attnum) INTO pk
      FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
     WHERE i.indrelid = t.oid AND i.indisprimary;
    IF pk IS NOT NULL AND t.relname <> 'patient_match_keys' THEN
      EXECUTE format('CREATE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW '
                     'EXECUTE FUNCTION audit.capture(%s)', t.nspname, t.relname,
                     (SELECT string_agg(quote_literal(x), ',') FROM unnest(pk) x));
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 14b  PATIENT HELPERS (security definer, narrow)
-- ---------------------------------------------------------------------
-- A centre argument is valid only if it is the active centre and the
-- user holds an active role there (checked against the database, not the API).
CREATE OR REPLACE FUNCTION app._centre_arg_ok(p_centre uuid, p_role text DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, iam AS $$
  SELECT p_centre IS NOT NULL AND p_centre = app.current_centre_id() AND EXISTS (
    SELECT 1 FROM iam.user_centre_roles WHERE user_id = app.current_user_id() AND centre_id = p_centre
      AND status = 'active' AND (p_role IS NULL OR role = p_role)
      AND current_date >= valid_from AND (valid_to IS NULL OR current_date <= valid_to))
$$;

-- Next local code for the active centre, e.g. 'PUN1-000124'.
CREATE OR REPLACE FUNCTION clinical.next_local_patient_code() RETURNS text
LANGUAGE sql AS $$ SELECT clinical._next_local_patient_code(app.visible_centre()) $$;
CREATE OR REPLACE FUNCTION clinical._next_local_patient_code(v_centre uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, clinical, iam AS $$
DECLARE v_n bigint; v_code text;
BEGIN
  IF NOT app._centre_arg_ok(v_centre) THEN RAISE EXCEPTION 'no active centre' USING ERRCODE = 'insufficient_privilege'; END IF;
  INSERT INTO clinical.centre_code_counters (centre_id, last_value) VALUES (v_centre, 1)
  ON CONFLICT (centre_id) DO UPDATE SET last_value = centre_code_counters.last_value + 1
  RETURNING last_value INTO v_n;
  SELECT centre_code INTO v_code FROM iam.centres WHERE centre_id = v_centre;
  RETURN v_code || '-' || lpad(v_n::text, 6, '0');
END $$;

-- Store match keys for a registration at the caller's centre.
CREATE OR REPLACE FUNCTION clinical.set_match_keys(p_registration uuid, p_keys jsonb) RETURNS void
LANGUAGE sql AS $$ SELECT clinical._set_match_keys(app.visible_centre(), p_registration, p_keys) $$;
CREATE OR REPLACE FUNCTION clinical._set_match_keys(p_centre uuid, p_registration uuid, p_keys jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, clinical AS $$
BEGIN
  IF NOT app._centre_arg_ok(p_centre) OR NOT EXISTS (SELECT 1 FROM clinical.patient_registrations
                 WHERE registration_id = p_registration AND centre_id = p_centre) THEN
    RAISE EXCEPTION 'registration not at active centre' USING ERRCODE = 'insufficient_privilege';
  END IF;
  DELETE FROM clinical.patient_match_keys WHERE registration_id = p_registration;
  INSERT INTO clinical.patient_match_keys (registration_id, key_type, key_hmac)
  SELECT p_registration, k, decode(v, 'hex') FROM jsonb_each_text(p_keys) AS j(k, v);
END $$;

-- Candidate master patients at OTHER centres sharing keys with this
-- registration.  Returns only the master id and which key types matched:
-- no name, contact, centre or clinical data crosses the boundary.
CREATE OR REPLACE FUNCTION clinical.find_match_candidates(p_registration uuid)
RETURNS TABLE (candidate_patient_id uuid, matched_key_types text[], strength text)
LANGUAGE sql STABLE AS $$ SELECT * FROM clinical._find_match_candidates(app.visible_centre(), p_registration) $$;
CREATE OR REPLACE FUNCTION clinical._find_match_candidates(p_centre uuid, p_registration uuid)
RETURNS TABLE (candidate_patient_id uuid, matched_key_types text[], strength text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, clinical AS $$
  SELECT r2.patient_id, array_agg(DISTINCT k2.key_type ORDER BY k2.key_type),
         CASE WHEN bool_or(k2.key_type = 'abha') OR count(DISTINCT k2.key_type) >= 2 THEN 'strong' ELSE 'weak' END
  FROM clinical.patient_registrations r1
  JOIN clinical.patient_match_keys k1 ON k1.registration_id = r1.registration_id
  JOIN clinical.patient_match_keys k2 ON k2.key_type = k1.key_type AND k2.key_hmac = k1.key_hmac
  JOIN clinical.patient_registrations r2 ON r2.registration_id = k2.registration_id
  WHERE r1.registration_id = p_registration
    AND r1.centre_id = p_centre
    AND app._centre_arg_ok(p_centre)
    AND r2.patient_id <> r1.patient_id
    AND r2.status <> 'entered_in_error'
  GROUP BY r2.patient_id
$$;

-- Confirm a link: re-point this centre's registration (and, by cascade,
-- all its clinical rows) to the existing master patient.  Requires a
-- cross-centre linkage consent.  Other centres' records stay invisible.
CREATE OR REPLACE FUNCTION clinical.confirm_patient_link(p_link_request uuid) RETURNS void
LANGUAGE sql AS $$ SELECT clinical._confirm_patient_link(app.visible_centre(), app.current_app_role(), p_link_request) $$;
CREATE OR REPLACE FUNCTION clinical._confirm_patient_link(p_centre uuid, p_role text, p_link_request uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, clinical AS $$
DECLARE lr record; v_old_patient uuid;
BEGIN
  SELECT * INTO lr FROM clinical.patient_link_requests
   WHERE link_request_id = p_link_request AND centre_id = p_centre AND status = 'proposed'
   FOR UPDATE;
  IF lr IS NULL THEN RAISE EXCEPTION 'no open link request at this centre' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_role IS NULL OR p_role NOT IN ('clinician','centre_admin') OR NOT app._centre_arg_ok(p_centre, p_role) THEN
    RAISE EXCEPTION 'only a clinician or centre admin may confirm a link' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clinical.patient_consents WHERE consent_id = lr.linkage_consent_id
                   AND consent_type = 'cross_centre_linkage' AND consent_status = 'active') THEN
    RAISE EXCEPTION 'linkage needs an active cross-centre linkage consent' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM clinical.patient_registrations
             WHERE patient_id = lr.candidate_patient_id AND centre_id = lr.centre_id) THEN
    RAISE EXCEPTION 'target patient already registered at this centre; use a merge' USING ERRCODE = 'unique_violation';
  END IF;
  SELECT patient_id INTO v_old_patient FROM clinical.patient_registrations WHERE registration_id = lr.registration_id;
  UPDATE clinical.patient_registrations SET patient_id = lr.candidate_patient_id, linkage_status = 'linked'
   WHERE registration_id = lr.registration_id;               -- cascades to every child row at this centre
  UPDATE clinical.patients SET status = 'merged', merged_into_patient_id = lr.candidate_patient_id
   WHERE patient_id = v_old_patient
     AND NOT EXISTS (SELECT 1 FROM clinical.patient_registrations WHERE patient_id = v_old_patient);
  UPDATE clinical.patient_link_requests SET status = 'confirmed', decided_by = app.current_user_id(), decided_at = now()
   WHERE link_request_id = p_link_request;
END $$;

-- ---------------------------------------------------------------------
-- 14c  ROW-LEVEL SECURITY
-- Pattern: every patient-data row is visible and writable only when its
-- centre_id equals app.visible_centre(), i.e. the active centre where the
-- user holds the role the API switched into.  The function is wrapped in
-- a sub-select so the planner evaluates it once per statement.
-- ---------------------------------------------------------------------
DO $$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT n.nspname, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p') AND n.nspname IN ('clinical','registry')
      AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'centre_id' AND NOT a.attisdropped)
      AND c.relname NOT IN ('protocol_sites','centre_code_counters','event_adjudications')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', t.nspname, t.relname);
    EXECUTE format('CREATE POLICY centre_isolation ON %I.%I USING (centre_id = (SELECT app.visible_centre())) '
                   'WITH CHECK (centre_id = (SELECT app.visible_centre()))', t.nspname, t.relname);
  END LOOP;
END $$;

-- Tables without centre_id that still hold patient data.
ALTER TABLE clinical.patients ENABLE ROW LEVEL SECURITY;
CREATE POLICY patients_via_registration ON clinical.patients FOR SELECT
  USING (EXISTS (SELECT 1 FROM clinical.patient_registrations r
                 WHERE r.patient_id = patients.patient_id AND r.centre_id = (SELECT app.visible_centre())));
CREATE POLICY patients_insert ON clinical.patients FOR INSERT
  WITH CHECK ((SELECT app.visible_centre()) IS NOT NULL);
-- Status changes to patients happen only through confirm_patient_link().

ALTER TABLE clinical.patient_match_keys ENABLE ROW LEVEL SECURITY;   -- no policy: invisible to all app roles
ALTER TABLE clinical.centre_code_counters ENABLE ROW LEVEL SECURITY;

-- Adjudication: site staff at the event's centre, or study members of the protocol.
ALTER TABLE registry.event_adjudications ENABLE ROW LEVEL SECURITY;
CREATE POLICY adjudication_site ON registry.event_adjudications
  USING (centre_id = (SELECT app.visible_centre()) OR centre_id = ANY (app.study_centres(protocol_id)))
  WITH CHECK (centre_id = (SELECT app.visible_centre()) OR centre_id = ANY (app.study_centres(protocol_id)));

ALTER TABLE registry.study_memberships ENABLE ROW LEVEL SECURITY;
CREATE POLICY memberships_own_or_admin ON registry.study_memberships
  USING (user_id = app.current_user_id() OR app.is_platform_admin())
  WITH CHECK (app.is_platform_admin());

ALTER TABLE research.export_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY export_jobs_study ON research.export_jobs
  USING (app.study_centres(protocol_id) IS NOT NULL)
  WITH CHECK (app.study_centres(protocol_id) IS NOT NULL
              AND EXISTS (SELECT 1 FROM registry.study_memberships m
                          WHERE m.user_id = app.current_user_id() AND m.protocol_id = export_jobs.protocol_id
                            AND m.can_export AND m.status = 'active'));

-- IAM tables.
ALTER TABLE iam.organisations ENABLE ROW LEVEL SECURITY;
CREATE POLICY organisations_read ON iam.organisations FOR SELECT
  USING (app.is_platform_admin() OR organisation_id = (SELECT app.visible_organisation()));
CREATE POLICY organisations_admin ON iam.organisations FOR ALL
  USING (app.is_platform_admin()) WITH CHECK (app.is_platform_admin());

ALTER TABLE iam.centres ENABLE ROW LEVEL SECURITY;
CREATE POLICY centres_read ON iam.centres FOR SELECT
  USING (app.is_platform_admin() OR organisation_id = (SELECT app.visible_organisation())
         OR centre_id IN (SELECT ps.centre_id FROM registry.protocol_sites ps
                          WHERE app.study_centres(ps.protocol_id) IS NOT NULL));
CREATE POLICY centres_platform_admin ON iam.centres FOR ALL
  USING (app.is_platform_admin()) WITH CHECK (app.is_platform_admin());
CREATE POLICY centres_centre_admin ON iam.centres FOR UPDATE
  USING (current_user::text = 'r_centre_admin' AND centre_id = (SELECT app.visible_centre()))
  WITH CHECK (centre_id = (SELECT app.visible_centre()));

ALTER TABLE iam.users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_read ON iam.users FOR SELECT
  USING (user_id = app.current_user_id() OR app.is_platform_admin()
         OR EXISTS (SELECT 1 FROM iam.user_centre_roles r
                    WHERE r.user_id = users.user_id AND r.organisation_id = (SELECT app.visible_organisation())));
CREATE POLICY users_admin_write ON iam.users FOR INSERT
  WITH CHECK (app.is_platform_admin() OR current_user::text = 'r_centre_admin');
CREATE POLICY users_admin_update ON iam.users FOR UPDATE
  USING (app.is_platform_admin() OR (current_user::text = 'r_centre_admin' AND EXISTS (
         SELECT 1 FROM iam.user_centre_roles r WHERE r.user_id = users.user_id
           AND r.organisation_id = (SELECT app.visible_organisation()))))
  WITH CHECK (platform_role IS NULL OR app.is_platform_admin());    -- centre admins cannot mint platform admins

ALTER TABLE iam.user_centre_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY ucr_read ON iam.user_centre_roles FOR SELECT
  USING (user_id = app.current_user_id() OR app.is_platform_admin()
         OR organisation_id = (SELECT app.visible_organisation()));
CREATE POLICY ucr_admin_write ON iam.user_centre_roles FOR ALL
  USING (app.is_platform_admin() OR (current_user::text = 'r_centre_admin'
         AND organisation_id = (SELECT app.visible_organisation())))
  WITH CHECK (app.is_platform_admin() OR (current_user::text = 'r_centre_admin'
         AND organisation_id = (SELECT app.visible_organisation())
         AND user_id <> app.current_user_id()));               -- no self-granting

-- ---------------------------------------------------------------------
-- 15  GRANTS  (second lock beside RLS: what each role may do at all)
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA iam, ref, clinical, registry, audit, research FROM PUBLIC;
REVOKE ALL ON SCHEMA iam, ref, clinical, registry, audit, research, app FROM PUBLIC;

GRANT USAGE ON SCHEMA app, iam, ref TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin, r_audit_reader;
GRANT USAGE ON SCHEMA clinical, registry TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT USAGE ON SCHEMA research TO r_research_coordinator, r_principal_investigator;
GRANT USAGE ON SCHEMA audit TO r_audit_reader, r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
-- Definer helpers (names starting with _) are executable because their invoker
-- wrappers run as the caller; each helper re-validates its centre argument.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app, clinical, registry TO r_assistant, r_nurse, r_clinician,
  r_research_coordinator, r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA clinical TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator;

-- Reference data: everyone reads, platform admins curate.
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA ref TO r_platform_admin;

-- IAM
GRANT SELECT ON ALL TABLES IN SCHEMA iam TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT INSERT, UPDATE ON iam.users, iam.user_centre_roles TO r_centre_admin, r_platform_admin;
GRANT UPDATE ON iam.centres TO r_centre_admin;
GRANT INSERT, UPDATE ON iam.organisations, iam.centres TO r_platform_admin;

-- Clinical: front desk tables (registration, consent, appointments, documents)
GRANT SELECT, INSERT, UPDATE ON clinical.patients, clinical.patient_registrations, clinical.patient_consents,
  clinical.patient_link_requests, clinical.appointments, clinical.documents
  TO r_assistant, r_nurse, r_clinician, r_research_coordinator, r_principal_investigator;

-- Clinical: measurements and history the assistant may enter
GRANT SELECT, INSERT, UPDATE ON clinical.vital_signs, clinical.lifestyle_observations, clinical.family_history,
  clinical.allergies TO r_assistant, r_nurse, r_clinician;
GRANT SELECT ON clinical.vital_signs, clinical.lifestyle_observations, clinical.family_history, clinical.allergies
  TO r_research_coordinator, r_principal_investigator;

-- Clinical: consultation, diagnosis, investigations (clinician and nurse write)
GRANT SELECT ON clinical.encounters, clinical.encounter_complaints, clinical.encounter_amendments,
  clinical.clinical_assessments, clinical.diagnoses, clinical.cardiac_devices, clinical.investigations,
  clinical.lab_results, clinical.ecg_reports, clinical.echo_reports, clinical.echo_valve_findings,
  clinical.coronary_angiograms, clinical.coronary_segment_findings, clinical.pci_procedures, clinical.pci_lesions,
  clinical.pci_stents, clinical.clinical_events, clinical.ai_jobs, clinical.ai_extracted_fields,
  clinical.medication_courses, clinical.medication_events, clinical.medication_adherence,
  clinical.adverse_drug_reactions
  TO r_assistant, r_nurse, r_clinician, r_research_coordinator, r_principal_investigator;
GRANT INSERT, UPDATE ON clinical.encounters, clinical.encounter_complaints, clinical.clinical_assessments,
  clinical.diagnoses, clinical.cardiac_devices, clinical.investigations, clinical.lab_results, clinical.ecg_reports,
  clinical.echo_reports, clinical.echo_valve_findings, clinical.coronary_angiograms,
  clinical.coronary_segment_findings, clinical.pci_procedures, clinical.pci_lesions, clinical.pci_stents,
  clinical.clinical_events, clinical.ai_jobs, clinical.ai_extracted_fields, clinical.medication_adherence,
  clinical.adverse_drug_reactions
  TO r_nurse, r_clinician;
GRANT INSERT ON clinical.encounter_amendments TO r_clinician;
-- Research coordinators abstract results and outcomes from source documents.
GRANT INSERT, UPDATE ON clinical.investigations, clinical.lab_results, clinical.ecg_reports, clinical.echo_reports,
  clinical.echo_valve_findings, clinical.clinical_events, clinical.medication_adherence, clinical.ai_jobs,
  clinical.ai_extracted_fields TO r_research_coordinator;

-- Prescribing: clinicians only (PRD 1.2).
GRANT INSERT, UPDATE ON clinical.medication_courses TO r_clinician;
GRANT INSERT ON clinical.medication_events TO r_clinician;

-- Registry data: site clinicians, coordinators and PIs.  No assistant or nurse.
GRANT SELECT ON ALL TABLES IN SCHEMA registry TO r_clinician, r_research_coordinator, r_principal_investigator,
  r_platform_admin;
GRANT SELECT ON registry.registry_suggestions, registry.registry_types TO r_nurse;
GRANT INSERT, UPDATE ON registry.enrolments, registry.assessments, registry.variable_values,
  registry.registry_suggestions, registry.hf_enrolment_details, registry.hf_assessment_data,
  registry.hf_gdmt_status, registry.lipid_enrolment_details, registry.lipid_assessment_data,
  registry.cad_enrolment_details, registry.event_adjudications
  TO r_clinician, r_research_coordinator, r_principal_investigator;
GRANT INSERT ON registry.hf_gdmt_reasons TO r_clinician, r_research_coordinator, r_principal_investigator;
-- Protocol configuration: platform admins.
GRANT INSERT, UPDATE ON registry.registry_types, registry.registry_protocols, registry.protocol_sites,
  registry.visit_schedule, registry.variable_definitions, registry.protocol_variables,
  registry.endpoint_definitions, registry.endpoint_components, registry.study_memberships TO r_platform_admin;
-- registry config tables carry no patient data: readable without RLS.
-- (platform admin gets SELECT on registry tables above but RLS hides every patient row.)

-- Research views and exports
GRANT SELECT ON ALL TABLES IN SCHEMA research TO r_research_coordinator, r_principal_investigator;
GRANT INSERT, UPDATE ON research.export_jobs TO r_research_coordinator, r_principal_investigator;
REVOKE INSERT, UPDATE, DELETE ON research.study_subjects FROM r_research_coordinator, r_principal_investigator;

-- Audit: readers only; everyone may append to the access log.
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO r_audit_reader;
GRANT INSERT ON audit.access_log TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;
GRANT EXECUTE ON FUNCTION audit.verify_chain(text) TO r_audit_reader;
REVOKE EXECUTE ON FUNCTION audit.capture() FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 16  REFERENCE SEED DATA  (all rule sets left in status 'draft' until
-- the clinical lead verifies every row against the source guideline)
-- ---------------------------------------------------------------------
-- Concepts used by registries and triggers ---------------------------
INSERT INTO ref.concepts (concept_code, domain, display_name) VALUES
 ('DX_HF','diagnosis','Heart failure'), ('DX_ICM','diagnosis','Ischaemic cardiomyopathy'),
 ('DX_DCM','diagnosis','Dilated cardiomyopathy'), ('DX_DYSLIPIDAEMIA','diagnosis','Dyslipidaemia'),
 ('DX_FH','diagnosis','Familial hypercholesterolaemia'), ('DX_CAD','diagnosis','Coronary artery disease'),
 ('DX_CCS','diagnosis','Chronic coronary syndrome'), ('DX_STEMI','diagnosis','ST-elevation myocardial infarction'),
 ('DX_NSTEMI','diagnosis','Non-ST-elevation myocardial infarction'), ('DX_UA','diagnosis','Unstable angina'),
 ('DX_MI','diagnosis','Myocardial infarction (old)'), ('DX_DM','diagnosis','Diabetes mellitus'),
 ('DX_HTN','diagnosis','Hypertension'), ('DX_CKD','diagnosis','Chronic kidney disease'),
 ('DX_AF','diagnosis','Atrial fibrillation / flutter'), ('DX_ANAEMIA','diagnosis','Anaemia'),
 ('DX_STROKE','diagnosis','Ischaemic stroke / TIA'), ('DX_PAD','diagnosis','Peripheral arterial disease'),
 ('DX_ELEVATED_LPA','diagnosis','Elevated lipoprotein(a)'),
 ('CX_CHEST_PAIN','complaint','Chest pain'), ('CX_DYSPNOEA','complaint','Dyspnoea'),
 ('CX_PALPITATIONS','complaint','Palpitations'), ('CX_SYNCOPE','complaint','Syncope'),
 ('CX_DIZZINESS','complaint','Dizziness'), ('CX_PEDAL_OEDEMA','complaint','Pedal oedema'),
 ('CX_FATIGUE','complaint','Fatigue'), ('CX_REDUCED_EXERCISE','complaint','Reduced exercise tolerance'),
 ('CX_FOLLOW_UP','complaint','Follow-up visit'),
 ('RSN_INTOLERANCE','reason','Intolerance'), ('RSN_HYPOTENSION','reason','Hypotension'),
 ('RSN_HYPERKALAEMIA','reason','Hyperkalaemia'), ('RSN_RENAL','reason','Renal dysfunction'),
 ('RSN_COST','reason','Financial constraint'), ('RSN_PATIENT_CHOICE','reason','Patient refusal'),
 ('RSN_TITRATION','reason','Dose titration'), ('RSN_NEW_DIAGNOSIS','reason','New indication');

INSERT INTO ref.concept_mappings (concept_id, code_system, code)
SELECT concept_id, 'ICD-10', m.code FROM ref.concepts c JOIN (VALUES
 ('DX_HF','I50.9'), ('DX_ICM','I25.5'), ('DX_DCM','I42.0'), ('DX_DYSLIPIDAEMIA','E78.5'), ('DX_FH','E78.01'),
 ('DX_CAD','I25.10'), ('DX_CCS','I25.9'), ('DX_STEMI','I21.3'), ('DX_NSTEMI','I21.4'), ('DX_UA','I20.0'),
 ('DX_MI','I25.2'), ('DX_DM','E11.9'), ('DX_HTN','I10'), ('DX_CKD','N18.9'), ('DX_AF','I48.91'),
 ('DX_ANAEMIA','D64.9'), ('DX_STROKE','I63.9'), ('DX_PAD','I73.9')) m(cc, code) ON m.cc = c.concept_code;

INSERT INTO ref.concept_registry_triggers (concept_id, registry_code)
SELECT concept_id, t.reg FROM ref.concepts c JOIN (VALUES
 ('DX_HF','HF'), ('DX_ICM','HF'), ('DX_ICM','CAD'), ('DX_ICM','LIPID'), ('DX_DCM','HF'),
 ('DX_DYSLIPIDAEMIA','LIPID'), ('DX_FH','LIPID'), ('DX_ELEVATED_LPA','LIPID'),
 ('DX_CAD','CAD'), ('DX_CAD','LIPID'), ('DX_CCS','CAD'), ('DX_CCS','LIPID'), ('DX_STEMI','CAD'), ('DX_STEMI','LIPID'),
 ('DX_NSTEMI','CAD'), ('DX_NSTEMI','LIPID'), ('DX_UA','CAD'), ('DX_MI','CAD'), ('DX_MI','LIPID')) t(cc, reg)
 ON t.cc = c.concept_code;

-- Analytes and unit conversions (canonical units follow Indian lab practice)
INSERT INTO ref.analytes (analyte_code, analyte_name, loinc_code, panel, canonical_unit, plausible_min, plausible_max) VALUES
 ('TC','Total cholesterol','2093-3','lipid','mg/dL',20,2000), ('LDL_C','LDL cholesterol','18262-6','lipid','mg/dL',1,1500),
 ('HDL_C','HDL cholesterol','2085-9','lipid','mg/dL',2,300), ('TG','Triglycerides','2571-8','lipid','mg/dL',5,20000),
 ('NON_HDL_C','Non-HDL cholesterol','43396-1','lipid','mg/dL',5,2000), ('APOB','Apolipoprotein B','1884-6','lipid','mg/dL',5,500),
 ('LPA_NMOL_L','Lipoprotein(a), molar','43583-4','lipid','nmol/L',0,1500), ('LPA_MG_DL','Lipoprotein(a), mass','10835-7','lipid','mg/dL',0,600),
 ('CREATININE','Creatinine','2160-0','renal','mg/dL',0.1,30), ('EGFR','eGFR','98979-8','renal','mL/min/1.73m2',1,250),
 ('UREA','Urea','3091-6','renal','mg/dL',2,600), ('NA','Sodium','2951-2','electrolyte','mmol/L',90,200),
 ('K','Potassium','2823-3','electrolyte','mmol/L',1,10), ('NT_PROBNP','NT-proBNP','33762-6','biomarker','pg/mL',0,100000),
 ('HS_TNI','High-sensitivity troponin I','89579-7','biomarker','ng/L',0,500000),
 ('HS_TNT','High-sensitivity troponin T','67151-1','biomarker','ng/L',0,100000),
 ('HS_CRP','hs-CRP','30522-7','biomarker','mg/L',0,500), ('FBS','Fasting glucose','1558-6','diabetes','mg/dL',10,1500),
 ('PPBS','Post-prandial glucose','1521-4','diabetes','mg/dL',10,1500), ('HBA1C','HbA1c','4548-4','diabetes','%',3,20),
 ('HB','Haemoglobin','718-7','haematology','g/dL',2,25), ('ALT','ALT','1742-6','liver','U/L',0,10000),
 ('AST','AST','1920-8','liver','U/L',0,10000), ('CK','Creatine kinase','2157-6','muscle','U/L',0,200000),
 ('TSH','TSH','3016-3','thyroid','mIU/L',0,500);

INSERT INTO ref.unit_conversions (analyte_code, from_unit, factor_to_canonical) VALUES
 ('TC','mmol/L',38.67), ('LDL_C','mmol/L',38.67), ('HDL_C','mmol/L',38.67), ('NON_HDL_C','mmol/L',38.67),
 ('TG','mmol/L',88.57), ('APOB','g/L',100), ('CREATININE','umol/L',0.01131), ('UREA','mmol/L',6.006),
 ('NT_PROBNP','ng/L',1), ('NT_PROBNP','pmol/L',8.457), ('HS_TNI','pg/mL',1), ('HS_TNT','pg/mL',1),
 ('HS_CRP','mg/dL',10), ('FBS','mmol/L',18.016), ('PPBS','mmol/L',18.016), ('HB','g/L',0.1),
 ('NA','mEq/L',1), ('K','mEq/L',1), ('EGFR','mL/min',1);

-- Drug classes and drugs ---------------------------------------------
INSERT INTO ref.drug_classes (drug_class_code, display_name) VALUES
 ('ARNI','Angiotensin receptor-neprilysin inhibitor'), ('ACEI','ACE inhibitor'), ('ARB','Angiotensin receptor blocker'),
 ('BETA_BLOCKER','Beta-blocker'), ('MRA','Mineralocorticoid receptor antagonist'), ('SGLT2I','SGLT2 inhibitor'),
 ('LOOP_DIURETIC','Loop diuretic'), ('IVABRADINE','Ivabradine'), ('DIGOXIN','Digoxin'),
 ('STATIN','Statin'), ('EZETIMIBE','Ezetimibe'), ('PCSK9_MAB','PCSK9 monoclonal antibody'),
 ('PCSK9_SIRNA','PCSK9 siRNA (inclisiran)'), ('BEMPEDOIC_ACID','Bempedoic acid'),
 ('ANTIPLATELET','Antiplatelet'), ('P2Y12I','P2Y12 inhibitor'), ('ANTICOAGULANT','Oral anticoagulant');

INSERT INTO ref.drugs (drug_code, generic_name, is_combination, reference_ingredient, reference_unit, default_route) VALUES
 ('SACUBITRIL_VALSARTAN','Sacubitril/valsartan',true,'sacubitril+valsartan, labelled total (50/100/200 mg tablets)','mg','oral'),
 ('ENALAPRIL','Enalapril',false,'enalapril','mg','oral'), ('RAMIPRIL','Ramipril',false,'ramipril','mg','oral'),
 ('LISINOPRIL','Lisinopril',false,'lisinopril','mg','oral'), ('CAPTOPRIL','Captopril',false,'captopril','mg','oral'),
 ('TRANDOLAPRIL','Trandolapril',false,'trandolapril','mg','oral'), ('PERINDOPRIL','Perindopril',false,'perindopril','mg','oral'),
 ('CANDESARTAN','Candesartan',false,'candesartan','mg','oral'), ('VALSARTAN','Valsartan',false,'valsartan','mg','oral'),
 ('LOSARTAN','Losartan',false,'losartan','mg','oral'), ('TELMISARTAN','Telmisartan',false,'telmisartan','mg','oral'),
 ('BISOPROLOL','Bisoprolol',false,'bisoprolol','mg','oral'), ('CARVEDILOL','Carvedilol',false,'carvedilol','mg','oral'),
 ('METOPROLOL_SUCCINATE','Metoprolol succinate (ER)',false,'metoprolol succinate','mg','oral'),
 ('METOPROLOL_TARTRATE','Metoprolol tartrate',false,'metoprolol tartrate','mg','oral'),
 ('NEBIVOLOL','Nebivolol',false,'nebivolol','mg','oral'),
 ('SPIRONOLACTONE','Spironolactone',false,'spironolactone','mg','oral'), ('EPLERENONE','Eplerenone',false,'eplerenone','mg','oral'),
 ('FINERENONE','Finerenone',false,'finerenone','mg','oral'),
 ('DAPAGLIFLOZIN','Dapagliflozin',false,'dapagliflozin','mg','oral'), ('EMPAGLIFLOZIN','Empagliflozin',false,'empagliflozin','mg','oral'),
 ('FUROSEMIDE','Furosemide',false,'furosemide','mg','oral'), ('TORSEMIDE','Torsemide',false,'torsemide','mg','oral'),
 ('IVABRADINE','Ivabradine',false,'ivabradine','mg','oral'), ('DIGOXIN','Digoxin',false,'digoxin','mg','oral'),
 ('ATORVASTATIN','Atorvastatin',false,'atorvastatin','mg','oral'), ('ROSUVASTATIN','Rosuvastatin',false,'rosuvastatin','mg','oral'),
 ('SIMVASTATIN','Simvastatin',false,'simvastatin','mg','oral'), ('PRAVASTATIN','Pravastatin',false,'pravastatin','mg','oral'),
 ('PITAVASTATIN','Pitavastatin',false,'pitavastatin','mg','oral'), ('FLUVASTATIN','Fluvastatin',false,'fluvastatin','mg','oral'),
 ('LOVASTATIN','Lovastatin',false,'lovastatin','mg','oral'), ('EZETIMIBE','Ezetimibe',false,'ezetimibe','mg','oral'),
 ('ROSUVASTATIN_EZETIMIBE','Rosuvastatin/ezetimibe',true,'rosuvastatin','mg','oral'),
 ('ATORVASTATIN_EZETIMIBE','Atorvastatin/ezetimibe',true,'atorvastatin','mg','oral'),
 ('EVOLOCUMAB','Evolocumab',false,'evolocumab','mg','sc'), ('ALIROCUMAB','Alirocumab',false,'alirocumab','mg','sc'),
 ('INCLISIRAN','Inclisiran',false,'inclisiran sodium','mg','sc'), ('BEMPEDOIC_ACID','Bempedoic acid',false,'bempedoic acid','mg','oral'),
 ('ASPIRIN','Aspirin',false,'aspirin','mg','oral'), ('CLOPIDOGREL','Clopidogrel',false,'clopidogrel','mg','oral'),
 ('TICAGRELOR','Ticagrelor',false,'ticagrelor','mg','oral'), ('PRASUGREL','Prasugrel',false,'prasugrel','mg','oral');

INSERT INTO ref.drug_class_members (drug_id, drug_class_code)
SELECT d.drug_id, m.cls FROM ref.drugs d JOIN (VALUES
 ('SACUBITRIL_VALSARTAN','ARNI'), ('ENALAPRIL','ACEI'), ('RAMIPRIL','ACEI'), ('LISINOPRIL','ACEI'), ('CAPTOPRIL','ACEI'),
 ('TRANDOLAPRIL','ACEI'), ('PERINDOPRIL','ACEI'), ('CANDESARTAN','ARB'), ('VALSARTAN','ARB'), ('LOSARTAN','ARB'),
 ('TELMISARTAN','ARB'), ('BISOPROLOL','BETA_BLOCKER'), ('CARVEDILOL','BETA_BLOCKER'), ('METOPROLOL_SUCCINATE','BETA_BLOCKER'),
 ('METOPROLOL_TARTRATE','BETA_BLOCKER'), ('NEBIVOLOL','BETA_BLOCKER'), ('SPIRONOLACTONE','MRA'), ('EPLERENONE','MRA'),
 ('FINERENONE','MRA'), ('DAPAGLIFLOZIN','SGLT2I'), ('EMPAGLIFLOZIN','SGLT2I'), ('FUROSEMIDE','LOOP_DIURETIC'),
 ('TORSEMIDE','LOOP_DIURETIC'), ('IVABRADINE','IVABRADINE'), ('DIGOXIN','DIGOXIN'),
 ('ATORVASTATIN','STATIN'), ('ROSUVASTATIN','STATIN'), ('SIMVASTATIN','STATIN'), ('PRAVASTATIN','STATIN'),
 ('PITAVASTATIN','STATIN'), ('FLUVASTATIN','STATIN'), ('LOVASTATIN','STATIN'), ('EZETIMIBE','EZETIMIBE'),
 ('ROSUVASTATIN_EZETIMIBE','STATIN'), ('ROSUVASTATIN_EZETIMIBE','EZETIMIBE'),
 ('ATORVASTATIN_EZETIMIBE','STATIN'), ('ATORVASTATIN_EZETIMIBE','EZETIMIBE'),
 ('EVOLOCUMAB','PCSK9_MAB'), ('ALIROCUMAB','PCSK9_MAB'), ('INCLISIRAN','PCSK9_SIRNA'), ('BEMPEDOIC_ACID','BEMPEDOIC_ACID'),
 ('ASPIRIN','ANTIPLATELET'), ('CLOPIDOGREL','P2Y12I'), ('TICAGRELOR','P2Y12I'), ('PRASUGREL','P2Y12I')) m(dc, cls)
 ON m.dc = d.drug_code;

INSERT INTO ref.drug_products (drug_id, brand_name, strength_label, reference_strength)
SELECT drug_id, 'Generic', s.label, s.strength FROM ref.drugs d JOIN (VALUES
 ('SACUBITRIL_VALSARTAN','24/26 mg (50 mg)',50), ('SACUBITRIL_VALSARTAN','49/51 mg (100 mg)',100),
 ('SACUBITRIL_VALSARTAN','97/103 mg (200 mg)',200), ('CARVEDILOL','3.125 mg',3.125), ('CARVEDILOL','6.25 mg',6.25),
 ('CARVEDILOL','12.5 mg',12.5), ('CARVEDILOL','25 mg',25), ('SPIRONOLACTONE','25 mg',25), ('DAPAGLIFLOZIN','10 mg',10),
 ('ROSUVASTATIN','10 mg',10), ('ROSUVASTATIN','20 mg',20), ('ATORVASTATIN','40 mg',40), ('ATORVASTATIN','80 mg',80)) s(dc, label, strength)
 ON s.dc = d.drug_code;

-- GDMT pillars and target doses ---------------------------------------
INSERT INTO ref.gdmt_pillars VALUES ('RASI','ARNI / ACEI / ARB',1), ('BB','Beta-blocker',2), ('MRA','MRA',3),
 ('SGLT2I','SGLT2 inhibitor',4);

INSERT INTO ref.rule_sets (rule_kind, rule_set_code, version, title, source_citation, effective_from, status) VALUES
 ('hf_target_dose','ESC_HF_2021_2023',1,'ESC HF guideline 2021 with 2023 focused update: evidence-based doses',
  'McDonagh TA et al. Eur Heart J 2021;42:3599 (Table 7); 2023 focused update Eur Heart J 2023;44:3627','2021-08-27','draft'),
 ('statin_intensity','ACC_AHA_2018',1,'ACC/AHA 2018 cholesterol guideline: statin intensity',
  'Grundy SM et al. Circulation 2019;139:e1082 (Table 3)','2018-11-10','draft'),
 ('ldl_target','ESC_EAS_2019',1,'ESC/EAS 2019 dyslipidaemia guideline: LDL-C goals by risk',
  'Mach F et al. Eur Heart J 2020;41:111','2019-08-31','draft');

INSERT INTO ref.hf_target_doses (rule_set_id, drug_id, pillar_code, evidence_based, target_daily_dose, target_frequency,
                                 start_daily_dose, notes)
SELECT rs.rule_set_id, d.drug_id, t.pillar, t.ev, t.target, t.freq, t.start, t.notes
FROM ref.rule_sets rs, ref.drugs d JOIN (VALUES
 ('SACUBITRIL_VALSARTAN','RASI',true,400,'BD',100,'97/103 mg BD; dose as labelled total'),
 ('ENALAPRIL','RASI',true,40,'BD',5,'ESC target 10-20 mg BD'),
 ('RAMIPRIL','RASI',true,10,'OD/BD',2.5,NULL), ('LISINOPRIL','RASI',true,35,'OD',2.5,'ESC target 20-35 mg OD'),
 ('CAPTOPRIL','RASI',true,150,'TDS',18.75,NULL), ('TRANDOLAPRIL','RASI',true,4,'OD',0.5,NULL),
 ('CANDESARTAN','RASI',true,32,'OD',4,NULL), ('VALSARTAN','RASI',true,320,'BD',80,NULL),
 ('LOSARTAN','RASI',true,150,'OD',50,NULL),
 ('BISOPROLOL','BB',true,10,'OD',1.25,NULL), ('CARVEDILOL','BB',true,50,'BD',6.25,'50 mg BD if weight > 85 kg'),
 ('METOPROLOL_SUCCINATE','BB',true,200,'OD',12.5,NULL), ('NEBIVOLOL','BB',true,10,'OD',1.25,NULL),
 ('METOPROLOL_TARTRATE','BB',false,200,'BD',25,'Not an evidence-based HFrEF beta-blocker'),
 ('SPIRONOLACTONE','MRA',true,50,'OD',25,NULL), ('EPLERENONE','MRA',true,50,'OD',25,NULL),
 ('DAPAGLIFLOZIN','SGLT2I',true,10,'OD',10,'Single dose: prescribed = at target'),
 ('EMPAGLIFLOZIN','SGLT2I',true,10,'OD',10,'Single dose: prescribed = at target')) t(dc, pillar, ev, target, freq, start, notes)
 ON t.dc = d.drug_code
WHERE rs.rule_set_code = 'ESC_HF_2021_2023';

INSERT INTO ref.hf_pillar_eligibility (rule_set_id, hf_phenotype, pillar_code, recommendation_class)
SELECT rs.rule_set_id, e.ph, e.pillar, e.cls FROM ref.rule_sets rs, (VALUES
 ('HFrEF','RASI','I'), ('HFrEF','BB','I'), ('HFrEF','MRA','I'), ('HFrEF','SGLT2I','I'),
 ('HFimpEF','RASI','continue'), ('HFimpEF','BB','continue'), ('HFimpEF','MRA','continue'), ('HFimpEF','SGLT2I','continue'),
 ('HFmrEF','SGLT2I','I'), ('HFmrEF','RASI','IIb'), ('HFmrEF','BB','IIb'), ('HFmrEF','MRA','IIb'),
 ('HFpEF','SGLT2I','I')) e(ph, pillar, cls)
WHERE rs.rule_set_code = 'ESC_HF_2021_2023';

INSERT INTO ref.statin_intensity_rules (rule_set_id, drug_id, min_daily_dose, max_daily_dose, intensity)
SELECT rs.rule_set_id, d.drug_id, s.mn, s.mx, s.i FROM ref.rule_sets rs, ref.drugs d JOIN (VALUES
 ('ATORVASTATIN',10,20,'moderate'), ('ATORVASTATIN',40,80,'high'),
 ('ATORVASTATIN_EZETIMIBE',10,20,'moderate'), ('ATORVASTATIN_EZETIMIBE',40,80,'high'),
 ('ROSUVASTATIN',5,10,'moderate'), ('ROSUVASTATIN',20,40,'high'),
 ('ROSUVASTATIN_EZETIMIBE',5,10,'moderate'), ('ROSUVASTATIN_EZETIMIBE',20,40,'high'),
 ('SIMVASTATIN',10,10,'low'), ('SIMVASTATIN',20,40,'moderate'),
 ('PRAVASTATIN',10,20,'low'), ('PRAVASTATIN',40,80,'moderate'),
 ('LOVASTATIN',20,20,'low'), ('LOVASTATIN',40,80,'moderate'),
 ('FLUVASTATIN',20,40,'low'), ('FLUVASTATIN',80,80,'moderate'),
 ('PITAVASTATIN',1,4,'moderate')) s(dc, mn, mx, i) ON s.dc = d.drug_code
WHERE rs.rule_set_code = 'ACC_AHA_2018';

INSERT INTO ref.ldl_target_rules (rule_set_id, risk_category, ldl_target_mg_dl, target_operator, min_pct_reduction,
                                  non_hdl_target_mg_dl, apob_target_mg_dl)
SELECT rs.rule_set_id, t.cat, t.ldl, '<', t.pct, t.nonhdl, t.apob FROM ref.rule_sets rs, (VALUES
 ('extreme',40,50,NULL::numeric,NULL::numeric), ('very_high',55,50,85,65), ('high',70,50,100,80),
 ('moderate',100,NULL,130,100), ('low',116,NULL,NULL,NULL)) t(cat, ldl, pct, nonhdl, apob)
WHERE rs.rule_set_code = 'ESC_EAS_2019';

-- Registries, draft protocols, visit schedules -----------------------
INSERT INTO registry.registry_types (registry_code, registry_name, description) VALUES
 ('HF','Heart failure registry','Prospective observational registry of adults with heart failure'),
 ('LIPID','Lipid management registry','Real-world lipid management, LDL-C target attainment and outcomes'),
 ('CAD','Coronary artery disease registry','Clinical characteristics, anatomy, treatment and outcomes of CAD');

INSERT INTO registry.registry_protocols (registry_type_id, protocol_code, protocol_version, protocol_title,
  inclusion_text, exclusion_text, hf_target_dose_rule_set_id, statin_rule_set_id, ldl_target_rule_set_id, effective_from)
SELECT t.registry_type_id, p.code, 1, p.title, p.inc, p.exc,
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_HF_2021_2023'),
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ACC_AHA_2018'),
  (SELECT rule_set_id FROM ref.rule_sets WHERE rule_set_code = 'ESC_EAS_2019'),
  date '2027-01-01'
FROM registry.registry_types t JOIN (VALUES
 ('HF','CEMR-HF','CardioEMR Heart Failure Registry',
  'Age >= 18; clinician-diagnosed HF (HFrEF, HFmrEF, HFpEF or HFimpEF); new, prevalent or post-discharge; outpatient or post-hospitalisation',
  'Unable or unwilling to give research consent; life expectancy < 1 year from non-cardiac cause (to confirm)'),
 ('LIPID','CEMR-LIPID','CardioEMR Lipid Management Registry',
  'Age >= 18; on or eligible for lipid-lowering therapy in any PRD 5.2 category', 'Unable or unwilling to give research consent'),
 ('CAD','CEMR-CAD','CardioEMR Coronary Artery Disease Registry',
  'Age >= 18; CCS or ACS, or prior MI/PCI/CABG', 'Unable or unwilling to give research consent')) p(reg, code, title, inc, exc)
 ON p.reg = t.registry_code;

INSERT INTO registry.visit_schedule (protocol_id, visit_code, visit_label, target_day, window_before_days,
                                     window_after_days, repeats_every_days, sort_order)
SELECT p.protocol_id, v.code, v.label, v.d, v.b, v.a, v.rep, v.o FROM registry.registry_protocols p JOIN (VALUES
 ('CEMR-HF','BL','Baseline',0,0,14,NULL::int,1), ('CEMR-HF','M1','1 month',30,7,14,NULL,2),
 ('CEMR-HF','M3','3 months',90,14,21,NULL,3), ('CEMR-HF','M6','6 months',180,30,30,NULL,4),
 ('CEMR-HF','M12','12 months',365,45,45,NULL,5), ('CEMR-HF','ANNUAL','Annual',730,45,45,365,6),
 ('CEMR-LIPID','BL','Baseline',0,0,14,NULL,1), ('CEMR-LIPID','W6_12','6-12 weeks',63,21,21,NULL,2),
 ('CEMR-LIPID','M6','6 months',180,30,30,NULL,3), ('CEMR-LIPID','M12','12 months',365,45,45,NULL,4),
 ('CEMR-LIPID','ANNUAL','Annual',730,45,45,365,5),
 ('CEMR-CAD','BL','Baseline',0,0,14,NULL,1), ('CEMR-CAD','M1','1 month',30,7,14,NULL,2),
 ('CEMR-CAD','M6','6 months',180,30,30,NULL,3), ('CEMR-CAD','M12','12 months',365,45,45,NULL,4),
 ('CEMR-CAD','ANNUAL','Annual',730,45,45,365,5)) v(pc, code, label, d, b, a, rep, o) ON v.pc = p.protocol_code;

INSERT INTO registry.endpoint_definitions (protocol_id, endpoint_code, endpoint_label, endpoint_kind,
  classification_system, event_types, qualifying_classifications, definition_text, requires_adjudication, is_primary)
SELECT p.protocol_id, e.code, e.label, e.kind, e.sys, e.ev, e.q, e.def, e.adj, e.prim
FROM registry.registry_protocols p JOIN (VALUES
 ('CEMR-HF','ACM','All-cause death','component','custom',ARRAY['death'],NULL::text[],'Death from any cause',false,false),
 ('CEMR-HF','CVD','Cardiovascular death','component','HF-ARC',ARRAY['death'],ARRAY['cardiovascular','undetermined'],'Death adjudicated cardiovascular; undetermined counted as CV',true,false),
 ('CEMR-HF','HFH','HF hospitalisation','component','HF-ARC',ARRAY['hf_hospitalisation'],NULL,'Unplanned admission >= 24 h with HF as primary reason and IV therapy escalation',true,false),
 ('CEMR-HF','UHFV','Urgent HF visit','component','HF-ARC',ARRAY['urgent_hf_visit'],NULL,'Unplanned visit needing IV diuretic without admission',true,false),
 ('CEMR-HF','CVD_HFH','CV death or first HF hospitalisation','composite','HF-ARC',NULL,NULL,'Time to first of CVD or HFH',true,true),
 ('CEMR-CAD','MACE3','3-point MACE','composite','custom',NULL,NULL,'CV death, MI, ischaemic stroke',true,true),
 ('CEMR-CAD','MI','Myocardial infarction','component','UDMI-4',ARRAY['mi'],NULL,'Fourth Universal Definition of MI',true,false),
 ('CEMR-CAD','ST','Stent thrombosis (definite/probable)','component','ARC-2',ARRAY['stent_thrombosis'],ARRAY['definite','probable'],'ARC-2 definite or probable',true,false),
 ('CEMR-CAD','BLEED_BARC35','Major bleeding (BARC 3-5)','component','BARC',ARRAY['bleeding'],ARRAY['3a','3b','3c','4','5a','5b'],'BARC type 3 to 5',true,false),
 ('CEMR-CAD','TLR','Target lesion revascularisation','component','ARC-2',ARRAY['pci','cabg'],ARRAY['clinically_driven_tlr'],'Clinically driven repeat revascularisation of the target lesion',true,false)
) e(pc, code, label, kind, sys, ev, q, def, adj, prim) ON e.pc = p.protocol_code;

INSERT INTO registry.endpoint_components (composite_endpoint_id, component_endpoint_id)
SELECT c.endpoint_id, m.endpoint_id FROM registry.endpoint_definitions c
JOIN registry.endpoint_definitions m ON m.protocol_id = c.protocol_id AND m.endpoint_code IN ('CVD','HFH')
WHERE c.endpoint_code = 'CVD_HFH';
-- Generated by dictionaries.py: HF and lipid data dictionaries v1
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'age_at_index', 'Demographics', 'Age at index date', 'integer', 'years', NULL::jsonb, 18, 110, 'calculated', 'calc.age_at_index', 'registration DOB to enrolment index date', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 0 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'age_at_index' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sex', 'Demographics', 'Sex', 'coded', NULL, '[{"code": "male", "label": "Male"}, {"code": "female", "label": "Female"}, {"code": "other", "label": "Other"}, {"code": "unknown", "label": "Unknown"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.registration_sex', 'patient_registrations.sex', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sex' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'height_cm', 'Demographics', 'Height', 'numeric', 'cm', NULL::jsonb, 100, 230, 'emr_derived', 'emr.vitals_latest', 'vital_signs.height_cm, latest in 365 d', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'height_cm' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'weight_kg', 'Demographics', 'Weight', 'numeric', 'kg', NULL::jsonb, 25, 250, 'emr_derived', 'emr.vitals_in_window', 'vital_signs.weight_kg in visit window', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'weight_kg' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bmi', 'Demographics', 'Body-mass index', 'numeric', 'kg/m2', NULL::jsonb, 10, 70, 'calculated', 'calc.bmi', 'weight / height^2', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hf_status_at_enrolment', 'Enrolment', 'HF status at enrolment', 'coded', NULL, '[{"code": "newly_diagnosed", "label": "Newly diagnosed"}, {"code": "prevalent", "label": "Prevalent at enrolment"}, {"code": "post_discharge", "label": "Referred after HF hospital discharge"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 5 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_status_at_enrolment' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hf_diagnosis_date', 'Enrolment', 'Date HF first diagnosed (day, month or year)', 'date', NULL, NULL::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 6 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_diagnosis_date' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'index_discharge_date', 'Enrolment', 'Discharge date of index HF admission', 'date', NULL, NULL::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 7 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'index_discharge_date' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'nyha_class', 'Clinical', 'NYHA functional class', 'coded', NULL, '[{"code": "I", "label": "NYHA I"}, {"code": "II", "label": "NYHA II"}, {"code": "III", "label": "NYHA III"}, {"code": "IV", "label": "NYHA IV"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.clinical_assessment', 'clinical_assessments.nyha_class', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nyha_class' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'systolic_bp', 'Clinical', 'Systolic blood pressure', 'integer', 'mmHg', NULL::jsonb, 60, 250, 'emr_derived', 'emr.vitals_in_window', 'vital_signs.systolic_bp', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'systolic_bp' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'diastolic_bp', 'Clinical', 'Diastolic blood pressure', 'integer', 'mmHg', NULL::jsonb, 30, 150, 'emr_derived', 'emr.vitals_in_window', 'vital_signs.diastolic_bp', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_bp' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'heart_rate', 'Clinical', 'Heart rate', 'integer', 'bpm', NULL::jsonb, 30, 200, 'emr_derived', 'emr.vitals_in_window', 'vital_signs.heart_rate', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'heart_rate' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'congestion_status', 'Clinical', 'Clinical congestion', 'coded', NULL, '[{"code": "euvolaemic", "label": "euvolaemic"}, {"code": "mild", "label": "mild"}, {"code": "moderate", "label": "moderate"}, {"code": "severe", "label": "severe"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.clinical_assessment', 'clinical_assessments.congestion_status', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'congestion_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'jvp_raised', 'Clinical', 'JVP raised', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.clinical_assessment', 'clinical_assessments.jvp = raised', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'jvp_raised' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'peripheral_oedema', 'Clinical', 'Peripheral oedema present', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.clinical_assessment', 'peripheral_oedema <> none', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'peripheral_oedema' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'primary_aetiology', 'Aetiology', 'Primary aetiology', 'coded', NULL, '[{"code": "ischaemic", "label": "ischaemic"}, {"code": "dilated_non_ischaemic", "label": "dilated non ischaemic"}, {"code": "hypertensive", "label": "hypertensive"}, {"code": "valvular", "label": "valvular"}, {"code": "rheumatic_valvular", "label": "rheumatic valvular"}, {"code": "tachycardia_induced", "label": "tachycardia induced"}, {"code": "peripartum", "label": "peripartum"}, {"code": "myocarditis", "label": "myocarditis"}, {"code": "infiltrative", "label": "infiltrative"}, {"code": "hypertrophic", "label": "hypertrophic"}, {"code": "chemotherapy_related", "label": "chemotherapy related"}, {"code": "alcohol_related", "label": "alcohol related"}, {"code": "congenital", "label": "congenital"}, {"code": "other", "label": "other"}, {"code": "unknown", "label": "unknown"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'primary_aetiology' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'secondary_aetiologies', 'Aetiology', 'Contributing aetiologies', 'multi_coded', NULL, '[{"code": "ischaemic", "label": "ischaemic"}, {"code": "dilated_non_ischaemic", "label": "dilated non ischaemic"}, {"code": "hypertensive", "label": "hypertensive"}, {"code": "valvular", "label": "valvular"}, {"code": "rheumatic_valvular", "label": "rheumatic valvular"}, {"code": "tachycardia_induced", "label": "tachycardia induced"}, {"code": "peripartum", "label": "peripartum"}, {"code": "myocarditis", "label": "myocarditis"}, {"code": "infiltrative", "label": "infiltrative"}, {"code": "hypertrophic", "label": "hypertrophic"}, {"code": "chemotherapy_related", "label": "chemotherapy related"}, {"code": "alcohol_related", "label": "alcohol related"}, {"code": "congenital", "label": "congenital"}, {"code": "other", "label": "other"}, {"code": "unknown", "label": "unknown"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 16 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'secondary_aetiologies' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'prior_lowest_lvef', 'Phenotype', 'Lowest documented LVEF before enrolment', 'numeric', '%', NULL::jsonb, 5, 90, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'prior_lowest_lvef' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hf_phenotype', 'Phenotype', 'HF phenotype (clinician-confirmed)', 'coded', NULL, '[{"code": "HFrEF", "label": "HFrEF"}, {"code": "HFmrEF", "label": "HFmrEF"}, {"code": "HFpEF", "label": "HFpEF"}, {"code": "HFimpEF", "label": "HFimpEF"}]'::jsonb, NULL, NULL, 'calculated', 'calc.hf_phenotype', 'registry.classify_hf_phenotype(lvef, prior_lowest_lvef)', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 18 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_phenotype' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 18 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_phenotype' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 18 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_phenotype' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 18 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_phenotype' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'echo_date', 'Echo', 'Date of echocardiogram used', 'date', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.echo_in_window', 'investigations.performed_on', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'echo_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'echo_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'echo_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'echo_date' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lvef', 'Echo', 'LV ejection fraction', 'numeric', '%', NULL::jsonb, 5, 90, 'emr_derived', 'emr.echo_in_window', 'echo_reports.lvef', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lvef_method', 'Echo', 'LVEF method', 'coded', NULL, '[{"code": "biplane_simpson", "label": "biplane simpson"}, {"code": "3d", "label": "3d"}, {"code": "teichholz", "label": "teichholz"}, {"code": "visual", "label": "visual"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.echo_in_window', 'echo_reports.lvef_method', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvef_method' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lvedd_mm', 'Echo', 'LV end-diastolic diameter', 'numeric', 'mm', NULL::jsonb, 20, 100, 'emr_derived', 'emr.echo_in_window', 'echo_reports.lvedd_mm', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvedd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvedd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvedd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvedd_mm' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lvesd_mm', 'Echo', 'LV end-systolic diameter', 'numeric', 'mm', NULL::jsonb, 10, 90, 'emr_derived', 'emr.echo_in_window', 'echo_reports.lvesd_mm', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvesd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvesd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvesd_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'lvesd_mm' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'la_volume_index', 'Echo', 'LA volume index', 'numeric', 'mL/m2', NULL::jsonb, 5, 300, 'emr_derived', 'emr.echo_in_window', 'echo_reports.la_volume_index_ml_m2', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'la_volume_index' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'la_volume_index' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'la_volume_index' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'la_volume_index' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'tapse_mm', 'Echo', 'TAPSE', 'numeric', 'mm', NULL::jsonb, 2, 40, 'emr_derived', 'emr.echo_in_window', 'echo_reports.tapse_mm', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'tapse_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'tapse_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'tapse_mm' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'tapse_mm' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rv_function', 'Echo', 'RV systolic function', 'coded', NULL, '[{"code": "normal", "label": "normal"}, {"code": "mildly_reduced", "label": "mildly reduced"}, {"code": "moderately_reduced", "label": "moderately reduced"}, {"code": "severely_reduced", "label": "severely reduced"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.echo_in_window', 'echo_reports.rv_function', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rv_function' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rv_function' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rv_function' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rv_function' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'diastolic_grade', 'Echo', 'Diastolic dysfunction grade', 'coded', NULL, '[{"code": "normal", "label": "normal"}, {"code": "grade_I", "label": "grade I"}, {"code": "grade_II", "label": "grade II"}, {"code": "grade_III", "label": "grade III"}, {"code": "indeterminate", "label": "indeterminate"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.echo_in_window', 'echo_reports.diastolic_grade', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 27 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_grade' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 27 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'diastolic_grade' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'pasp_mmhg', 'Echo', 'Pulmonary artery systolic pressure', 'integer', 'mmHg', NULL::jsonb, 10, 150, 'emr_derived', 'emr.echo_in_window', 'echo_reports.pasp_mmhg', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 28 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'pasp_mmhg' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 28 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'pasp_mmhg' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mr_severity', 'Echo', 'Mitral regurgitation severity', 'coded', NULL, '[{"code": "none", "label": "none"}, {"code": "trivial", "label": "trivial"}, {"code": "mild", "label": "mild"}, {"code": "moderate", "label": "moderate"}, {"code": "moderate_severe", "label": "moderate_severe"}, {"code": "severe", "label": "severe"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.echo_valve', 'echo_valve_findings mitral regurgitation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 29 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mr_severity' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 29 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mr_severity' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'nt_probnp', 'Laboratory', 'NT-proBNP', 'numeric', 'pg/mL', NULL::jsonb, 5, 70000, 'emr_derived', 'emr.lab_in_window', 'lab_results NT_PROBNP', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nt_probnp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'optional', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nt_probnp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nt_probnp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nt_probnp' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'nt_probnp' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'haemoglobin', 'Laboratory', 'Haemoglobin', 'numeric', 'g/dL', NULL::jsonb, 3, 22, 'emr_derived', 'emr.lab_in_window', 'lab_results HB', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'haemoglobin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'haemoglobin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'haemoglobin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'haemoglobin' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'creatinine', 'Laboratory', 'Serum creatinine', 'numeric', 'mg/dL', NULL::jsonb, 0.2, 20, 'emr_derived', 'emr.lab_in_window', 'lab_results CREATININE', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'creatinine' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'egfr', 'Laboratory', 'eGFR (CKD-EPI 2021, race-free)', 'numeric', 'mL/min/1.73m2', NULL::jsonb, 2, 200, 'calculated', 'calc.egfr_ckd_epi_2021', 'creatinine, age, sex', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'egfr' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sodium', 'Laboratory', 'Serum sodium', 'numeric', 'mmol/L', NULL::jsonb, 100, 180, 'emr_derived', 'emr.lab_in_window', 'lab_results NA', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sodium' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'potassium', 'Laboratory', 'Serum potassium', 'numeric', 'mmol/L', NULL::jsonb, 1.5, 9, 'emr_derived', 'emr.lab_in_window', 'lab_results K', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'potassium' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_diabetes', 'Comorbidities', 'Diabetes mellitus', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_DM', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_diabetes' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_diabetes' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_diabetes' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_hypertension', 'Comorbidities', 'Hypertension', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_HTN', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_hypertension' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_ckd', 'Comorbidities', 'Chronic kidney disease (eGFR < 60 or diagnosis)', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_CKD or eGFR < 60 twice 90 d apart', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_ckd' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_ckd' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_ckd' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_af', 'Comorbidities', 'Atrial fibrillation / flutter', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_AF', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_af' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_af' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_af' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_cad', 'Comorbidities', 'Coronary artery disease', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_CAD, DX_MI, DX_ICM', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_cad' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_anaemia', 'Comorbidities', 'Anaemia (Hb < 13 g/dL men, < 12 g/dL women, or diagnosis)', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.anaemia_who', 'haemoglobin, sex', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_anaemia' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'has_anaemia' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_eligible', 'Medication (GDMT)', 'ARNI / ACEI / ARB: eligible for this phenotype', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.hf_pillar_eligibility', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_eligible' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_prescribed', 'Medication (GDMT)', 'ARNI / ACEI / ARB: prescribed', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'registry.compute_gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_prescribed' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_drug', 'Medication (GDMT)', 'ARNI / ACEI / ARB: drug', 'text', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.drugs.drug_code', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_drug' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_daily_dose', 'Medication (GDMT)', 'ARNI / ACEI / ARB: total daily dose', 'numeric', 'mg/day', NULL::jsonb, 0, 2000, 'calculated', 'calc.gdmt', 'medication_events.daily_dose', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_pct_target', 'Medication (GDMT)', 'ARNI / ACEI / ARB: % of target daily dose', 'numeric', '%', NULL::jsonb, 0, 300, 'calculated', 'calc.gdmt', 'daily dose / ref.hf_target_doses', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_pct_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_dose_status', 'Medication (GDMT)', 'ARNI / ACEI / ARB: optimisation status', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "below_target_uptitrating", "label": "below target uptitrating"}, {"code": "below_target_max_tolerated", "label": "below target max tolerated"}, {"code": "not_prescribed", "label": "not prescribed"}, {"code": "not_indicated", "label": "not indicated"}]'::jsonb, NULL, NULL, 'calculated', 'calc.gdmt + clinician confirmation', 'calc.gdmt + clinician confirmation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_dose_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'rasi_reasons', 'Medication (GDMT)', 'ARNI / ACEI / ARB: reasons not prescribed / not at target', 'multi_coded', NULL, '[{"code": "contraindication", "label": "contraindication"}, {"code": "intolerance", "label": "intolerance"}, {"code": "hypotension", "label": "hypotension"}, {"code": "hyperkalaemia", "label": "hyperkalaemia"}, {"code": "renal_dysfunction", "label": "renal dysfunction"}, {"code": "bradycardia", "label": "bradycardia"}, {"code": "worsening_hf", "label": "worsening hf"}, {"code": "patient_refusal", "label": "patient refusal"}, {"code": "financial", "label": "financial"}, {"code": "drug_unavailable", "label": "drug unavailable"}, {"code": "titration_in_progress", "label": "titration in progress"}, {"code": "recently_initiated", "label": "recently initiated"}, {"code": "not_indicated_for_phenotype", "label": "not indicated for phenotype"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'rasi_reasons' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_eligible', 'Medication (GDMT)', 'Beta-blocker: eligible for this phenotype', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.hf_pillar_eligibility', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_eligible' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_prescribed', 'Medication (GDMT)', 'Beta-blocker: prescribed', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'registry.compute_gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 50 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_prescribed' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_drug', 'Medication (GDMT)', 'Beta-blocker: drug', 'text', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.drugs.drug_code', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 51 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_drug' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_daily_dose', 'Medication (GDMT)', 'Beta-blocker: total daily dose', 'numeric', 'mg/day', NULL::jsonb, 0, 2000, 'calculated', 'calc.gdmt', 'medication_events.daily_dose', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 52 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_pct_target', 'Medication (GDMT)', 'Beta-blocker: % of target daily dose', 'numeric', '%', NULL::jsonb, 0, 300, 'calculated', 'calc.gdmt', 'daily dose / ref.hf_target_doses', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 53 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_pct_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_dose_status', 'Medication (GDMT)', 'Beta-blocker: optimisation status', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "below_target_uptitrating", "label": "below target uptitrating"}, {"code": "below_target_max_tolerated", "label": "below target max tolerated"}, {"code": "not_prescribed", "label": "not prescribed"}, {"code": "not_indicated", "label": "not indicated"}]'::jsonb, NULL, NULL, 'calculated', 'calc.gdmt + clinician confirmation', 'calc.gdmt + clinician confirmation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 54 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_dose_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bb_reasons', 'Medication (GDMT)', 'Beta-blocker: reasons not prescribed / not at target', 'multi_coded', NULL, '[{"code": "contraindication", "label": "contraindication"}, {"code": "intolerance", "label": "intolerance"}, {"code": "hypotension", "label": "hypotension"}, {"code": "hyperkalaemia", "label": "hyperkalaemia"}, {"code": "renal_dysfunction", "label": "renal dysfunction"}, {"code": "bradycardia", "label": "bradycardia"}, {"code": "worsening_hf", "label": "worsening hf"}, {"code": "patient_refusal", "label": "patient refusal"}, {"code": "financial", "label": "financial"}, {"code": "drug_unavailable", "label": "drug unavailable"}, {"code": "titration_in_progress", "label": "titration in progress"}, {"code": "recently_initiated", "label": "recently initiated"}, {"code": "not_indicated_for_phenotype", "label": "not indicated for phenotype"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 55 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'bb_reasons' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_eligible', 'Medication (GDMT)', 'MRA: eligible for this phenotype', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.hf_pillar_eligibility', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 56 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_eligible' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_prescribed', 'Medication (GDMT)', 'MRA: prescribed', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'registry.compute_gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 57 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_prescribed' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_drug', 'Medication (GDMT)', 'MRA: drug', 'text', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.drugs.drug_code', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 58 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_drug' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_daily_dose', 'Medication (GDMT)', 'MRA: total daily dose', 'numeric', 'mg/day', NULL::jsonb, 0, 2000, 'calculated', 'calc.gdmt', 'medication_events.daily_dose', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 59 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_pct_target', 'Medication (GDMT)', 'MRA: % of target daily dose', 'numeric', '%', NULL::jsonb, 0, 300, 'calculated', 'calc.gdmt', 'daily dose / ref.hf_target_doses', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 60 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_pct_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_dose_status', 'Medication (GDMT)', 'MRA: optimisation status', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "below_target_uptitrating", "label": "below target uptitrating"}, {"code": "below_target_max_tolerated", "label": "below target max tolerated"}, {"code": "not_prescribed", "label": "not prescribed"}, {"code": "not_indicated", "label": "not indicated"}]'::jsonb, NULL, NULL, 'calculated', 'calc.gdmt + clinician confirmation', 'calc.gdmt + clinician confirmation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 61 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_dose_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'mra_reasons', 'Medication (GDMT)', 'MRA: reasons not prescribed / not at target', 'multi_coded', NULL, '[{"code": "contraindication", "label": "contraindication"}, {"code": "intolerance", "label": "intolerance"}, {"code": "hypotension", "label": "hypotension"}, {"code": "hyperkalaemia", "label": "hyperkalaemia"}, {"code": "renal_dysfunction", "label": "renal dysfunction"}, {"code": "bradycardia", "label": "bradycardia"}, {"code": "worsening_hf", "label": "worsening hf"}, {"code": "patient_refusal", "label": "patient refusal"}, {"code": "financial", "label": "financial"}, {"code": "drug_unavailable", "label": "drug unavailable"}, {"code": "titration_in_progress", "label": "titration in progress"}, {"code": "recently_initiated", "label": "recently initiated"}, {"code": "not_indicated_for_phenotype", "label": "not indicated for phenotype"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 62 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'mra_reasons' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_eligible', 'Medication (GDMT)', 'SGLT2 inhibitor: eligible for this phenotype', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.hf_pillar_eligibility', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 63 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_eligible' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_prescribed', 'Medication (GDMT)', 'SGLT2 inhibitor: prescribed', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'registry.compute_gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 64 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_prescribed' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_drug', 'Medication (GDMT)', 'SGLT2 inhibitor: drug', 'text', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.gdmt', 'ref.drugs.drug_code', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 65 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_drug' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_daily_dose', 'Medication (GDMT)', 'SGLT2 inhibitor: total daily dose', 'numeric', 'mg/day', NULL::jsonb, 0, 2000, 'calculated', 'calc.gdmt', 'medication_events.daily_dose', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 66 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_pct_target', 'Medication (GDMT)', 'SGLT2 inhibitor: % of target daily dose', 'numeric', '%', NULL::jsonb, 0, 300, 'calculated', 'calc.gdmt', 'daily dose / ref.hf_target_doses', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 67 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_pct_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_dose_status', 'Medication (GDMT)', 'SGLT2 inhibitor: optimisation status', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "below_target_uptitrating", "label": "below target uptitrating"}, {"code": "below_target_max_tolerated", "label": "below target max tolerated"}, {"code": "not_prescribed", "label": "not prescribed"}, {"code": "not_indicated", "label": "not indicated"}]'::jsonb, NULL, NULL, 'calculated', 'calc.gdmt + clinician confirmation', 'calc.gdmt + clinician confirmation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 68 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_dose_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sglt2i_reasons', 'Medication (GDMT)', 'SGLT2 inhibitor: reasons not prescribed / not at target', 'multi_coded', NULL, '[{"code": "contraindication", "label": "contraindication"}, {"code": "intolerance", "label": "intolerance"}, {"code": "hypotension", "label": "hypotension"}, {"code": "hyperkalaemia", "label": "hyperkalaemia"}, {"code": "renal_dysfunction", "label": "renal dysfunction"}, {"code": "bradycardia", "label": "bradycardia"}, {"code": "worsening_hf", "label": "worsening hf"}, {"code": "patient_refusal", "label": "patient refusal"}, {"code": "financial", "label": "financial"}, {"code": "drug_unavailable", "label": "drug unavailable"}, {"code": "titration_in_progress", "label": "titration in progress"}, {"code": "recently_initiated", "label": "recently initiated"}, {"code": "not_indicated_for_phenotype", "label": "not indicated for phenotype"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 69 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'sglt2i_reasons' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'gdmt_pillars_prescribed', 'Medication (GDMT)', 'Number of eligible pillars prescribed', 'integer', 'count', NULL::jsonb, 0, 4, 'calculated', 'calc.gdmt', 'calc.gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 70 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_prescribed' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'gdmt_pillars_at_target', 'Medication (GDMT)', 'Number of pillars at target dose', 'integer', 'count', NULL::jsonb, 0, 4, 'calculated', 'calc.gdmt', 'calc.gdmt', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 71 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'gdmt_pillars_at_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'loop_diuretic_furosemide_eq', 'Medication (other)', 'Loop diuretic, furosemide-equivalent daily dose (0 = none)', 'numeric', 'mg/day', NULL::jsonb, 0, 1000, 'calculated', 'calc.loop_diuretic_equivalent', 'furosemide 40 = torsemide 20 = bumetanide 1', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 72 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'loop_diuretic_furosemide_eq' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_ivabradine', 'Medication (other)', 'Ivabradine', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'IVABRADINE', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 73 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_ivabradine' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_digoxin', 'Medication (other)', 'Digoxin', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'DIGOXIN', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 74 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'on_digoxin' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'devices', 'Devices', 'Active cardiac devices', 'multi_coded', NULL, '[{"code": "ICD", "label": "ICD"}, {"code": "CRT_P", "label": "CRT-P"}, {"code": "CRT_D", "label": "CRT-D"}, {"code": "PPM", "label": "PPM"}, {"code": "CSP", "label": "CSP"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.active_devices', 'cardiac_devices', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 75 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'devices' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 75 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'devices' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 75 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'devices' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 75 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'devices' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'vital_status', 'Outcomes', 'Vital status at visit', 'coded', NULL, '[{"code": "alive", "label": "Alive"}, {"code": "dead", "label": "Dead"}, {"code": "unknown", "label": "Unknown / lost"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 76 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'vital_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 76 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'vital_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 76 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'vital_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 76 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'vital_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 76 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'vital_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hf_hospitalisations_since_last', 'Outcomes', 'HF hospitalisations since previous visit', 'integer', 'count', NULL::jsonb, 0, 50, 'calculated', 'calc.event_count', 'clinical_events hf_hospitalisation', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 77 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_hospitalisations_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 77 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_hospitalisations_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 77 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_hospitalisations_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 77 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_hospitalisations_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 77 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hf_hospitalisations_since_last' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'urgent_hf_visits_since_last', 'Outcomes', 'Urgent HF visits since previous visit', 'integer', 'count', NULL::jsonb, 0, 50, 'calculated', 'calc.event_count', 'clinical_events urgent_hf_visit', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 78 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'urgent_hf_visits_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 78 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'urgent_hf_visits_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 78 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'urgent_hf_visits_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 78 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'urgent_hf_visits_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 78 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'urgent_hf_visits_since_last' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'worsening_hf_escalation', 'Outcomes', 'Worsening HF needing outpatient treatment escalation', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.event_exists', 'worsening_hf_outpatient', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 79 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'worsening_hf_escalation' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 79 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'worsening_hf_escalation' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 79 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'worsening_hf_escalation' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 79 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'worsening_hf_escalation' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 79 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'worsening_hf_escalation' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'renal_deterioration', 'Outcomes', 'Renal deterioration (creatinine rise >= 0.3 mg/dL or eGFR fall >= 25%)', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.renal_deterioration vs baseline', 'calc.renal_deterioration vs baseline', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'optional', 80 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'renal_deterioration' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 80 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'renal_deterioration' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 80 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'renal_deterioration' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 80 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'renal_deterioration' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 80 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'renal_deterioration' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hyperkalaemia', 'Outcomes', 'Hyperkalaemia (K > 5.5 mmol/L) since previous visit', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.lab_threshold', 'K > 5.5', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 81 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hyperkalaemia' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 81 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hyperkalaemia' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 81 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hyperkalaemia' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 81 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hyperkalaemia' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 81 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'hyperkalaemia' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'symptomatic_hypotension', 'Outcomes', 'Symptomatic hypotension since previous visit', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.event_exists', 'hypotension', 'active' FROM registry.registry_types WHERE registry_code = 'HF';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M1', 'mandatory', 82 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'symptomatic_hypotension' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M3', 'mandatory', 82 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'symptomatic_hypotension' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 82 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'symptomatic_hypotension' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 82 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'symptomatic_hypotension' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 82 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-HF' AND p.protocol_version = 1 AND t.registry_code = 'HF' AND d.variable_code = 'symptomatic_hypotension' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'age_at_index', 'Demographics', 'Age at index date', 'integer', 'years', NULL::jsonb, 18, 110, 'calculated', 'calc.age_at_index', 'calc.age_at_index', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 0 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'age_at_index' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'sex', 'Demographics', 'Sex', 'coded', NULL, '[{"code": "male", "label": "Male"}, {"code": "female", "label": "Female"}, {"code": "other", "label": "Other"}, {"code": "unknown", "label": "Unknown"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.registration_sex', 'emr.registration_sex', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 1 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'sex' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'bmi', 'Demographics', 'Body-mass index', 'numeric', 'kg/m2', NULL::jsonb, 10, 70, 'calculated', 'calc.bmi', 'calc.bmi', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 2 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'bmi' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'prevention_type', 'Category', 'Primary or secondary prevention', 'coded', NULL, '[{"code": "primary", "label": "Primary"}, {"code": "secondary", "label": "Secondary"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 3 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'prevention_type' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lipid_categories', 'Category', 'Patient categories (all that apply)', 'multi_coded', NULL, '[{"code": "primary_prevention", "label": "primary prevention"}, {"code": "secondary_prevention", "label": "secondary prevention"}, {"code": "established_cad", "label": "established cad"}, {"code": "post_mi", "label": "post mi"}, {"code": "post_pci", "label": "post pci"}, {"code": "post_cabg", "label": "post cabg"}, {"code": "diabetes", "label": "diabetes"}, {"code": "familial_hypercholesterolaemia", "label": "familial hypercholesterolaemia"}, {"code": "elevated_lpa", "label": "elevated lpa"}, {"code": "statin_intolerance", "label": "statin intolerance"}, {"code": "ckd", "label": "ckd"}, {"code": "stroke_tia", "label": "stroke tia"}, {"code": "pad", "label": "pad"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_categories' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_categories' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 4 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_categories' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_cad', 'Clinical', 'Coronary artery disease', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_CAD', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 5 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'has_cad' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'prior_mi', 'Clinical', 'Previous myocardial infarction', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.event_before_index', 'mi', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 6 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'prior_mi' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'prior_stroke_tia', 'Clinical', 'Previous ischaemic stroke / TIA', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_STROKE', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 7 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'prior_stroke_tia' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_pad', 'Clinical', 'Peripheral arterial disease', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_PAD', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 8 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'has_pad' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_diabetes', 'Clinical', 'Diabetes mellitus', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_DM', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 9 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'has_diabetes' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_ckd', 'Clinical', 'Chronic kidney disease', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_CKD', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 10 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'has_ckd' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'has_hypertension', 'Clinical', 'Hypertension', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_diagnosis', 'DX_HTN', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 11 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'has_hypertension' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'smoking_status', 'Clinical', 'Smoking status', 'coded', NULL, '[{"code": "never", "label": "never"}, {"code": "former", "label": "former"}, {"code": "current", "label": "current"}, {"code": "unknown", "label": "unknown"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.lifestyle_latest', 'emr.lifestyle_latest', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'smoking_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'smoking_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 12 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'smoking_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'fh_basis', 'Clinical', 'FH diagnosis basis', 'coded', NULL, '[{"code": "dlcn", "label": "Dutch Lipid Clinic Network"}, {"code": "simon_broome", "label": "Simon Broome"}, {"code": "genetic", "label": "Genetic"}, {"code": "clinical", "label": "Clinical"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 13 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'fh_basis' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'dlcn_score', 'Clinical', 'DLCN score', 'integer', 'points', NULL::jsonb, 0, 30, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 14 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'dlcn_score' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_guideline', 'Risk and target', 'Guideline rule set used for target', 'text', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.protocol_rule_set', 'registry_protocols.ldl_target_rule_set_id', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_guideline' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_guideline' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_guideline' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_guideline' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 15 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_guideline' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'risk_category', 'Risk and target', 'Cardiovascular risk category', 'coded', NULL, '[{"code": "very_high", "label": "very high"}, {"code": "high", "label": "high"}, {"code": "moderate", "label": "moderate"}, {"code": "low", "label": "low"}, {"code": "extreme", "label": "extreme"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 16 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'risk_category' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 16 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'risk_category' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 16 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'risk_category' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_target', 'Risk and target', 'LDL-C target applied', 'numeric', 'mg/dL', NULL::jsonb, 10, 200, 'calculated', 'calc.ldl_target', 'ref.ldl_target_rules', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 17 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'baseline_ldl_kind', 'Lipids', 'Which value is the baseline LDL-C', 'coded', NULL, '[{"code": "untreated", "label": "Untreated (no lipid-lowering therapy)"}, {"code": "on_treatment_at_enrolment", "label": "On treatment at enrolment"}, {"code": "imputed_untreated", "label": "Imputed untreated value"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 18 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'baseline_ldl_kind' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lipid_test_status', 'Lipids', 'Lipid profile done in this visit window', 'coded', NULL, '[{"code": "tested_in_window", "label": "tested in window"}, {"code": "tested_outside_window", "label": "tested outside window"}, {"code": "not_tested", "label": "not tested"}]'::jsonb, NULL, NULL, 'calculated', 'calc.lab_in_window', 'LDL_C', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 19 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lipid_test_date', 'Lipids', 'Lipid sample date', 'date', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.lab_in_window', 'lab_results.collected_at', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_date' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 20 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lipid_test_date' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_c', 'Lipids', 'LDL cholesterol', 'numeric', 'mg/dL', NULL::jsonb, 5, 1000, 'emr_derived', 'emr.lab_in_window', 'LDL_C', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 21 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_c' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_method', 'Lipids', 'LDL-C method', 'coded', NULL, '[{"code": "direct", "label": "direct"}, {"code": "friedewald", "label": "friedewald"}, {"code": "martin_hopkins", "label": "martin-hopkins"}, {"code": "sampson", "label": "sampson"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.lab_in_window', 'lab_results.method', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_method' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 22 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_method' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'total_cholesterol', 'Lipids', 'Total cholesterol', 'numeric', 'mg/dL', NULL::jsonb, 40, 1500, 'emr_derived', 'emr.lab_in_window', 'TC', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'total_cholesterol' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'total_cholesterol' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'total_cholesterol' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'total_cholesterol' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 23 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'total_cholesterol' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'hdl_c', 'Lipids', 'HDL cholesterol', 'numeric', 'mg/dL', NULL::jsonb, 5, 200, 'emr_derived', 'emr.lab_in_window', 'HDL_C', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 24 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'hdl_c' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'triglycerides', 'Lipids', 'Triglycerides', 'numeric', 'mg/dL', NULL::jsonb, 10, 10000, 'emr_derived', 'emr.lab_in_window', 'TG', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'triglycerides' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'triglycerides' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'triglycerides' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'triglycerides' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 25 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'triglycerides' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'non_hdl_c', 'Lipids', 'Non-HDL cholesterol', 'numeric', 'mg/dL', NULL::jsonb, 10, 1500, 'calculated', 'calc.non_hdl', 'TC - HDL-C', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_hdl_c' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 26 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_hdl_c' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'apob', 'Advanced lipids', 'Apolipoprotein B', 'numeric', 'mg/dL', NULL::jsonb, 10, 400, 'emr_derived', 'emr.lab_in_window', 'APOB', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 27 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'apob' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 27 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'apob' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 27 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'apob' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lpa_value', 'Advanced lipids', 'Lipoprotein(a), as reported', 'numeric', NULL, NULL::jsonb, 0, 1000, 'emr_derived', 'emr.lab_ever', 'LPA_NMOL_L or LPA_MG_DL', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 28 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lpa_value' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lpa_unit', 'Advanced lipids', 'Lp(a) unit', 'coded', NULL, '[{"code": "nmol/L", "label": "nmol/L"}, {"code": "mg/dL", "label": "mg/dL"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.lab_ever', 'analyte used', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 29 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lpa_unit' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'lpa_elevated', 'Advanced lipids', 'Lp(a) elevated (>= 125 nmol/L or >= 50 mg/dL)', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.lpa_elevated', 'calc.lpa_elevated', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 30 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'lpa_elevated' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'statin_drug', 'Treatment', 'Statin', 'text', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'STATIN', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_drug' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 31 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_drug' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'statin_daily_dose', 'Treatment', 'Statin daily dose', 'numeric', 'mg/day', NULL::jsonb, 0, 80, 'emr_derived', 'emr.active_drug_class', 'daily_dose', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 32 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_daily_dose' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'statin_intensity', 'Treatment intensity', 'Statin intensity', 'coded', NULL, '[{"code": "none", "label": "none"}, {"code": "low", "label": "low"}, {"code": "moderate", "label": "moderate"}, {"code": "high", "label": "high"}]'::jsonb, NULL, NULL, 'calculated', 'calc.statin_intensity', 'ref.statin_intensity_rules', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_intensity' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_intensity' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_intensity' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_intensity' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 33 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'statin_intensity' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_ezetimibe', 'Treatment', 'Ezetimibe', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'EZETIMIBE', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_ezetimibe' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_ezetimibe' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_ezetimibe' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_ezetimibe' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 34 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_ezetimibe' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_pcsk9_mab', 'Treatment', 'PCSK9 monoclonal antibody', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'PCSK9_MAB', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_pcsk9_mab' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_pcsk9_mab' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_pcsk9_mab' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_pcsk9_mab' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 35 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_pcsk9_mab' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_inclisiran', 'Treatment', 'Inclisiran', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'PCSK9_SIRNA', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_inclisiran' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_inclisiran' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_inclisiran' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_inclisiran' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 36 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_inclisiran' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'on_bempedoic_acid', 'Treatment', 'Bempedoic acid', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'emr_derived', 'emr.active_drug_class', 'BEMPEDOIC_ACID', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_bempedoic_acid' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_bempedoic_acid' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_bempedoic_acid' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_bempedoic_acid' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 37 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'on_bempedoic_acid' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'therapy_change', 'Treatment', 'Change to lipid therapy at this visit', 'coded', NULL, '[{"code": "none", "label": "none"}, {"code": "statin_initiated", "label": "statin initiated"}, {"code": "statin_intensified", "label": "statin intensified"}, {"code": "non_statin_added", "label": "non statin added"}, {"code": "reduced", "label": "reduced"}, {"code": "stopped", "label": "stopped"}]'::jsonb, NULL, NULL, 'calculated', 'calc.llt_change vs previous visit', 'calc.llt_change vs previous visit', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'therapy_change' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'therapy_change' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'therapy_change' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 38 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'therapy_change' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'non_intensification_reason', 'Treatment', 'Reason therapy not intensified when not at target', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "intolerance", "label": "intolerance"}, {"code": "cost", "label": "cost"}, {"code": "patient_refusal", "label": "patient refusal"}, {"code": "clinician_judgement", "label": "clinician judgement"}, {"code": "awaiting_repeat_test", "label": "awaiting repeat test"}, {"code": "other", "label": "other"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_intensification_reason' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_intensification_reason' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_intensification_reason' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 39 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'non_intensification_reason' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ck', 'Safety', 'Creatine kinase', 'numeric', 'U/L', NULL::jsonb, 5, 100000, 'emr_derived', 'emr.lab_in_window', 'CK', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ck' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'optional', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ck' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ck' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ck' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 40 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ck' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'alt', 'Safety', 'ALT', 'numeric', 'U/L', NULL::jsonb, 1, 5000, 'emr_derived', 'emr.lab_in_window', 'ALT', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'alt' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'alt' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'alt' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'alt' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'optional', 41 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'alt' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'muscle_symptoms', 'Safety', 'Statin-associated muscle symptoms', 'coded', NULL, '[{"code": "none", "label": "none"}, {"code": "myalgia", "label": "myalgia"}, {"code": "myositis", "label": "myositis"}, {"code": "rhabdomyolysis", "label": "rhabdomyolysis"}]'::jsonb, NULL, NULL, 'entered', NULL, NULL, 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'muscle_symptoms' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'muscle_symptoms' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'muscle_symptoms' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 42 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'muscle_symptoms' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'adherence', 'Adherence', 'Adherence to lipid-lowering therapy', 'coded', NULL, '[{"code": "good", "label": "good"}, {"code": "partial", "label": "partial"}, {"code": "poor", "label": "poor"}, {"code": "unknown", "label": "unknown"}]'::jsonb, NULL, NULL, 'emr_derived', 'emr.adherence_latest', 'emr.adherence_latest', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'adherence' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'adherence' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'adherence' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 43 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'adherence' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_abs_reduction', 'Outcomes', 'Absolute LDL-C reduction from baseline', 'numeric', 'mg/dL', NULL::jsonb, -500, 1000, 'calculated', 'calc.ldl_abs_reduction', 'baseline - current', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_abs_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_abs_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_abs_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 44 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_abs_reduction' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_pct_reduction', 'Outcomes', '% LDL-C reduction from baseline', 'numeric', '%', NULL::jsonb, -500, 100, 'calculated', 'calc.ldl_pct_reduction', '(baseline - current) / baseline x 100', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_pct_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_pct_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_pct_reduction' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 45 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_pct_reduction' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'reduction_50pct_met', 'Outcomes', '>= 50% LDL-C reduction achieved', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.ldl_pct_reduction >= 50', 'calc.ldl_pct_reduction >= 50', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'reduction_50pct_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'reduction_50pct_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'reduction_50pct_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 46 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'reduction_50pct_met' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'ldl_target_met', 'Outcomes', 'LDL-C target attained', 'boolean', NULL, NULL::jsonb, NULL, NULL, 'calculated', 'calc.ldl_target_met', 'ref.ldl_target_rules', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'BL', 'conditional', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'conditional', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'conditional', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'conditional', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'conditional', 47 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'ldl_target_met' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'target_status', 'Outcomes', 'Target status (separates no repeat test from not at target)', 'coded', NULL, '[{"code": "at_target", "label": "at target"}, {"code": "not_at_target_on_max_tolerated", "label": "not at target on max tolerated"}, {"code": "not_at_target_escalation_pending", "label": "not at target escalation pending"}, {"code": "not_at_target_adherence_issue", "label": "not at target adherence issue"}, {"code": "no_repeat_test", "label": "no repeat test"}]'::jsonb, NULL, NULL, 'calculated', 'calc.lipid_target_status', 'calc.lipid_target_status', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'target_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'target_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'target_status' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 48 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'target_status' AND d.definition_version = 1;
INSERT INTO registry.variable_definitions (registry_type_id, variable_code, category, variable_label, data_type, unit, allowed_values, min_value, max_value, source_kind, derivation_key, emr_source, status) SELECT registry_type_id, 'cv_events_since_last', 'Outcomes', 'Cardiovascular events since previous visit', 'integer', 'count', NULL::jsonb, 0, 50, 'calculated', 'calc.event_count', 'mi, stroke, pci, cabg, death (cv)', 'active' FROM registry.registry_types WHERE registry_code = 'LIPID';
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'W6_12', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'cv_events_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M6', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'cv_events_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'M12', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'cv_events_since_last' AND d.definition_version = 1;
INSERT INTO registry.protocol_variables (protocol_id, variable_id, visit_code, requirement, sort_order) SELECT p.protocol_id, d.variable_id, 'ANNUAL', 'mandatory', 49 FROM registry.registry_protocols p, registry.variable_definitions d JOIN registry.registry_types t USING (registry_type_id) WHERE p.protocol_code = 'CEMR-LIPID' AND p.protocol_version = 1 AND t.registry_code = 'LIPID' AND d.variable_code = 'cv_events_since_last' AND d.definition_version = 1;
