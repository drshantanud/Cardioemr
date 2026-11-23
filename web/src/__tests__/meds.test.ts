import { describe, expect, it } from "vitest";
import { dailyDose, doseLine, eventLabel } from "@/lib/meds";

describe("medicine wording", () => {
  it("writes a tablet dose with its printed strength", () => {
    expect(doseLine({ strength_label: "49/51 mg", dose_quantity: 1, dose_unit: "tablet", frequency_code: "BD", route: "oral" }))
      .toBe("49/51 mg · 1 tablet BD");
    expect(doseLine({ strength_label: "3.125 mg", dose_quantity: 2, dose_unit: "tablet", frequency_code: "BD", route: "oral" }))
      .toBe("3.125 mg · 2 tablets BD");
  });
  it("drops the strength when the dose is already in mg and shows non-oral routes", () => {
    expect(doseLine({ strength_label: "75 mg", dose_quantity: 75, dose_unit: "mg", frequency_code: "OD", route: "oral" }))
      .toBe("75 mg OD");
    expect(doseLine({ strength_label: "140 mg/ml", dose_quantity: 1, dose_unit: "injection", frequency_code: "Q2W", route: "sc" }))
      .toBe("140 mg/ml · 1 injection Q2W (sc)");
  });
  it("is empty without a dose", () => {
    expect(doseLine(null)).toBe("");
    expect(doseLine({ strength_label: null, dose_quantity: null, dose_unit: "tablet", frequency_code: "OD", route: "oral" })).toBe("");
  });
  it("formats daily dose and event names", () => {
    expect(dailyDose(12.5, "mg")).toBe("12.5 mg/day");
    expect(dailyDose(null, "mg")).toBe("");
    expect(eventLabel("increase")).toBe("Dose increased");
    expect(eventLabel("something_new")).toBe("something new");
  });
});
