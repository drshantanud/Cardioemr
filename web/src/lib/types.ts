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
