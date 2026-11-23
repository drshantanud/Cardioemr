-- =====================================================================
-- CardioEMR  migration 0006_events_reports_exports_units   (2026-11-23)
-- Builds on the tables 0001 already has for these areas:
--   1. Unit conversion on entry: a registry value may be entered in another
--      unit; the database converts it and keeps what was typed.
--   2. Clinical events: integrity rules, adjudications opened automatically
--      for every protocol whose endpoints use the event type, withdrawn when
--      the event is entered in error, reopened when its facts change.
--   3. Adjudication: human decisions only, by a clinician or PI who did not
--      report the event, classification checked against the endpoint's
--      classification system; re-adjudication needs a change reason.
--   4. Endpoints: CAD and lipid MACE components (draft, for clinical review),
--      endpoint and time-to-first-event views.
--   5. Reports: follow-up facts (nurses included) and missing mandatory data.
--   6. Research exports: state machine, four-eyes approval, a pseudonymised
--      view of every registry value.
-- Every clinical definition seeded here is status 'draft' and listed in the
-- PR for the clinical lead's review.
-- =====================================================================
SET check_function_bodies = off;

-- ---------------------------------------------------------------------
-- 1. UNIT CONVERSION ON ENTRY
-- ---------------------------------------------------------------------
-- Physical quantities that are not lab analytes (weight, lengths, pressure).
-- A unit belongs to one quantity; value_in_base = value * factor_to_base.
CREATE TABLE ref.quantity_units (
  unit           text PRIMARY KEY,
  quantity       text NOT NULL CHECK (quantity IN ('mass','length','pressure')),
  factor_to_base numeric NOT NULL CHECK (factor_to_base > 0)
);
INSERT INTO ref.quantity_units (unit, quantity, factor_to_base) VALUES
 ('kg','mass',1), ('g','mass',0.001), ('lb','mass',0.45359237),
 ('m','length',1), ('cm','length',0.01), ('mm','length',0.001), ('in','length',0.0254), ('ft','length',0.3048),
 ('mmHg','pressure',1), ('kPa','pressure',7.50062), ('cmH2O','pressure',0.735559);

-- Lab-type registry variables point at their analyte, so they use the same
-- conversion factors as clinical.lab_results.  eGFR is deliberately not
-- mapped: ref.unit_conversions has EGFR mL/min = 1, which is right for a lab
-- printout but would let a Cockcroft-Gault clearance pass as eGFR on entry.
ALTER TABLE registry.variable_definitions ADD COLUMN analyte_code text REFERENCES ref.analytes;
UPDATE registry.variable_definitions d SET analyte_code = m.analyte
  FROM (VALUES ('ldl_c','LDL_C'), ('ldl_target','LDL_C'), ('ldl_target_lai','LDL_C'), ('ldl_abs_reduction','LDL_C'),
               ('total_cholesterol','TC'), ('hdl_c','HDL_C'), ('triglycerides','TG'), ('non_hdl_c','NON_HDL_C'),
               ('apob','APOB'), ('ck','CK'), ('alt','ALT'), ('nt_probnp','NT_PROBNP'), ('haemoglobin','HB'),
               ('creatinine','CREATININE'), ('sodium','NA'), ('potassium','K'), ('peak_troponin','HS_TNI'),
               ('hba1c','HBA1C')) m(code, analyte)
 WHERE d.variable_code = m.code AND d.unit IS NOT NULL
   AND d.unit = (SELECT canonical_unit FROM ref.analytes a WHERE a.analyte_code = m.analyte);

CREATE OR REPLACE FUNCTION ref.norm_unit(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT lower(replace(replace(btrim(p), 'µ', 'u'), 'μ', 'u')) $$;

-- Converts p_value from p_from to p_to for an analyte (lab factors) or a
-- physical quantity.  NULL when the two units cannot be converted.
CREATE OR REPLACE FUNCTION ref.convert_unit(p_analyte text, p_value numeric, p_from text, p_to text) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_canonical text; f_from numeric; f_to numeric; q_from record; q_to record;
BEGIN
  IF p_value IS NULL OR p_from IS NULL OR p_to IS NULL THEN RETURN NULL; END IF;
  IF ref.norm_unit(p_from) = ref.norm_unit(p_to) THEN RETURN p_value; END IF;
  IF p_analyte IS NOT NULL THEN
    SELECT canonical_unit INTO v_canonical FROM ref.analytes WHERE analyte_code = p_analyte;
    f_from := CASE WHEN ref.norm_unit(p_from) = ref.norm_unit(v_canonical) THEN 1 ELSE
              (SELECT factor_to_canonical FROM ref.unit_conversions
                WHERE analyte_code = p_analyte AND ref.norm_unit(from_unit) = ref.norm_unit(p_from)) END;
    f_to := CASE WHEN ref.norm_unit(p_to) = ref.norm_unit(v_canonical) THEN 1 ELSE
            (SELECT factor_to_canonical FROM ref.unit_conversions
              WHERE analyte_code = p_analyte AND ref.norm_unit(from_unit) = ref.norm_unit(p_to)) END;
    IF f_from IS NOT NULL AND f_to IS NOT NULL THEN RETURN p_value * f_from / f_to; END IF;
    RETURN NULL;
  END IF;
  SELECT * INTO q_from FROM ref.quantity_units WHERE ref.norm_unit(unit) = ref.norm_unit(p_from);
  SELECT * INTO q_to FROM ref.quantity_units WHERE ref.norm_unit(unit) = ref.norm_unit(p_to);
  IF q_from.unit IS NOT NULL AND q_to.unit IS NOT NULL AND q_from.quantity = q_to.quantity THEN
    RETURN p_value * q_from.factor_to_base / q_to.factor_to_base;
  END IF;
  RETURN NULL;
END $$;

-- Units a registry variable accepts on entry (its own unit first).
CREATE OR REPLACE FUNCTION registry.accepted_units(p_variable uuid) RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN d.unit IS NULL OR d.data_type NOT IN ('numeric','integer') THEN NULL
    WHEN d.analyte_code IS NOT NULL THEN
      ARRAY[d.unit] || ARRAY(SELECT u FROM (
          SELECT a.canonical_unit AS u FROM ref.analytes a WHERE a.analyte_code = d.analyte_code
          UNION SELECT from_unit FROM ref.unit_conversions c WHERE c.analyte_code = d.analyte_code) x
        WHERE ref.norm_unit(u) <> ref.norm_unit(d.unit) ORDER BY u)
    ELSE ARRAY[d.unit] || ARRAY(SELECT q.unit FROM ref.quantity_units q
        WHERE q.quantity = (SELECT quantity FROM ref.quantity_units WHERE unit = d.unit) AND q.unit <> d.unit
        ORDER BY q.factor_to_base DESC) END
  FROM registry.variable_definitions d WHERE d.variable_id = p_variable
$$;

GRANT SELECT ON ref.quantity_units TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;

-- What the user typed, kept beside the converted value.
ALTER TABLE registry.variable_values ADD COLUMN entered_value numeric, ADD COLUMN entered_unit text,
  ADD CONSTRAINT variable_values_entered_unit_pair CHECK ((entered_value IS NULL) = (entered_unit IS NULL));

-- Named to fire before variable_values_validate, so range checks see the
-- converted value.  Integers round to whole numbers, other numbers to 2 dp.
CREATE OR REPLACE FUNCTION registry.variable_value_convert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d record; v numeric;
BEGIN
  IF NEW.entered_unit IS NULL THEN RETURN NEW; END IF;
  SELECT variable_code, data_type, unit, analyte_code INTO d
    FROM registry.variable_definitions WHERE variable_id = NEW.variable_id;
  IF NEW.value_status <> 'present' OR d.data_type NOT IN ('numeric','integer') OR d.unit IS NULL THEN
    RAISE EXCEPTION 'variable % takes no unit', d.variable_code
      USING ERRCODE = 'check_violation', HINT = 'cemr:UNIT_NOT_CONVERTIBLE';
  END IF;
  v := ref.convert_unit(d.analyte_code, NEW.entered_value, NEW.entered_unit, d.unit);
  IF v IS NULL THEN
    RAISE EXCEPTION 'variable % is recorded in %; % cannot be converted', d.variable_code, d.unit, NEW.entered_unit
      USING ERRCODE = 'check_violation', HINT = 'cemr:UNIT_NOT_CONVERTIBLE';
  END IF;
  IF ref.norm_unit(NEW.entered_unit) = ref.norm_unit(d.unit) THEN
    NEW.entered_value := NULL; NEW.entered_unit := NULL;   -- nothing was converted
  END IF;
  NEW.numeric_value := round(v, CASE WHEN d.data_type = 'integer' THEN 0 ELSE 2 END);
  RETURN NEW;
END $$;
CREATE TRIGGER variable_values_a_convert BEFORE INSERT OR UPDATE ON registry.variable_values
  FOR EACH ROW EXECUTE FUNCTION registry.variable_value_convert();

-- ---------------------------------------------------------------------
-- 2. CLINICAL EVENTS: integrity
-- ---------------------------------------------------------------------
ALTER TABLE registry.event_adjudications DROP CONSTRAINT event_adjudications_adjudication_status_check;
ALTER TABLE registry.event_adjudications ADD CONSTRAINT event_adjudications_adjudication_status_check
  CHECK (adjudication_status IN ('pending','in_review','adjudicated','not_an_event','insufficient_data',
                                 'event_withdrawn'));
ALTER TABLE registry.event_adjudications RENAME CONSTRAINT event_adjudications_check
  TO event_adjudications_decision_requires_adjudicator;

ALTER TABLE clinical.clinical_events RENAME CONSTRAINT clinical_events_check TO clinical_events_death_requires_cause;
ALTER TABLE clinical.clinical_events RENAME CONSTRAINT clinical_events_check1 TO clinical_events_cv_mode_requires_cv_death;
ALTER TABLE clinical.clinical_events RENAME CONSTRAINT clinical_events_check2 TO clinical_events_mi_type_requires_mi;
ALTER TABLE clinical.clinical_events RENAME CONSTRAINT clinical_events_check3 TO clinical_events_discharge_after_admission;
ALTER TABLE clinical.clinical_events RENAME CONSTRAINT clinical_events_check4 TO clinical_events_admission_requires_hospitalised;

CREATE OR REPLACE FUNCTION clinical.clinical_event_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.event_type <> OLD.event_type THEN
      RAISE EXCEPTION 'event type cannot change; mark this event entered in error and report the correct one'
        USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_TYPE_FIXED';
    END IF;
    IF OLD.status = 'entered_in_error' AND app.current_app_role() IS NOT NULL THEN
      RAISE EXCEPTION 'event was entered in error and cannot change' USING ERRCODE = 'check_violation',
        HINT = 'cemr:EVENT_WITHDRAWN';
    END IF;
    IF app.current_app_role() IS NOT NULL AND app.change_reason() IS NULL THEN
      RAISE EXCEPTION 'changing a reported event needs a change reason' USING ERRCODE = 'check_violation',
        HINT = 'cemr:CHANGE_REASON_REQUIRED';
    END IF;
  END IF;
  IF NEW.event_date > current_date THEN
    RAISE EXCEPTION 'event date is in the future' USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_INVALID';
  END IF;
  IF (NEW.death_cause IS NOT NULL AND NEW.event_type <> 'death')
     OR (NEW.stroke_type IS NOT NULL AND NEW.event_type <> 'stroke')
     OR (NEW.bleeding_site IS NOT NULL AND NEW.event_type <> 'bleeding')
     OR (NEW.potassium_mmol_l IS NOT NULL AND NEW.event_type <> 'hyperkalaemia')
     OR (NEW.creatinine_result_id IS NOT NULL AND NEW.event_type <> 'renal_deterioration')
     OR (NEW.pci_procedure_id IS NOT NULL AND NEW.event_type NOT IN ('pci','stent_thrombosis','mi','bleeding'))
     OR (NEW.target_lesion_id IS NOT NULL AND NEW.event_type NOT IN ('pci','cabg','stent_thrombosis','mi')) THEN
    RAISE EXCEPTION 'a detail field does not apply to a % event', NEW.event_type
      USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_INVALID';
  END IF;
  IF NEW.admission_date IS NOT NULL AND NEW.admission_date > NEW.event_date + 1 THEN
    RAISE EXCEPTION 'admission is after the event date' USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_INVALID';
  END IF;
  -- Linked records must be this patient's, at this centre.  Foreign keys alone
  -- do not check that (they bypass row-level security).
  IF NEW.pci_procedure_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clinical.pci_procedures p
       WHERE p.procedure_id = NEW.pci_procedure_id AND p.patient_id = NEW.patient_id AND p.centre_id = NEW.centre_id)
  OR NEW.target_lesion_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clinical.pci_lesions l
       WHERE l.lesion_id = NEW.target_lesion_id AND l.patient_id = NEW.patient_id AND l.centre_id = NEW.centre_id)
  OR NEW.creatinine_result_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clinical.lab_results r
       WHERE r.result_id = NEW.creatinine_result_id AND r.patient_id = NEW.patient_id AND r.centre_id = NEW.centre_id)
  OR NEW.source_document_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clinical.documents d
       WHERE d.document_id = NEW.source_document_id AND d.patient_id = NEW.patient_id AND d.centre_id = NEW.centre_id)
  THEN
    RAISE EXCEPTION 'a linked record does not belong to this patient at this centre'
      USING ERRCODE = 'foreign_key_violation', HINT = 'cemr:EVENT_LINK_INVALID';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER clinical_events_a_guard BEFORE INSERT OR UPDATE ON clinical.clinical_events
  FOR EACH ROW EXECUTE FUNCTION clinical.clinical_event_guard();

-- ---------------------------------------------------------------------
-- 3. ADJUDICATION: opened, withdrawn and reopened by the database
-- ---------------------------------------------------------------------
-- An event opens one pending adjudication per (protocol, endpoint) when the
-- patient is enrolled in that protocol at the event's centre, the event is
-- on or after the index date and inside follow-up (before the date a closed
-- enrolment ended), and a non-retired component endpoint that needs
-- adjudication lists the event type.  Historical events never open one.
CREATE OR REPLACE FUNCTION registry._open_adjudications(p_event uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry, clinical AS $$
DECLARE n integer;
BEGIN
  INSERT INTO registry.event_adjudications (event_id, protocol_id, endpoint_id, patient_id, centre_id)
  SELECT ev.event_id, e.protocol_id, ed.endpoint_id, ev.patient_id, ev.centre_id
    FROM clinical.clinical_events ev
    JOIN registry.enrolments e ON e.patient_id = ev.patient_id AND e.centre_id = ev.centre_id
    JOIN registry.endpoint_definitions ed ON ed.protocol_id = e.protocol_id
   WHERE ev.event_id = p_event AND ev.status <> 'entered_in_error' AND NOT ev.is_historical
     AND e.enrolment_status NOT IN ('screening','screen_failed') AND e.index_date IS NOT NULL
     AND ev.event_date >= e.index_date
     AND (e.enrolment_status = 'enrolled' OR ev.event_date <= e.status_changed_on)
     AND ed.endpoint_kind = 'component' AND ed.requires_adjudication AND ed.status <> 'retired'
     AND ev.event_type = ANY (ed.event_types)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION registry._open_adjudications(uuid) FROM PUBLIC, r_assistant, r_nurse, r_clinician,
  r_research_coordinator, r_principal_investigator, r_centre_admin, r_platform_admin;

CREATE OR REPLACE FUNCTION clinical.clinical_event_after() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry, clinical AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM registry._open_adjudications(NEW.event_id);
  ELSIF NEW.status = 'entered_in_error' AND OLD.status <> 'entered_in_error' THEN
    UPDATE registry.event_adjudications SET adjudication_status = 'event_withdrawn',
           notes = concat_ws(E'\n', notes, 'Event entered in error: ' || coalesce(app.change_reason(), ''))
     WHERE event_id = NEW.event_id AND adjudication_status <> 'event_withdrawn';
  ELSIF (NEW.event_date, NEW.event_date_precision, NEW.is_historical, NEW.hospitalised, NEW.admission_date,
         NEW.discharge_date, NEW.severity, NEW.outcome, NEW.death_cause, NEW.death_cv_mode, NEW.mi_type,
         NEW.stroke_type, NEW.bleeding_site, NEW.pci_procedure_id, NEW.target_lesion_id)
        IS DISTINCT FROM
        (OLD.event_date, OLD.event_date_precision, OLD.is_historical, OLD.hospitalised, OLD.admission_date,
         OLD.discharge_date, OLD.severity, OLD.outcome, OLD.death_cause, OLD.death_cv_mode, OLD.mi_type,
         OLD.stroke_type, OLD.bleeding_site, OLD.pci_procedure_id, OLD.target_lesion_id) THEN
    -- Facts an adjudicator relied on changed: decisions go back to the queue.
    UPDATE registry.event_adjudications SET adjudication_status = 'pending', meets_endpoint = NULL,
           notes = concat_ws(E'\n', notes, 'Reopened: event details changed (' || coalesce(app.change_reason(), '') || ')')
     WHERE event_id = NEW.event_id AND adjudication_status IN ('in_review','adjudicated','not_an_event','insufficient_data');
    PERFORM registry._open_adjudications(NEW.event_id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER clinical_events_z_adjudication AFTER INSERT OR UPDATE ON clinical.clinical_events
  FOR EACH ROW EXECUTE FUNCTION clinical.clinical_event_after();

-- An enrolment that starts (or a late index date) picks up events already on file.
CREATE OR REPLACE FUNCTION registry.enrolment_open_adjudications() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, registry, clinical AS $$
DECLARE ev record;
BEGIN
  IF NEW.enrolment_status = 'enrolled' THEN
    FOR ev IN SELECT event_id FROM clinical.clinical_events
               WHERE patient_id = NEW.patient_id AND centre_id = NEW.centre_id AND event_date >= NEW.index_date LOOP
      PERFORM registry._open_adjudications(ev.event_id);
    END LOOP;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER enrolments_z_open_adjudications AFTER INSERT OR UPDATE OF enrolment_status, index_date
  ON registry.enrolments FOR EACH ROW EXECUTE FUNCTION registry.enrolment_open_adjudications();

-- Classification codes per classification system.  Draft content for the
-- clinical lead: BARC, ARC-2 stent thrombosis, UDMI-4 MI types, HF-ARC
-- death and HF-event codes, and the custom death and stroke codes.
CREATE TABLE ref.adjudication_classifications (
  classification_system text NOT NULL CHECK (classification_system IN ('ARC-2','BARC','UDMI-4','HF-ARC',
                          'VARC-3','MVARC','custom')),
  code   text NOT NULL,
  label  text NOT NULL,
  PRIMARY KEY (classification_system, code)
);
INSERT INTO ref.adjudication_classifications VALUES
 ('BARC','0','BARC 0: no bleeding'), ('BARC','1','BARC 1: not actionable'), ('BARC','2','BARC 2: overt, actionable'),
 ('BARC','3a','BARC 3a: Hb drop 3-5 g/dL or transfusion'), ('BARC','3b','BARC 3b: Hb drop >= 5 g/dL, tamponade, surgery or IV vasoactives'),
 ('BARC','3c','BARC 3c: intracranial or intraocular'), ('BARC','4','BARC 4: CABG-related'),
 ('BARC','5a','BARC 5a: probable fatal'), ('BARC','5b','BARC 5b: definite fatal'),
 ('ARC-2','definite','ARC-2 definite stent thrombosis'), ('ARC-2','probable','ARC-2 probable stent thrombosis'),
 ('ARC-2','possible','ARC-2 possible stent thrombosis'),
 ('ARC-2','clinically_driven_tlr','Clinically driven target lesion revascularisation'),
 ('ARC-2','not_clinically_driven','Revascularisation not clinically driven'),
 ('ARC-2','not_target_lesion','Revascularisation of a non-target lesion'),
 ('UDMI-4','1','Type 1 MI'), ('UDMI-4','2','Type 2 MI'), ('UDMI-4','3','Type 3 MI'), ('UDMI-4','4a','Type 4a MI'),
 ('UDMI-4','4b','Type 4b MI'), ('UDMI-4','4c','Type 4c MI'), ('UDMI-4','5','Type 5 MI'),
 ('UDMI-4','myocardial_injury','Myocardial injury, not MI'),
 ('HF-ARC','cardiovascular','Cardiovascular death'), ('HF-ARC','non_cardiovascular','Non-cardiovascular death'),
 ('HF-ARC','undetermined','Undetermined cause of death'),
 ('HF-ARC','hf_event','Meets the HF event definition'), ('HF-ARC','not_hf_event','Does not meet the HF event definition'),
 ('custom','cardiovascular','Cardiovascular death'), ('custom','non_cardiovascular','Non-cardiovascular death'),
 ('custom','undetermined','Undetermined'), ('custom','ischaemic','Ischaemic stroke'),
 ('custom','haemorrhagic','Haemorrhagic stroke');

GRANT SELECT ON ref.adjudication_classifications TO r_assistant, r_nurse, r_clinician, r_research_coordinator,
  r_principal_investigator, r_centre_admin, r_platform_admin;

-- Human decisions only.  Rules (roles outside r_* are the owner and triggers):
--   * pending and event_withdrawn are set by the database, never by a user;
--   * a decision needs a clinician or PI acting role; adjudicated_by is the caller;
--   * the adjudicator did not report the event (independent review);
--   * the classification exists in the endpoint's classification system;
--   * when the endpoint lists qualifying classifications, meets_endpoint
--     follows the classification and a contradicting value is refused;
--   * changing an adjudicated or not-an-event decision needs a change reason;
--   * a withdrawn adjudication is closed.
-- Runs as the caller (its role is what is checked); the reporter of an event
-- at another centre is read through this narrow definer helper.
CREATE OR REPLACE FUNCTION registry._event_reporter(p_event uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, clinical AS $$
  SELECT reported_by FROM clinical.clinical_events WHERE event_id = p_event
$$;
REVOKE EXECUTE ON FUNCTION registry._event_reporter(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registry._event_reporter(uuid) TO r_clinician, r_principal_investigator;

CREATE OR REPLACE FUNCTION registry.adjudication_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_role text := app.current_app_role(); ed record; v_reporter uuid; v_meets boolean;
BEGIN
  IF v_role IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'adjudications are opened by the database when an event is reported'
      USING ERRCODE = 'insufficient_privilege', HINT = 'cemr:ADJUDICATION_ROLE';
  END IF;
  IF (NEW.event_id, NEW.protocol_id, NEW.patient_id, NEW.centre_id) IS DISTINCT FROM
     (OLD.event_id, OLD.protocol_id, OLD.patient_id, OLD.centre_id) THEN
    RAISE EXCEPTION 'adjudication identity cannot change' USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_INVALID';
  END IF;
  IF OLD.adjudication_status = 'event_withdrawn' THEN
    RAISE EXCEPTION 'the event was entered in error; this adjudication is closed'
      USING ERRCODE = 'check_violation', HINT = 'cemr:EVENT_WITHDRAWN';
  END IF;
  IF NEW.adjudication_status IN ('pending','event_withdrawn') AND NEW.adjudication_status <> OLD.adjudication_status THEN
    RAISE EXCEPTION 'status % is set by the system', NEW.adjudication_status
      USING ERRCODE = 'insufficient_privilege', HINT = 'cemr:ADJUDICATION_ROLE';
  END IF;
  IF v_role NOT IN ('clinician','principal_investigator') THEN
    RAISE EXCEPTION 'role % may not adjudicate events', v_role
      USING ERRCODE = 'insufficient_privilege', HINT = 'cemr:ADJUDICATION_ROLE';
  END IF;
  IF OLD.adjudication_status IN ('adjudicated','not_an_event') AND app.change_reason() IS NULL THEN
    RAISE EXCEPTION 'changing an adjudication decision needs a change reason'
      USING ERRCODE = 'check_violation', HINT = 'cemr:CHANGE_REASON_REQUIRED';
  END IF;
  v_reporter := registry._event_reporter(NEW.event_id);
  IF v_reporter = app.current_user_id() THEN
    RAISE EXCEPTION 'the person who reported an event may not adjudicate it'
      USING ERRCODE = 'check_violation', HINT = 'cemr:ADJUDICATOR_CONFLICT';
  END IF;
  IF NEW.endpoint_id IS DISTINCT FROM OLD.endpoint_id AND OLD.endpoint_id IS NOT NULL THEN
    RAISE EXCEPTION 'the endpoint of an adjudication cannot change' USING ERRCODE = 'check_violation',
      HINT = 'cemr:EVENT_INVALID';
  END IF;
  SELECT * INTO ed FROM registry.endpoint_definitions WHERE endpoint_id = NEW.endpoint_id;
  IF NEW.endpoint_id IS NOT NULL AND ed.protocol_id <> NEW.protocol_id THEN
    RAISE EXCEPTION 'endpoint belongs to another protocol' USING ERRCODE = 'check_violation',
      HINT = 'cemr:PROTOCOL_MISMATCH';
  END IF;
  IF NEW.classification IS NOT NULL AND ed.classification_system IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM ref.adjudication_classifications c
        WHERE c.classification_system = ed.classification_system AND c.code = NEW.classification) THEN
    RAISE EXCEPTION 'classification % is not a % code', NEW.classification, ed.classification_system
      USING ERRCODE = 'check_violation', HINT = 'cemr:CLASSIFICATION_INVALID';
  END IF;
  IF NEW.adjudication_status = 'adjudicated' AND ed.qualifying_classifications IS NOT NULL THEN
    IF NEW.classification IS NULL THEN
      RAISE EXCEPTION 'endpoint % needs a classification', ed.endpoint_code
        USING ERRCODE = 'check_violation', HINT = 'cemr:CLASSIFICATION_INVALID';
    END IF;
    v_meets := NEW.classification = ANY (ed.qualifying_classifications);
    IF NEW.meets_endpoint IS NOT NULL AND NEW.meets_endpoint <> v_meets THEN
      RAISE EXCEPTION 'classification % % endpoint %', NEW.classification,
        CASE WHEN v_meets THEN 'meets' ELSE 'does not meet' END, ed.endpoint_code
        USING ERRCODE = 'check_violation', HINT = 'cemr:CLASSIFICATION_INVALID';
    END IF;
    NEW.meets_endpoint := v_meets;
  END IF;
  IF NEW.adjudication_status = 'not_an_event' THEN NEW.meets_endpoint := false; END IF;
  IF NEW.adjudication_status IN ('adjudicated','not_an_event','insufficient_data','in_review') THEN
    NEW.adjudicated_by := app.current_user_id();
    NEW.adjudicated_at := CASE WHEN NEW.adjudication_status IN ('adjudicated','not_an_event') THEN now() END;
    IF NEW.adjudication_status IN ('in_review','insufficient_data') THEN NEW.meets_endpoint := NULL; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER event_adjudications_a_guard BEFORE INSERT OR UPDATE ON registry.event_adjudications
  FOR EACH ROW EXECUTE FUNCTION registry.adjudication_guard();

-- What an adjudicator sees: the event, without patient identifiers when the
-- adjudicator works at another centre (central adjudication by study members).
CREATE OR REPLACE VIEW registry.v_adjudication_queue AS
SELECT adj.adjudication_id, adj.event_id, adj.protocol_id, p.protocol_code, ed.endpoint_code, ed.endpoint_label,
       ed.classification_system, ed.qualifying_classifications, adj.adjudication_status, adj.classification,
       adj.meets_endpoint, adj.adjudicated_by, adj.adjudicated_at, adj.committee_reference, adj.notes, adj.row_version,
       adj.centre_id, c.centre_code,
       CASE WHEN adj.centre_id = (SELECT app.visible_centre()) THEN adj.patient_id END AS patient_id,
       s.study_subject_code,
       ev.event_type, ev.event_date, ev.event_date - en.index_date AS event_day, ev.event_date_precision,
       ev.description, ev.hospitalised, ev.admission_date, ev.discharge_date,
       CASE WHEN adj.centre_id = (SELECT app.visible_centre()) THEN ev.facility_name END AS facility_name,
       ev.severity, ev.outcome, ev.death_cause, ev.death_cv_mode, ev.mi_type, ev.stroke_type, ev.bleeding_site,
       ev.pci_procedure_id, ev.target_lesion_id, ev.source, ev.status AS event_status, ev.reported_by, ev.created_at AS reported_at
FROM registry.event_adjudications adj
JOIN clinical.clinical_events ev ON ev.event_id = adj.event_id
JOIN registry.registry_protocols p ON p.protocol_id = adj.protocol_id
JOIN iam.centres c ON c.centre_id = adj.centre_id
LEFT JOIN registry.endpoint_definitions ed ON ed.endpoint_id = adj.endpoint_id
LEFT JOIN registry.enrolments en ON en.patient_id = adj.patient_id AND en.centre_id = adj.centre_id
      AND en.protocol_id = adj.protocol_id AND en.enrolment_status <> 'screen_failed'
LEFT JOIN research.study_subjects s ON s.enrolment_id = en.enrolment_id
WHERE adj.centre_id = (SELECT app.visible_centre())
   OR adj.centre_id = ANY (app.study_centres(adj.protocol_id));
REVOKE ALL ON registry.v_adjudication_queue FROM PUBLIC;
GRANT SELECT ON registry.v_adjudication_queue TO r_clinician, r_research_coordinator, r_principal_investigator;

-- ---------------------------------------------------------------------
-- 4. ENDPOINTS (draft, for clinical review)
-- ---------------------------------------------------------------------
-- CAD: MACE3 had no components.  Add CV death and ischaemic stroke and link
-- MACE3 = CVD + MI + ISCH_STROKE.  Lipid: same MACE3 set.
INSERT INTO registry.endpoint_definitions (protocol_id, endpoint_code, endpoint_label, endpoint_kind,
  classification_system, event_types, qualifying_classifications, definition_text, requires_adjudication, is_primary)
SELECT p.protocol_id, e.code, e.label, e.kind, e.sys, e.ev, e.q, e.def, e.adj, e.prim
FROM registry.registry_protocols p JOIN (VALUES
 ('CEMR-CAD','ACM','All-cause death','component','custom',ARRAY['death'],NULL::text[],'Death from any cause',false,false),
 ('CEMR-CAD','CVD','Cardiovascular death','component','custom',ARRAY['death'],ARRAY['cardiovascular','undetermined'],
  'Death adjudicated cardiovascular; undetermined counted as CV',true,false),
 ('CEMR-CAD','ISCH_STROKE','Ischaemic stroke','component','custom',ARRAY['stroke'],ARRAY['ischaemic'],
  'Stroke adjudicated ischaemic',true,false),
 ('CEMR-LIPID','ACM','All-cause death','component','custom',ARRAY['death'],NULL,'Death from any cause',false,false),
 ('CEMR-LIPID','CVD','Cardiovascular death','component','custom',ARRAY['death'],ARRAY['cardiovascular','undetermined'],
  'Death adjudicated cardiovascular; undetermined counted as CV',true,false),
 ('CEMR-LIPID','MI','Myocardial infarction','component','UDMI-4',ARRAY['mi'],NULL,'Fourth Universal Definition of MI',true,false),
 ('CEMR-LIPID','ISCH_STROKE','Ischaemic stroke','component','custom',ARRAY['stroke'],ARRAY['ischaemic'],
  'Stroke adjudicated ischaemic',true,false),
 ('CEMR-LIPID','MACE3','3-point MACE','composite','custom',NULL,NULL,'CV death, MI, ischaemic stroke',true,true)
) e(pc, code, label, kind, sys, ev, q, def, adj, prim) ON e.pc = p.protocol_code
ON CONFLICT (protocol_id, endpoint_code) DO NOTHING;

-- MI: qualifying UDMI-4 types (1, 2, 3, 4a-4c, 5): myocardial injury does not count.
UPDATE registry.endpoint_definitions SET qualifying_classifications = ARRAY['1','2','3','4a','4b','4c','5']
 WHERE endpoint_code = 'MI';
-- HF hospitalisation and urgent HF visit: HF-ARC event / not an HF event.
UPDATE registry.endpoint_definitions SET qualifying_classifications = ARRAY['hf_event']
 WHERE endpoint_code IN ('HFH','UHFV');

INSERT INTO registry.endpoint_components (composite_endpoint_id, component_endpoint_id)
SELECT c.endpoint_id, m.endpoint_id FROM registry.endpoint_definitions c
  JOIN registry.registry_protocols p ON p.protocol_id = c.protocol_id
  JOIN registry.endpoint_definitions m ON m.protocol_id = c.protocol_id AND m.endpoint_code IN ('CVD','MI','ISCH_STROKE')
 WHERE c.endpoint_code = 'MACE3' AND p.protocol_code IN ('CEMR-CAD','CEMR-LIPID')
ON CONFLICT DO NOTHING;

-- Every event that counts towards an endpoint, components and composites.
-- endpoint_status: confirmed (adjudicated and meets, or an endpoint without
-- adjudication), pending (awaiting a decision) or not_counted.
-- Visible rows: the caller's active centre, or the study centres of a study
-- member (as for adjudications); the research views below build on it.
CREATE OR REPLACE VIEW registry.v_endpoint_events AS
WITH comp AS (
  SELECT e.enrolment_id, e.protocol_id, e.centre_id, e.patient_id, e.index_date, ed.endpoint_id, ev.event_id,
         ev.event_type, ev.event_date,
         CASE WHEN NOT ed.requires_adjudication THEN 'confirmed'
              WHEN adj.adjudication_status = 'adjudicated' AND adj.meets_endpoint THEN 'confirmed'
              WHEN adj.adjudication_status IN ('adjudicated','not_an_event') THEN 'not_counted'
              ELSE 'pending' END AS endpoint_status
    FROM registry.enrolments e
    JOIN registry.endpoint_definitions ed ON ed.protocol_id = e.protocol_id AND ed.endpoint_kind = 'component'
         AND ed.status <> 'retired'
    JOIN clinical.clinical_events ev ON ev.patient_id = e.patient_id AND ev.centre_id = e.centre_id
         AND ev.event_type = ANY (ed.event_types) AND ev.status <> 'entered_in_error' AND NOT ev.is_historical
         AND ev.event_date >= e.index_date
         AND (e.enrolment_status = 'enrolled' OR ev.event_date <= e.status_changed_on)
    LEFT JOIN registry.event_adjudications adj ON adj.event_id = ev.event_id AND adj.protocol_id = e.protocol_id
         AND adj.endpoint_id = ed.endpoint_id
   WHERE e.enrolment_status NOT IN ('screening','screen_failed') AND e.index_date IS NOT NULL
     AND (e.centre_id = (SELECT app.visible_centre()) OR e.centre_id = ANY (app.study_centres(e.protocol_id))))
SELECT c.enrolment_id, c.protocol_id, c.centre_id, c.patient_id, d.endpoint_id, d.endpoint_code, d.endpoint_kind,
       c.event_id, c.event_type, c.event_date, c.event_date - c.index_date AS event_day, c.endpoint_status
  FROM comp c JOIN registry.endpoint_definitions d ON d.endpoint_id = c.endpoint_id
UNION ALL
SELECT c.enrolment_id, c.protocol_id, c.centre_id, c.patient_id, d.endpoint_id, d.endpoint_code, d.endpoint_kind,
       c.event_id, c.event_type, c.event_date, c.event_date - c.index_date, c.endpoint_status
  FROM comp c JOIN registry.endpoint_components ec ON ec.component_endpoint_id = c.endpoint_id
  JOIN registry.endpoint_definitions d ON d.endpoint_id = ec.composite_endpoint_id AND d.status <> 'retired';
REVOKE ALL ON registry.v_endpoint_events FROM PUBLIC;
GRANT SELECT ON registry.v_endpoint_events TO r_clinician, r_research_coordinator, r_principal_investigator;

-- ---------------------------------------------------------------------
-- 5. REPORTS
-- ---------------------------------------------------------------------
-- Follow-up: every enrolled patient in a protocol at the caller's centre,
-- with what a schedule needs plus name and mobile for the call list, and the
-- date of a reported death.  Nurses book these visits but have no registry
-- grants, so this is a narrow definer function like schedule_facts.
CREATE OR REPLACE FUNCTION registry.follow_up_facts(p_protocol uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$ SELECT registry._follow_up_facts(app.visible_centre(), p_protocol) $$;
CREATE OR REPLACE FUNCTION registry._follow_up_facts(p_centre uuid, p_protocol uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, registry, clinical AS $$
BEGIN
  IF NOT app._centre_arg_ok(p_centre) THEN
    RAISE EXCEPTION 'no active centre' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM registry.registry_protocols WHERE protocol_id = p_protocol) THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'visits', (SELECT coalesce(jsonb_agg(jsonb_build_object('visit_code', visit_code, 'visit_label', visit_label,
                 'target_day', target_day, 'window_before_days', window_before_days,
                 'window_after_days', window_after_days, 'repeats_every_days', repeats_every_days) ORDER BY sort_order), '[]')
                 FROM registry.visit_schedule WHERE protocol_id = p_protocol),
    'enrolments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'enrolment_id', e.enrolment_id, 'patient_id', e.patient_id, 'index_date', e.index_date,
                 'local_patient_code', r.local_patient_code,
                 'patient_name', concat_ws(' ', r.first_name, r.last_name), 'mobile', r.mobile,
                 'death_reported_on', (SELECT min(ev.event_date) FROM clinical.clinical_events ev
                                        WHERE ev.patient_id = e.patient_id AND ev.centre_id = e.centre_id
                                          AND ev.event_type = 'death' AND ev.status <> 'entered_in_error'),
                 'assessments', (SELECT coalesce(jsonb_agg(jsonb_build_object('assessment_id', a.assessment_id,
                                   'visit_code', a.visit_code, 'assessment_date', a.assessment_date,
                                   'completion_status', a.completion_status) ORDER BY a.assessment_date), '[]')
                                   FROM registry.assessments a WHERE a.enrolment_id = e.enrolment_id
                                    AND a.assessment_type IN ('baseline','scheduled')))
                 ORDER BY r.local_patient_code), '[]')
                 FROM registry.enrolments e
                 JOIN clinical.patient_registrations r ON r.patient_id = e.patient_id AND r.centre_id = e.centre_id
                WHERE e.protocol_id = p_protocol AND e.centre_id = p_centre AND e.enrolment_status = 'enrolled'
                  AND e.index_date IS NOT NULL));
END $$;
REVOKE EXECUTE ON FUNCTION registry._follow_up_facts(uuid, uuid), registry.follow_up_facts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registry._follow_up_facts(uuid, uuid), registry.follow_up_facts(uuid)
  TO r_nurse, r_clinician, r_research_coordinator, r_principal_investigator;

-- Missing data: one row per (assessment, mandatory variable) of the visit.
-- has_value: any value row, including a recorded reason (not_done, unknown...).
-- Missed and not-applicable assessments are not counted.
CREATE OR REPLACE VIEW registry.v_mandatory_values WITH (security_invoker = true) AS
SELECT DISTINCT ON (a.assessment_id, d.variable_id)
       e.protocol_id, a.centre_id, a.enrolment_id, a.assessment_id, a.visit_code, a.assessment_date,
       a.completion_status, d.variable_id, d.variable_code, d.variable_label, pv.sort_order,
       v.value_id IS NOT NULL AS has_value, v.value_status, v.verification_status
  FROM registry.assessments a
  JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
  JOIN registry.protocol_variables pv ON pv.protocol_id = e.protocol_id AND pv.visit_code IN (a.visit_code, '*')
       AND pv.requirement = 'mandatory'
  JOIN registry.variable_definitions d ON d.variable_id = pv.variable_id
  LEFT JOIN registry.variable_values v ON v.assessment_id = a.assessment_id AND v.variable_id = d.variable_id
 WHERE a.completion_status NOT IN ('missed','not_applicable')
 ORDER BY a.assessment_id, d.variable_id, pv.sort_order;
GRANT SELECT ON registry.v_mandatory_values TO r_clinician, r_research_coordinator, r_principal_investigator;

-- ---------------------------------------------------------------------
-- 6. RESEARCH EXPORTS
-- ---------------------------------------------------------------------
ALTER TABLE research.export_jobs
  ADD COLUMN requested_role text NOT NULL DEFAULT 'research_coordinator'
      CHECK (requested_role IN ('research_coordinator','principal_investigator')),
  ADD COLUMN decision_note text,
  ADD COLUMN failure_reason text,
  ADD COLUMN started_at timestamptz,
  ADD COLUMN manifest jsonb,
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN created_by uuid DEFAULT app.current_user_id(),
  ADD COLUMN row_version integer NOT NULL DEFAULT 1,
  ADD COLUMN updated_at timestamptz,
  ADD COLUMN updated_by uuid;
ALTER TABLE research.export_jobs ALTER COLUMN missing_value_codes
  SET DEFAULT '{"not_done":-97,"unknown":-98,"not_applicable":-99,"declined":-96,"missing":""}';
CREATE TRIGGER zz_touch_row BEFORE UPDATE ON research.export_jobs FOR EACH ROW EXECUTE FUNCTION app.touch_row();

-- State machine: requested -> approved | rejected (a PI who is not the
-- requester); approved -> running -> completed | failed (run as the
-- requester); failed -> running (retry); completed -> expired.  The
-- request itself never changes after it is made.
CREATE OR REPLACE FUNCTION research.export_job_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_role text := app.current_app_role();
BEGIN
  IF v_role IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'requested' OR NEW.approved_by IS NOT NULL OR NEW.requested_by <> app.current_user_id()
       OR v_role NOT IN ('research_coordinator','principal_investigator') THEN
      RAISE EXCEPTION 'an export starts as a request by the caller' USING ERRCODE = 'check_violation',
        HINT = 'cemr:EXPORT_STATE';
    END IF;
    NEW.requested_at := now();
    NEW.requested_role := v_role;      -- the export later runs with this role's access
    RETURN NEW;
  END IF;
  IF (NEW.protocol_id, NEW.requested_by, NEW.requested_at, NEW.requested_role, NEW.purpose, NEW.centre_ids,
      NEW.cohort_filter, NEW.index_date_rule, NEW.visit_codes, NEW.variable_codes, NEW.deidentification,
      NEW.file_format, NEW.missing_value_codes, NEW.include_data_dictionary)
     IS DISTINCT FROM
     (OLD.protocol_id, OLD.requested_by, OLD.requested_at, OLD.requested_role, OLD.purpose, OLD.centre_ids,
      OLD.cohort_filter, OLD.index_date_rule, OLD.visit_codes, OLD.variable_codes, OLD.deidentification,
      OLD.file_format, OLD.missing_value_codes, OLD.include_data_dictionary) THEN
    RAISE EXCEPTION 'an export request cannot be changed; make a new request' USING ERRCODE = 'check_violation',
      HINT = 'cemr:EXPORT_STATE';
  END IF;
  IF NEW.status = OLD.status THEN
    IF NEW.status IN ('requested','approved','rejected','expired') AND to_jsonb(NEW) - 'updated_at' - 'updated_by'
       - 'row_version' <> to_jsonb(OLD) - 'updated_at' - 'updated_by' - 'row_version' THEN
      RAISE EXCEPTION 'export % cannot change', NEW.status USING ERRCODE = 'check_violation', HINT = 'cemr:EXPORT_STATE';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT ((OLD.status, NEW.status) IN (('requested','approved'), ('requested','rejected'), ('approved','running'),
          ('running','completed'), ('running','failed'), ('failed','running'), ('completed','expired'))) THEN
    RAISE EXCEPTION 'export cannot go from % to %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation', HINT = 'cemr:EXPORT_STATE';
  END IF;
  IF NEW.status IN ('approved','rejected') THEN
    IF v_role <> 'principal_investigator' THEN
      RAISE EXCEPTION 'only a principal investigator decides exports' USING ERRCODE = 'insufficient_privilege',
        HINT = 'cemr:EXPORT_ROLE';
    END IF;
    IF NEW.requested_by = app.current_user_id() THEN
      RAISE EXCEPTION 'requester cannot decide their own export' USING ERRCODE = 'check_violation',
        HINT = 'cemr:FOUR_EYES';
    END IF;
    NEW.approved_by := app.current_user_id();
    NEW.approved_at := now();
  ELSIF NEW.status IN ('running','completed','failed') THEN
    IF NEW.requested_by <> app.current_user_id() THEN
      RAISE EXCEPTION 'exports run with the requester''s own access' USING ERRCODE = 'insufficient_privilege',
        HINT = 'cemr:EXPORT_ROLE';
    END IF;
    IF NEW.status = 'running' THEN NEW.started_at := now(); NEW.failure_reason := NULL; END IF;
    IF NEW.status = 'completed' AND (NEW.file_sha256 IS NULL OR NEW.file_storage_key IS NULL OR NEW.row_count IS NULL
                                     OR NEW.expires_at IS NULL) THEN
      RAISE EXCEPTION 'a completed export needs its file, hash, row count and expiry' USING ERRCODE = 'check_violation',
        HINT = 'cemr:EXPORT_STATE';
    END IF;
    IF NEW.status = 'completed' THEN NEW.completed_at := now(); END IF;
  ELSIF NEW.status = 'expired' AND NEW.expires_at > now() THEN
    RAISE EXCEPTION 'export has not expired yet' USING ERRCODE = 'check_violation', HINT = 'cemr:EXPORT_STATE';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER export_jobs_a_guard BEFORE INSERT OR UPDATE ON research.export_jobs
  FOR EACH ROW EXECUTE FUNCTION research.export_job_guard();

-- Pseudonymised research views over registry values.  As in the other
-- research views: subject code instead of identity, days from index instead
-- of dates (date values become a day offset and a year), only study centres,
-- never subjects whose consent withdrawal excludes collected data.
-- visit_seq numbers repeated visits with the same code (unscheduled visits).
CREATE OR REPLACE VIEW research.v_subjects AS
SELECT s.study_subject_code, e.protocol_id, e.centre_id, p.protocol_code, p.protocol_version, c.centre_code, r.sex,
       CASE WHEN r.date_of_birth IS NULL THEN NULL
            ELSE extract(year FROM age(e.index_date, r.date_of_birth))::int END AS age_at_index,
       extract(year FROM e.index_date)::int AS index_year,
       e.enrolment_date - e.index_date AS enrolment_day, e.enrolment_status,
       e.status_changed_on - e.index_date AS status_change_day
FROM registry.enrolments e
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
JOIN registry.registry_protocols p ON p.protocol_id = e.protocol_id
JOIN iam.centres c ON c.centre_id = e.centre_id
JOIN clinical.patient_registrations r ON r.patient_id = e.patient_id AND r.centre_id = e.centre_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_assessments AS
SELECT s.study_subject_code, e.protocol_id, e.centre_id, a.visit_code,
       row_number() OVER (PARTITION BY a.enrolment_id, a.visit_code ORDER BY a.assessment_date, a.created_at)::int AS visit_seq,
       a.assessment_type, a.contact_mode, a.days_from_index, a.within_window, a.completion_status,
       a.locked_at IS NOT NULL AS locked
FROM registry.assessments a
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_variable_values AS
WITH a AS (
  SELECT a.*, row_number() OVER (PARTITION BY a.enrolment_id, a.visit_code ORDER BY a.assessment_date, a.created_at)::int
           AS visit_seq
    FROM registry.assessments a)
SELECT s.study_subject_code, e.protocol_id, e.centre_id, a.visit_code, a.visit_seq, a.days_from_index,
       d.variable_code, d.data_type, v.value_status, v.numeric_value, v.text_value,
       v.date_value - e.index_date AS date_day, extract(year FROM v.date_value)::int AS date_year,
       v.boolean_value, v.coded_value, v.coded_values, v.verification_status, v.source_kind
FROM registry.variable_values v
JOIN registry.variable_definitions d ON d.variable_id = v.variable_id
JOIN a ON a.assessment_id = v.assessment_id
JOIN registry.enrolments e ON e.enrolment_id = a.enrolment_id
JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
WHERE e.centre_id = ANY (app.study_centres(e.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

-- Endpoint events and time to first event per subject and endpoint.
-- Follow-up ends (censoring) at the last day the subject is known to have
-- been followed: the latest complete assessment, the latest reported event,
-- or the day a closed enrolment ended, whichever is latest.
CREATE OR REPLACE VIEW research.v_endpoint_events AS
SELECT s.study_subject_code, p.protocol_code, x.protocol_id, x.centre_id, x.endpoint_code, x.endpoint_kind,
       x.event_type, x.event_day, x.endpoint_status
FROM registry.v_endpoint_events x
JOIN research.study_subjects s ON s.enrolment_id = x.enrolment_id
JOIN registry.registry_protocols p ON p.protocol_id = x.protocol_id
JOIN registry.enrolments e ON e.enrolment_id = x.enrolment_id
WHERE x.centre_id = ANY (app.study_centres(x.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = e.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

CREATE OR REPLACE VIEW research.v_time_to_first_event AS
WITH subj AS (
  SELECT e.enrolment_id, e.protocol_id, e.centre_id, e.consent_id, s.study_subject_code,
         greatest(
           (SELECT max(a.days_from_index) FROM registry.assessments a
             WHERE a.enrolment_id = e.enrolment_id AND a.completion_status = 'complete'),
           (SELECT max(ev.event_date - e.index_date) FROM clinical.clinical_events ev
             WHERE ev.patient_id = e.patient_id AND ev.centre_id = e.centre_id AND ev.status <> 'entered_in_error'
               AND NOT ev.is_historical AND ev.event_date >= e.index_date
               AND (e.enrolment_status = 'enrolled' OR ev.event_date <= e.status_changed_on)),
           CASE WHEN e.enrolment_status IN ('completed','withdrawn','lost_to_follow_up','deceased')
                THEN e.status_changed_on - e.index_date END,
           0) AS last_follow_up_day
    FROM registry.enrolments e JOIN research.study_subjects s ON s.enrolment_id = e.enrolment_id
   WHERE e.enrolment_status NOT IN ('screening','screen_failed') AND e.index_date IS NOT NULL
     AND (e.centre_id = (SELECT app.visible_centre()) OR e.centre_id = ANY (app.study_centres(e.protocol_id))))
SELECT subj.study_subject_code, p.protocol_code, subj.protocol_id, subj.centre_id, ed.endpoint_code, ed.endpoint_kind,
       ed.is_primary, first_ev.first_day IS NOT NULL AS had_event,
       coalesce(first_ev.first_day, subj.last_follow_up_day) AS time_days,
       subj.last_follow_up_day,
       (SELECT count(*) FROM registry.v_endpoint_events x WHERE x.enrolment_id = subj.enrolment_id
         AND x.endpoint_id = ed.endpoint_id AND x.endpoint_status = 'pending') AS pending_adjudications
FROM subj
JOIN registry.registry_protocols p ON p.protocol_id = subj.protocol_id
JOIN registry.endpoint_definitions ed ON ed.protocol_id = subj.protocol_id AND ed.status <> 'retired'
LEFT JOIN LATERAL (SELECT min(x.event_day) AS first_day FROM registry.v_endpoint_events x
                    WHERE x.enrolment_id = subj.enrolment_id AND x.endpoint_id = ed.endpoint_id
                      AND x.endpoint_status = 'confirmed') first_ev ON true
WHERE subj.centre_id = ANY (app.study_centres(subj.protocol_id))
  AND NOT EXISTS (SELECT 1 FROM clinical.patient_consents pc
                  WHERE pc.consent_id = subj.consent_id AND pc.withdrawal_scope = 'exclude_collected_data');

GRANT SELECT ON research.v_subjects, research.v_variable_values, research.v_assessments, research.v_endpoint_events,
  research.v_time_to_first_event TO r_research_coordinator, r_principal_investigator;

-- ---------------------------------------------------------------------
-- 7. ERROR TAGS THE API MAPS
-- ---------------------------------------------------------------------
INSERT INTO ref.api_error_map (source_kind, source_name, error_code, http_status, title) VALUES
 ('hint','cemr:UNIT_NOT_CONVERTIBLE','UNIT_NOT_CONVERTIBLE',422,'This unit cannot be converted to the variable''s unit'),
 ('hint','cemr:EVENT_TYPE_FIXED','VALIDATION_FAILED',422,'Event type cannot change; enter the event in error and report it again'),
 ('hint','cemr:EVENT_WITHDRAWN','EVENT_WITHDRAWN',409,'The event was entered in error'),
 ('hint','cemr:EVENT_INVALID','VALIDATION_FAILED',422,'Event details are not consistent'),
 ('hint','cemr:EVENT_LINK_INVALID','VALIDATION_FAILED',422,'A linked record does not belong to this patient'),
 ('hint','cemr:ADJUDICATION_ROLE','FORBIDDEN',403,'Role may not make this adjudication change'),
 ('hint','cemr:ADJUDICATOR_CONFLICT','ADJUDICATOR_CONFLICT',422,'The person who reported an event may not adjudicate it'),
 ('hint','cemr:CLASSIFICATION_INVALID','CLASSIFICATION_INVALID',422,'Classification does not fit this endpoint'),
 ('hint','cemr:EXPORT_STATE','CONFLICT',409,'Export is not in a state that allows this change'),
 ('hint','cemr:EXPORT_ROLE','FORBIDDEN',403,'Role may not make this export change'),
 ('hint','cemr:FOUR_EYES','FOUR_EYES',422,'An export must be approved by someone other than the requester'),
 ('constraint','clinical_events_one_death','CONFLICT',409,'A death is already recorded for this patient'),
 ('constraint','clinical_events_death_requires_cause','VALIDATION_FAILED',422,'A death needs its cause'),
 ('constraint','clinical_events_cv_mode_requires_cv_death','VALIDATION_FAILED',422,'Mode of CV death needs a cardiovascular cause'),
 ('constraint','clinical_events_mi_type_requires_mi','VALIDATION_FAILED',422,'MI type applies to MI events only'),
 ('constraint','clinical_events_discharge_after_admission','VALIDATION_FAILED',422,'Discharge is before admission'),
 ('constraint','clinical_events_admission_requires_hospitalised','VALIDATION_FAILED',422,'This event type needs hospitalised = true'),
 ('constraint','event_adjudications_decision_requires_adjudicator','VALIDATION_FAILED',422,
  'A decision needs meets_endpoint'),
 ('constraint','variable_values_entered_unit_pair','VALIDATION_FAILED',422,'An entered value needs its unit');
