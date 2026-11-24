import { describe, expect, it } from "vitest";
import {
  decides, eventAsks, stentDetail, stentLine, stentOptionLabel, eventBody, eventDate, lesionLine, newEvent, newLesion, newPci, pciBody, pciDraftOf, validateEvent, validatePci,
} from "@/lib/cad";
import type { PciProcedure, StentDevice } from "@/lib/types";

const TODAY = "2026-11-23";

function filledPci() {
  const d = newPci(TODAY);
  d.indication = "chronic_coronary_syndrome";
  const l = d.lesions[0];
  Object.assign(l, { vessel: "LAD", segment_code: "6", pre_stenosis_pct: "90", residual_stenosis_pct: "0", final_timi_flow: "3" });
  Object.assign(l.stents[0], { device_other: true, device_text: "Xience Sierra", diameter_mm: "3.0", length_mm: "28", deployment_atm: "14" });
  return d;
}

describe("PCI drafts", () => {
  it("asks for indication, vessel and stent size", () => {
    const e = validatePci(newPci(TODAY), TODAY);
    expect(e.indication).toBeTruthy();
    expect(e["lesion.1.vessel"]).toBeTruthy();
    expect(e["lesion.1.stent.1.device_text"]).toBeTruthy();
    expect(e["lesion.1.stent.1.diameter_mm"]).toBe("Enter the diameter");
  });

  it("checks ranges, Medina and future dates", () => {
    const d = filledPci();
    d.procedure_date = "2026-12-01";
    d.lesions[0].stents[0].diameter_mm = "8";
    d.lesions[0].is_bifurcation = true;
    d.lesions[0].medina = "1,2,0";
    d.complications = ["none", "dissection"];
    const e = validatePci(d, TODAY);
    expect(e.procedure_date).toMatch(/future/);
    expect(e["lesion.1.stent.1.diameter_mm"]).toMatch(/between 1.5 and 6/);
    expect(e["lesion.1.medina"]).toBeTruthy();
    expect(e.complications).toBeTruthy();
  });

  it("builds the API body: numbers, nulls, and no stents unless stented", () => {
    const d = filledPci();
    expect(validatePci(d, TODAY)).toEqual({});
    const l2 = newLesion(2);
    Object.assign(l2, { vessel: "RCA", treatment: "DCB" });
    d.lesions.push(l2);
    const b = pciBody(d) as { lesions: Record<string, unknown>[]; contrast_ml: unknown; complications: unknown };
    expect(b.contrast_ml).toBeNull();
    expect(b.complications).toBeNull();
    expect(b.lesions[0]).toMatchObject({ vessel: "LAD", pre_stenosis_pct: 90, medina: null, j_cto_score: null });
    expect((b.lesions[0].stents as Record<string, unknown>[])[0]).toMatchObject({ diameter_mm: 3, length_mm: 28, deployment_atm: 14 });
    expect(b.lesions[1].stents).toEqual([]);
  });

  it("round-trips a saved procedure and keeps lesion and stent ids", () => {
    const body = pciBody(filledPci()) as unknown as PciProcedure;
    const saved: PciProcedure = {
      ...body, procedure_id: "p1", patient_id: "x", encounter_id: null, angiogram_investigation_id: null, source: "manual",
      source_document_id: null, row_version: 1,
      lesions: body.lesions.map((l) => ({ ...l, lesion_id: "l1", stents: l.stents.map((s) => ({ ...s, stent_id: "s1" })) })),
    };
    const d = pciDraftOf(saved);
    expect(d.lesions[0].lesion_id).toBe("l1");
    expect(d.lesions[0].stents[0]).toMatchObject({ stent_id: "s1", diameter_mm: "3" });
    expect(lesionLine(saved.lesions[0])).toBe("LAD (6) · 90% → 0% · 1 stent");
  });
});

describe("stent catalogue", () => {
  const orsiro: StentDevice = {
    stent_device_id: "dev-orsiro", manufacturer: "Biotronik", platform_name: "Orsiro", display_name: "Orsiro (Biotronik)",
    device_type: "DES", drug: "sirolimus", strut_material: "cobalt-chromium", polymer_type: "biodegradable", polymer: "PLLA",
    strut_thickness_min_um: 60, strut_thickness_max_um: 80, aliases: [], review_status: "pending_clinical_review", status: "active",
  };

  it("asks to choose a catalogue stent, or to type one marked other", () => {
    const d = filledPci();
    Object.assign(d.lesions[0].stents[0], { device_other: false, device_text: "" });
    expect(validatePci(d, TODAY)["lesion.1.stent.1.device_text"]).toBe("Choose the stent");
    Object.assign(d.lesions[0].stents[0], { device_other: true });
    expect(validatePci(d, TODAY)["lesion.1.stent.1.device_text"]).toBe("Type the make and model");
  });

  it("sends the catalogue id without typed text, and typed text without an id", () => {
    const d = filledPci();
    Object.assign(d.lesions[0].stents[0], { device_other: false, stent_device_id: "dev-orsiro", device_text: "left over" });
    let s = (pciBody(d) as { lesions: { stents: Record<string, unknown>[] }[] }).lesions[0].stents[0];
    expect(s).toMatchObject({ stent_device_id: "dev-orsiro", device_text: null });
    Object.assign(d.lesions[0].stents[0], { device_other: true, device_text: "Yukon Choice PC" });
    s = (pciBody(d) as { lesions: { stents: Record<string, unknown>[] }[] }).lesions[0].stents[0];
    expect(s).toMatchObject({ stent_device_id: null, device_text: "Yukon Choice PC" });
  });

  it("labels devices in the picker and on the summary", () => {
    expect(stentOptionLabel(orsiro)).toBe("Orsiro (Biotronik)");
    expect(stentDetail(orsiro)).toBe("sirolimus · biodegradable polymer · 60–80 µm struts");
    expect(stentDetail({ ...orsiro, strut_thickness_max_um: 60 })).toMatch(/· 60 µm struts$/);
    expect(stentOptionLabel({ ...orsiro, status: "retired" })).toMatch(/\(retired\)$/);
    const saved = { sequence_number: 1, stent_device_id: "dev-orsiro", device_text: null, device_name: "Orsiro (Biotronik)",
      diameter_mm: 3, length_mm: 30, deployment_atm: null, post_dilatation_balloon_mm: null };
    expect(stentLine(saved)).toBe("Orsiro (Biotronik) 3 × 30 mm");
    expect(pciDraftOf({ ...(pciBody(filledPci()) as unknown as PciProcedure), lesions: [] }).lesions).toEqual([]);
  });
});

describe("event drafts", () => {
  it("a death needs its cause; dates in order", () => {
    const d = { ...newEvent(TODAY), event_type: "death", admission_date: "2026-11-10", discharge_date: "2026-11-05" };
    const e = validateEvent(d, TODAY);
    expect(e.death_cause).toBeTruthy();
    expect(e.discharge_date).toBeTruthy();
  });

  it("sends only the details the type asks for", () => {
    const d = { ...newEvent(TODAY), event_type: "hf_hospitalisation", mi_type: "1", admission_date: "2026-11-01" };
    const b = eventBody(d);
    expect(b.hospitalised).toBe(true);
    expect(b.mi_type).toBeNull();
    expect(b.admission_date).toBe("2026-11-01");
    expect(eventAsks("mi").mi).toBe(true);
    const death = eventBody({ ...newEvent(TODAY), event_type: "death", death_cause: "non_cardiovascular", death_cv_mode: "sudden" });
    expect(death.death_cv_mode).toBeNull();
  });

  it("shows a date at its recorded precision", () => {
    expect(eventDate("2024-03-01", "year")).toBe("2024");
    expect(eventDate("2024-03-01", "month")).toMatch(/Mar.*2024/);
  });

  it("knows when a classification decides the endpoint", () => {
    expect(decides(["definite", "probable"])).toBe(true);
    expect(decides(null)).toBe(false);
  });
});
