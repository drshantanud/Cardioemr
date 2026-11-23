// Shapes returned by the API (see api/registry-api-v0.1.yaml).

export interface Membership {
  centre_id: string;
  centre_name: string;
  centre_code: string;
  timezone: string;
  organisation_id: string;
  organisation_name: string;
  roles: string[];
}

export interface Me {
  user_id: string;
  full_name: string;
  email: string;
  platform_role: string | null;
  centres: Membership[];
}

export type Sex = "male" | "female" | "other" | "unknown";
export type DobPrecision = "day" | "month" | "year" | "estimated_from_age";

export interface PatientSummary {
  patient_id: string;
  registration_id: string;
  local_patient_code: string;
  first_name: string;
  middle_name: string | null;
  last_name: string | null;
  display_name: string;
  date_of_birth: string | null;
  dob_precision: DobPrecision;
  age_years: number | null;
  sex: Sex;
  mobile: string | null;
  city: string | null;
  registration_date: string;
  status: string;
  row_version: number;
}

export interface Patient extends PatientSummary {
  alternate_mobile: string | null;
  email: string | null;
  address_line: string | null;
  district: string | null;
  state_code: string | null;
  pincode: string | null;
  abha_number: string | null;
  abha_address: string | null;
  emergency_contact_name: string | null;
  emergency_contact_relation: string | null;
  emergency_contact_phone: string | null;
  occupation: string | null;
  referral_source: string | null;
  referral_detail: string | null;
  linkage_status: string;
}

export interface PatientList {
  items: PatientSummary[];
  has_more: boolean;
  limit: number;
  offset: number;
}

export interface Consent {
  consent_id: string;
  consent_type: string;
  consent_status: string;
  consent_date: string;
  consent_form_version: string;
  withdrawal_date: string | null;
  protocol_code: string | null;
  protocol_id?: string | null;
  row_version?: number;
}

export interface Allergy {
  allergy_id: string;
  allergen_type: string;
  allergen_text: string;
  reaction: string | null;
  severity: string | null;
}

export interface EncounterHeader {
  encounter_id: string;
  encounter_type: string;
  encounter_start: string;
  status: string;
  follow_up_date: string | null;
  clinician_name: string | null;
}

export interface EnrolmentHeader {
  enrolment_id: string;
  protocol_id: string;
  registry_code: string;
  registry_name: string;
  protocol_code: string;
  enrolment_status: string;
  eligibility_status: string;
  screening_date: string;
  enrolment_date: string | null;
  index_date: string | null;
}

export interface SuggestionHeader {
  suggestion_id: string;
  registry_code: string;
  suggested_at: string;
  status: string;
}

export interface PatientOverview {
  patient: Patient;
  consents: Consent[];
  allergies: Allergy[];
  recent_encounters: EncounterHeader[];
  enrolments: EnrolmentHeader[] | null;
  registry_suggestions: SuggestionHeader[] | null;
}

export interface DuplicateCandidate {
  patient_id: string;
  local_patient_code: string;
  display_name: string;
  date_of_birth: string | null;
  sex: Sex;
  mobile: string | null;
}

// --- consultations -------------------------------------------------------------

export interface Concept {
  concept_code: string;
  display_name: string;
  icd10_code: string | null;
  registry_triggers: string[];
}

export interface ComplaintEntry {
  concept_code: string;
  display_name?: string;
  duration_value: number | null;
  duration_unit: string | null;
  detail: string | null;
}

export interface ClinicalAssessment {
  nyha_class: string | null;
  ccs_class: string | null;
  killip_class: string | null;
  jvp: string | null;
  jvp_cm: number | null;
  peripheral_oedema: string | null;
  pulmonary_rales: boolean | null;
  s3_gallop: boolean | null;
  orthopnoea: boolean | null;
  pnd: boolean | null;
  congestion_status: string | null;
  hf_phenotype: string | null;
  cv_risk_category: string | null;
}

export interface VitalsRow {
  vital_id: string;
  encounter_id?: string | null;
  measured_at: string;
  bmi: number | null;
  height_cm: number | null;
  weight_kg: number | null;
  waist_cm: number | null;
  systolic_bp: number | null;
  diastolic_bp: number | null;
  bp_position: string | null;
  heart_rate: number | null;
  pulse_rhythm: string | null;
  respiratory_rate: number | null;
  spo2: number | null;
  temperature_c: number | null;
}

export interface Diagnosis {
  diagnosis_id: string;
  encounter_id?: string | null;
  concept_code: string | null;
  diagnosis_text: string;
  icd10_code: string | null;
  diagnosis_role: string;
  certainty: string;
  is_principal: boolean;
  onset_date?: string | null;
  resolved_date?: string | null;
  status: string;
  row_version?: number;
  new_registry_suggestions?: { suggestion_id: string; registry_code: string }[];
}

export interface EncounterMedEvent {
  medication_event_id: string;
  course_id: string;
  event_type: string;
  effective_date: string;
  generic_name: string;
  strength_label: string | null;
  dose_quantity: number | null;
  dose_unit: string | null;
  frequency_code: string | null;
  daily_dose: number | null;
  reference_unit: string;
  route: string;
  instructions: string | null;
  reason_text: string | null;
  brand_name_text: string | null;
  voided: boolean;
}

export interface AmendmentRow {
  amendment_id: string;
  field_name: string;
  previous_value: string | null;
  amended_value: string;
  reason: string;
  amended_at: string;
  amended_by_name: string | null;
}

export type NoteField =
  | "presenting_complaint" | "history_present_illness" | "clinical_history" | "examination_cvs" | "examination_resp"
  | "examination_other" | "assessment" | "plan" | "lifestyle_advice" | "patient_education" | "referral_to";

export interface Encounter extends Record<NoteField, string | null> {
  encounter_id: string;
  patient_id: string;
  clinician_id: string;
  clinician_name: string | null;
  encounter_type: string;
  setting: string;
  encounter_start: string;
  encounter_end: string | null;
  follow_up_date: string | null;
  status: "draft" | "signed" | "amended" | "entered_in_error";
  signed_at: string | null;
  signed_by_name: string | null;
  row_version: number;
  complaints: ComplaintEntry[];
  clinical_assessment: ClinicalAssessment | null;
  vitals: VitalsRow[];
  diagnoses: Diagnosis[];
  medication_events: EncounterMedEvent[];
  amendments: AmendmentRow[];
}

export interface EncounterListItem {
  encounter_id: string;
  encounter_type: string;
  encounter_start: string;
  status: string;
  follow_up_date: string | null;
  assessment_preview: string | null;
  clinician_name: string | null;
  complaints: string | null;
}

// --- medicines -------------------------------------------------------------------

export interface DrugProduct {
  product_id: string;
  brand_name: string;
  strength_label: string;
  reference_strength: number;
  dose_form: string;
}

export interface Drug {
  drug_code: string;
  generic_name: string;
  reference_unit: string;
  default_route: string;
  is_combination: boolean;
  classes: string[];
  products: DrugProduct[];
}

export interface MedEvent {
  medication_event_id: string;
  event_type: string;
  effective_date: string;
  recorded_at: string;
  encounter_id: string | null;
  brand_name_text: string | null;
  strength_label: string | null;
  dose_quantity: number | null;
  dose_unit: string | null;
  frequency_code: string | null;
  doses_per_day: number | null;
  daily_dose: number | null;
  route: string;
  duration_days: number | null;
  instructions: string | null;
  reason_text: string | null;
  reason: string | null;
  prescriber_source: string;
  prescribed_by_name: string | null;
  voids_event_id: string | null;
  voided: boolean;
}

export interface MedicationCourse {
  course_id: string;
  drug_code: string;
  generic_name: string;
  reference_unit: string;
  default_route: string;
  indication: string | null;
  started_on: string;
  stopped_on: string | null;
  status: "active" | "on_hold" | "stopped" | "entered_in_error";
  classes: string[];
  current_dose: MedEvent | null;
  events?: MedEvent[];
}

export interface LabSummary {
  analyte_code: string;
  analyte_name: string;
  comparator: string;
  value_reported: number | null;
  unit_reported: string | null;
  value_canonical: number | null;
  canonical_unit: string;
  collected_at: string;
  verification_status: string;
  abnormal_flag: string | null;
}

export interface ClinicalSummary {
  last_signed_encounter: Encounter | null;
  medications: MedicationCourse[];
  diagnoses: Diagnosis[];
  allergies: Allergy[];
  latest_vitals: VitalsRow | null;
  latest_labs: LabSummary[];
  latest_echo: { performed_on: string; lvef: number | null; lvef_method: string | null; rv_function: string | null;
    diastolic_grade: string | null; pasp_mmhg: number | null; interpretation: string | null; verification_status: string } | null;
  latest_ecg: { performed_on: string; rhythm: string | null; heart_rate: number | null; qrs_ms: number | null;
    qtc_ms: number | null; qrs_morphology: string | null; interpretation: string | null; verification_status: string } | null;
}

// ---- registries ------------------------------------------------------------

export interface ProtocolSummary {
  protocol_id: string;
  protocol_code: string;
  protocol_version: string;
  status: string;
  site_status: string | null;
}

export interface Registry {
  registry_code: string;
  registry_name: string;
  protocols: ProtocolSummary[];
}

export interface Visit {
  visit_code: string;
  visit_label: string;
  target_day: number;
  window_before_days: number;
  window_after_days: number;
  repeats_every_days: number | null;
}

export interface Protocol {
  protocol_id: string;
  protocol_code: string;
  protocol_version: string;
  registry_code: string;
  title: string;
  status: string;
  requires_research_consent: boolean;
  inclusion_text: string;
  exclusion_text: string | null;
  inclusion_rules: { code: string; label: string }[];
  exclusion_rules: { code: string; label: string }[];
  visits: Visit[];
  rule_sets: { rule_kind: string; rule_set_code: string; version: string; status: string; role: string }[];
}

export interface ScheduleItem {
  visit_code: string;
  occurrence: number;
  target_date: string;
  window_opens: string;
  window_closes: string;
  status: "done" | "due" | "overdue" | "not_due" | "missed" | "not_applicable";
  assessment_id: string | null;
}

export interface Enrolment {
  enrolment_id: string;
  patient_id: string;
  protocol_id: string;
  registry_code: "HF" | "LIPID" | "CAD";
  screening_date: string;
  enrolment_date: string | null;
  index_date: string | null;
  eligibility_status: string;
  consent_id: string | null;
  enrolment_status: string;
  status_changed_on: string | null;
  row_version: number;
  study_subject_code: string | null;
  details: Record<string, unknown> | null;
  schedule?: ScheduleItem[];
}

export interface AssessmentHeader {
  assessment_id: string;
  enrolment_id: string;
  visit_code: string;
  assessment_type: string;
  contact_mode: string;
  assessment_date: string;
  days_from_index: number | null;
  within_window: boolean | null;
  completion_status: string;
  missed_reason: string | null;
  locked_at: string | null;
  row_version: number;
}

export type DataType = "numeric" | "integer" | "text" | "date" | "boolean" | "coded" | "multi_coded";

export interface VariableDefinition {
  variable_code: string;
  definition_version: number;
  category: string;
  variable_label: string;
  data_type: DataType;
  unit: string | null;
  allowed_values: { code: string; label: string }[] | null;
  min_value: number | null;
  max_value: number | null;
  source_kind: "entered" | "emr_derived" | "calculated";
  emr_source: string | null;
  visit_code: string;
  requirement: "mandatory" | "conditional" | "optional";
  condition_text: string | null;
  accepted_units: string[] | null;
}

export type ValueStatus = "present" | "not_done" | "unknown" | "not_applicable" | "declined";

export interface VariableValue {
  variable_code: string;
  value_status: ValueStatus;
  value: number | string | boolean | string[] | null;
  source_kind: string;
  source_table: string | null;
  source_row_id: string | null;
  verification_status: "unverified" | "verified" | "queried";
  entered_value: number | null;
  entered_unit: string | null;
  updated_at: string | null;
  row_version: number;
}

export interface Assessment extends AssessmentHeader {
  variables: { definition: VariableDefinition; value: VariableValue | null }[];
  mandatory_missing: string[];
}

export interface PrefillResult {
  filled: VariableValue[];
  skipped: { variable_code: string; reason: string; detail?: string }[];
}

export interface GdmtPillar {
  pillar: "RASI" | "BB" | "MRA" | "SGLT2I";
  drug_code: string | null;
  daily_dose: number | null;
  target_daily_dose: number | null;
  pct_of_target: number | null;
  eligible: boolean;
  prescribed: boolean;
  dose_status: string;
  source: string;
  reasons: string[];
  initiation_date: string | null;
  last_titration_date: string | null;
}

export interface Gdmt {
  as_of: string;
  rule_set: string;
  rule_set_status: string;
  hf_phenotype: string;
  stored: boolean;
  pillars: GdmtPillar[];
  pillars_eligible: number;
  pillars_on_treatment: number;
  pillars_at_target: number;
}

export interface LipidTargetRow {
  guideline: string;
  rule_set_code: string;
  rule_set_status: string;
  is_primary: boolean;
  risk_category: string;
  ldl_target_mg_dl: number;
  ldl_mg_dl: number | null;
  ldl_pct_reduction: number | null;
  target_met: boolean | null;
  row_version: number;
}

export interface LipidTargets {
  items: LipidTargetRow[];
  guidelines: { rule_set_code: string; version: string; status: string; is_primary: boolean;
    categories: { risk_category: string; ldl_target_mg_dl: number; target_operator: string; min_pct_reduction: number | null }[] }[];
}

// --- CAD procedures, events and adjudication -------------------------------------

export interface PciStent {
  stent_id?: string;
  sequence_number: number;
  stent_device_id: string | null;
  device_text: string | null;
  diameter_mm: number;
  length_mm: number;
  deployment_atm: number | null;
  post_dilatation_balloon_mm: number | null;
}

export interface PciLesion {
  lesion_id?: string;
  lesion_number: number;
  vessel: string;
  segment_code: string | null;
  lesion_type_acc_aha: string | null;
  lesion_length_mm: number | null;
  reference_diameter_mm: number | null;
  pre_stenosis_pct: number | null;
  pre_timi_flow: number | null;
  calcification: string | null;
  is_cto: boolean;
  j_cto_score: number | null;
  is_bifurcation: boolean;
  medina: string | null;
  bifurcation_technique: string | null;
  is_in_stent_restenosis: boolean;
  thrombus: boolean | null;
  lesion_preparation: string[] | null;
  post_dilatation: boolean | null;
  pre_physiology_value: number | null;
  post_physiology_value: number | null;
  final_timi_flow: number | null;
  residual_stenosis_pct: number | null;
  treatment: string;
  stents: PciStent[];
}

export interface PciProcedure {
  procedure_id: string;
  patient_id: string;
  encounter_id: string | null;
  angiogram_investigation_id: string | null;
  procedure_date: string;
  performed_at_facility: string | null;
  indication: string;
  urgency: string | null;
  access_site: string | null;
  operator_name: string | null;
  imaging_guidance: string;
  physiology: string;
  mechanical_support: string | null;
  contrast_ml: number | null;
  fluoroscopy_min: number | null;
  procedural_success: boolean | null;
  complications: string[] | null;
  source: string;
  source_document_id: string | null;
  status: "draft" | "final" | "entered_in_error";
  row_version: number;
  lesions: PciLesion[];
}

export interface ClinicalEvent {
  event_id: string;
  patient_id: string;
  event_type: string;
  event_date: string;
  event_date_precision: "day" | "month" | "year";
  is_historical: boolean;
  description: string | null;
  hospitalised: boolean | null;
  admission_date: string | null;
  discharge_date: string | null;
  facility_name: string | null;
  severity: string | null;
  outcome: string | null;
  death_cause: string | null;
  death_cv_mode: string | null;
  mi_type: string | null;
  stroke_type: string | null;
  bleeding_site: string | null;
  pci_procedure_id: string | null;
  target_lesion_id: string | null;
  potassium_mmol_l: number | null;
  creatinine_result_id: string | null;
  source: string;
  source_document_id: string | null;
  reported_by: string;
  status: "reported" | "source_verified" | "entered_in_error";
  created_at: string;
  row_version: number;
}

export interface Adjudication {
  adjudication_id: string;
  event_id: string;
  protocol_code: string;
  endpoint_code: string | null;
  endpoint_label: string | null;
  classification_system: string | null;
  qualifying_classifications: string[] | null;
  event_type: string;
  event_date: string;
  event_day: number | null;
  adjudication_status: "pending" | "in_review" | "adjudicated" | "not_an_event" | "insufficient_data" | "event_withdrawn";
  classification: string | null;
  meets_endpoint: boolean | null;
  adjudicated_by: string | null;
  adjudicated_at: string | null;
  committee_reference: string | null;
  notes: string | null;
  centre_code: string;
  study_subject_code: string | null;
  patient_id: string | null;
  row_version: number;
  event: {
    event_date_precision: string; description: string | null; hospitalised: boolean | null;
    admission_date: string | null; discharge_date: string | null; facility_name: string | null;
    severity: string | null; outcome: string | null; death_cause: string | null; death_cv_mode: string | null;
    mi_type: string | null; stroke_type: string | null; bleeding_site: string | null;
    pci_procedure_id: string | null; target_lesion_id: string | null; source: string; event_status: string;
    reported_by: string; reported_at: string;
  };
}

export interface EventWithAdjudications {
  event: ClinicalEvent;
  adjudications: Adjudication[];
}

export interface Classification {
  classification_system: string;
  code: string;
  label: string;
}
