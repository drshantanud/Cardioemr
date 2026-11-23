"use client";
import { useState } from "react";
import type { FormEvent, ReactNode } from "react";
import { REFERRAL_SOURCES, STATES } from "@/lib/format";
import type { Patient } from "@/lib/types";
import { Field } from "./ui";

// Form values are strings; empty means "not given".
export type PatientFormValues = Record<(typeof FIELDS)[number], string>;

export const FIELDS = [
  "first_name", "middle_name", "last_name", "date_of_birth", "age_years", "sex", "mobile", "alternate_mobile", "email",
  "address_line", "city", "district", "state_code", "pincode", "abha_number", "emergency_contact_name",
  "emergency_contact_relation", "emergency_contact_phone", "occupation", "referral_source", "referral_detail",
] as const;

export function emptyValues(): PatientFormValues {
  return Object.fromEntries(FIELDS.map((f) => [f, ""])) as PatientFormValues;
}

export function valuesFrom(p: Patient): PatientFormValues {
  const v = emptyValues();
  for (const f of FIELDS) {
    const x = (p as unknown as Record<string, unknown>)[f];
    if (x !== null && x !== undefined) v[f] = String(x);
  }
  v.age_years = "";
  return v;
}

const MOBILE = /^\+?[0-9]{10,15}$/;

/** Client-side checks that mirror the API, so most mistakes show before saving. */
export function validate(v: PatientFormValues, dobMode: "dob" | "age"): Partial<Record<keyof PatientFormValues, string>> {
  const e: Partial<Record<keyof PatientFormValues, string>> = {};
  if (!v.first_name.trim()) e.first_name = "Enter the first name";
  if (!v.sex) e.sex = "Choose one";
  if (dobMode === "dob") {
    if (!v.date_of_birth) e.date_of_birth = "Enter the date of birth, or switch to age";
    else if (v.date_of_birth > new Date().toISOString().slice(0, 10) || v.date_of_birth < "1900-01-01")
      e.date_of_birth = "Date of birth is not plausible";
  } else {
    const a = Number(v.age_years);
    if (!v.age_years || !Number.isInteger(a) || a < 0 || a > 120) e.age_years = "Age in whole years, 0 to 120";
  }
  for (const f of ["mobile", "alternate_mobile", "emergency_contact_phone"] as const) {
    const d = v[f].replace(/[\s-]/g, "");
    if (d && !MOBILE.test(d)) e[f] = "10 to 15 digits";
  }
  if (v.email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.email)) e.email = "Not a valid email address";
  if (v.pincode && !/^[1-9][0-9]{5}$/.test(v.pincode)) e.pincode = "Six digits";
  if (v.abha_number && !/^[0-9]{14}$/.test(v.abha_number.replace(/[\s-]/g, ""))) e.abha_number = "14 digits";
  return e;
}

/** Request body: trimmed strings, empty as null, phone and ABHA numbers without spaces. */
export function toBody(v: PatientFormValues, dobMode: "dob" | "age"): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const f of FIELDS) {
    if (f === "age_years" || f === "date_of_birth") continue;
    let s = v[f].trim();
    if (["mobile", "alternate_mobile", "emergency_contact_phone", "abha_number"].includes(f)) s = s.replace(/[\s-]/g, "");
    out[f] = s === "" ? null : s;
  }
  if (dobMode === "dob") out.date_of_birth = v.date_of_birth;
  else out.age_years = Number(v.age_years);
  return out;
}

export function PatientForm({
  initial, allowAge, onSubmit, busy, footer, banner,
}: {
  initial: PatientFormValues;
  allowAge: boolean;
  onSubmit: (values: PatientFormValues, dobMode: "dob" | "age") => void;
  busy: boolean;
  footer: ReactNode;
  banner?: ReactNode;
}) {
  const [v, setV] = useState(initial);
  const [dobMode, setDobMode] = useState<"dob" | "age">("dob");
  const [errors, setErrors] = useState<ReturnType<typeof validate>>({});
  const [tried, setTried] = useState(false);

  const set = (f: keyof PatientFormValues) => (e: { target: { value: string } }) => {
    const next = { ...v, [f]: e.target.value };
    setV(next);
    if (tried) setErrors(validate(next, dobMode));
  };
  const input = (f: keyof PatientFormValues, extra: Record<string, unknown> = {}) => ({
    id: f, name: f, className: "input", value: v[f], onChange: set(f),
    "aria-invalid": errors[f] ? true : undefined, "aria-describedby": errors[f] ? `${f}-err` : undefined, ...extra,
  });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setTried(true);
    const errs = validate(v, dobMode);
    setErrors(errs);
    if (Object.keys(errs).length) {
      document.getElementById(Object.keys(errs)[0])?.focus();
      return;
    }
    onSubmit(v, dobMode);
  };

  return (
    <form className="card" onSubmit={submit} noValidate>
      {banner && <div style={{ padding: "16px 16px 0" }}>{banner}</div>}
      <div className="form-section">
        <h2>Identity</h2>
        <div className="form-grid">
          <Field label="First name" htmlFor="first_name" required error={errors.first_name} className="span-2">
            <input {...input("first_name", { autoComplete: "off", autoFocus: true })} />
          </Field>
          <Field label="Middle name" htmlFor="middle_name" className="span-2">
            <input {...input("middle_name", { autoComplete: "off" })} />
          </Field>
          <Field label="Last name" htmlFor="last_name" hint="Leave empty if the patient uses one name" className="span-2">
            <input {...input("last_name", { autoComplete: "off" })} />
          </Field>
          <div className="field span-3">
            <div className="row" style={{ justifyContent: "space-between" }}>
              <label htmlFor={dobMode === "dob" ? "date_of_birth" : "age_years"}>
                {dobMode === "dob" ? "Date of birth" : "Age in years"}<span className="req" aria-hidden>*</span>
              </label>
              {allowAge && (
                <div className="segmented" role="group" aria-label="Date of birth or age">
                  <button type="button" aria-pressed={dobMode === "dob"} onClick={() => setDobMode("dob")}>Date of birth</button>
                  <button type="button" aria-pressed={dobMode === "age"} onClick={() => setDobMode("age")}>Age only</button>
                </div>
              )}
            </div>
            {dobMode === "dob" ? (
              <input type="date" {...input("date_of_birth", { max: new Date().toISOString().slice(0, 10), min: "1900-01-01" })} />
            ) : (
              <input type="number" inputMode="numeric" {...input("age_years", { min: 0, max: 120 })} />
            )}
            {(errors.date_of_birth || errors.age_years) ? (
              <span className="err" id={`${dobMode === "dob" ? "date_of_birth" : "age_years"}-err`}>
                {errors.date_of_birth ?? errors.age_years}
              </span>
            ) : dobMode === "age" ? <span className="hint">Stored as an estimated date of birth</span> : null}
          </div>
          <Field label="Sex" htmlFor="sex" required error={errors.sex} className="span-3 align-end">
            <select {...input("sex")}>
              <option value="">Choose…</option>
              <option value="male">Male</option>
              <option value="female">Female</option>
              <option value="other">Other</option>
              <option value="unknown">Not known</option>
            </select>
          </Field>
        </div>
      </div>

      <div className="form-section">
        <h2>Contact</h2>
        <div className="form-grid">
          <Field label="Mobile" htmlFor="mobile" error={errors.mobile} className="span-2">
            <input type="tel" inputMode="tel" {...input("mobile", { autoComplete: "off", placeholder: "98220 00000" })} />
          </Field>
          <Field label="Alternate mobile" htmlFor="alternate_mobile" error={errors.alternate_mobile} className="span-2">
            <input type="tel" inputMode="tel" {...input("alternate_mobile", { autoComplete: "off" })} />
          </Field>
          <Field label="Email" htmlFor="email" error={errors.email} className="span-2">
            <input type="email" inputMode="email" {...input("email", { autoComplete: "off" })} />
          </Field>
          <Field label="Address" htmlFor="address_line" className="span-6">
            <input {...input("address_line", { autoComplete: "off" })} />
          </Field>
          <Field label="City / town" htmlFor="city" className="span-2">
            <input {...input("city", { autoComplete: "off" })} />
          </Field>
          <Field label="District" htmlFor="district" className="span-2">
            <input {...input("district", { autoComplete: "off" })} />
          </Field>
          <Field label="State" htmlFor="state_code" className="span-1" >
            <select {...input("state_code")}>
              <option value="">—</option>
              {STATES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
            </select>
          </Field>
          <Field label="PIN code" htmlFor="pincode" error={errors.pincode} className="span-1">
            <input inputMode="numeric" maxLength={6} {...input("pincode", { autoComplete: "off" })} />
          </Field>
        </div>
      </div>

      <div className="form-section">
        <h2>Emergency contact</h2>
        <div className="form-grid">
          <Field label="Name" htmlFor="emergency_contact_name" className="span-2">
            <input {...input("emergency_contact_name", { autoComplete: "off" })} />
          </Field>
          <Field label="Relation" htmlFor="emergency_contact_relation" className="span-2">
            <input {...input("emergency_contact_relation", { autoComplete: "off", placeholder: "e.g. Son" })} />
          </Field>
          <Field label="Phone" htmlFor="emergency_contact_phone" error={errors.emergency_contact_phone} className="span-2">
            <input type="tel" inputMode="tel" {...input("emergency_contact_phone", { autoComplete: "off" })} />
          </Field>
        </div>
      </div>

      <div className="form-section">
        <h2>Other details</h2>
        <div className="form-grid">
          <Field label="Occupation" htmlFor="occupation" className="span-2">
            <input {...input("occupation", { autoComplete: "off" })} />
          </Field>
          <Field label="Referred by" htmlFor="referral_source" className="span-2">
            <select {...input("referral_source")}>
              <option value="">—</option>
              {REFERRAL_SOURCES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
            </select>
          </Field>
          <Field label="Referral details" htmlFor="referral_detail" className="span-2">
            <input {...input("referral_detail", { autoComplete: "off", placeholder: "Doctor or hospital name" })} />
          </Field>
          <Field label="ABHA number" htmlFor="abha_number" error={errors.abha_number} hint="Ayushman Bharat Health Account, 14 digits" className="span-3">
            <input inputMode="numeric" {...input("abha_number", { autoComplete: "off" })} />
          </Field>
        </div>
      </div>
      <div className="form-actions">
        {footer}
        <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
      </div>
    </form>
  );
}
