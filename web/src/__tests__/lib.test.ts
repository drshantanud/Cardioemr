import { describe, expect, it } from "vitest";
import { emptyValues, toBody, validate } from "@/components/PatientForm";
import { ApiError, buildHeaders, buildUrl } from "@/lib/api";
import { safeReturnTo } from "@/lib/auth";
import { ageSex, formatDate, formatDob, formatMobile } from "@/lib/format";
import { can, homeFor, navFor } from "@/lib/roles";
import { isValidSelection, onlyChoice } from "@/lib/selection";
import type { Me } from "@/lib/types";

const me: Me = {
  user_id: "u", full_name: "Dr A", email: "a@x", platform_role: null,
  centres: [{ centre_id: "c1", centre_name: "Pune", centre_code: "PUN1", timezone: "Asia/Kolkata",
    organisation_id: "o", organisation_name: "Org", roles: ["clinician"] }],
};

describe("format", () => {
  it("formats dates day month year without shifting the day", () => {
    expect(formatDate("1968-03-14")).toBe("14 Mar 1968");
    expect(formatDate(null)).toBe("—");
  });
  it("formats an estimated date of birth as approximate", () => {
    expect(formatDob("1959-01-01", "estimated_from_age")).toBe("about 1959 (from age)");
  });
  it("groups Indian mobiles", () => {
    expect(formatMobile("9822000001")).toBe("98220 00001");
    expect(formatMobile("+919822000001")).toBe("98220 00001");
  });
  it("shows age and sex", () => {
    expect(ageSex(58, "male")).toBe("58 y · M");
    expect(ageSex(67, "female", true)).toBe("~67 y · F");
  });
});

describe("roles", () => {
  it("hides registry data from assistants and patients from centre admins", () => {
    expect(can("assistant", "registry.read")).toBe(false);
    expect(can("clinician", "registry.read")).toBe(true);
    expect(can("centre_admin", "patients.read")).toBe(false);
    expect(homeFor("centre_admin")).toBe("/no-access");
    expect(navFor("assistant").map((n) => n.href)).toEqual(["/patients"]);
    expect(navFor("principal_investigator").map((n) => n.href)).toContain("/adjudication");
  });
});

describe("selection", () => {
  it("auto-selects the only centre and role", () => {
    expect(onlyChoice(me)).toEqual({ centreId: "c1", role: "clinician" });
    expect(onlyChoice({ ...me, centres: [{ ...me.centres[0], roles: ["clinician", "principal_investigator"] }] })).toBeNull();
  });
  it("rejects a saved selection the user no longer holds", () => {
    expect(isValidSelection(me, { centreId: "c1", role: "clinician" })).toBe(true);
    expect(isValidSelection(me, { centreId: "c1", role: "principal_investigator" })).toBe(false);
    expect(isValidSelection(me, { centreId: "c2", role: "clinician" })).toBe(false);
  });
});

describe("api", () => {
  it("drops empty query values", () => {
    expect(buildUrl("/patients", { q: "", limit: 25, offset: 0 })).toBe("/api/v1/patients?limit=25&offset=0");
  });
  it("sends the acting centre, role and write headers", () => {
    const h = buildHeaders({ token: "t", centreId: "c1", role: "nurse" },
      { body: {}, idempotencyKey: "k".repeat(16), ifMatch: '"2"', changeReason: "typo" });
    expect(h.get("Authorization")).toBe("Bearer t");
    expect(h.get("X-Centre-Id")).toBe("c1");
    expect(h.get("X-Acting-Role")).toBe("nurse");
    expect(h.get("If-Match")).toBe('"2"');
    expect(h.get("X-Change-Reason")).toBe("typo");
    expect(h.get("Content-Type")).toBe("application/json");
  });
  it("turns field errors into one readable line", () => {
    const e = new ApiError(400, "VALIDATION_FAILED", "Request is not valid", undefined,
      [{ field: "mobile", message: "String should match pattern" }]);
    expect(e.userMessage).toBe("Mobile: String should match pattern");
  });
});

describe("auth", () => {
  it("only returns to same-origin paths", () => {
    expect(safeReturnTo("/patients?q=a")).toBe("/patients?q=a");
    expect(safeReturnTo("https://evil.example")).toBe("/");
    expect(safeReturnTo("//evil.example")).toBe("/");
    expect(safeReturnTo("/\\evil.example")).toBe("/");
  });
});

describe("patient form", () => {
  it("requires name, sex and a date of birth or age", () => {
    const e = validate(emptyValues(), "dob");
    expect(Object.keys(e).sort()).toEqual(["date_of_birth", "first_name", "sex"]);
    expect(validate({ ...emptyValues(), first_name: "A", sex: "male", age_years: "130" }, "age").age_years).toBeTruthy();
  });
  it("builds a clean request body", () => {
    const body = toBody({ ...emptyValues(), first_name: " Anita ", sex: "female", age_years: "62",
      mobile: "98220 12345", abha_number: "1234-5678-9012-34" }, "age");
    expect(body).toMatchObject({ first_name: "Anita", sex: "female", age_years: 62, mobile: "9822012345",
      abha_number: "12345678901234", last_name: null });
    expect(body).not.toHaveProperty("date_of_birth");
  });
});
