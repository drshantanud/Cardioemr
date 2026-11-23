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
