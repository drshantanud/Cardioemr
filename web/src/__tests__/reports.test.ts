import { describe, expect, it } from "vitest";
import { apiPathOf } from "@/lib/api";
import { byCategory, exportBody, newExport, validateExport } from "@/lib/exports";
import { closesText } from "@/lib/reports";
import { navFor } from "@/lib/roles";

describe("follow-up wording", () => {
  it("says how far the window is", () => {
    expect(closesText({ status: "overdue", days_until_window_closes: -3, window_opens: "2026-10-01" }, "2026-11-24")).toBe("window closed 3 days ago");
    expect(closesText({ status: "due", days_until_window_closes: 0, window_opens: "2026-11-20" }, "2026-11-24")).toBe("window closes today");
    expect(closesText({ status: "due", days_until_window_closes: 1, window_opens: "2026-11-20" }, "2026-11-24")).toBe("window closes in 1 day");
    expect(closesText({ status: "not_due", days_until_window_closes: 20, window_opens: "2026-11-29" }, "2026-11-24")).toBe("opens in 5 days");
  });
});

describe("export requests", () => {
  it("needs a purpose and variables; years in order", () => {
    const d = { ...newExport("p1"), purpose: "short", index_year_from: "2027", index_year_to: "2026" };
    const e = validateExport(d);
    expect(e.purpose).toBeTruthy();
    expect(e.variable_codes).toBeTruthy();
    expect(e.index_year_to).toBeTruthy();
  });

  it("builds the body with only the filters chosen", () => {
    const d = { ...newExport("p1"), purpose: "  LDL-C attainment at 12 months  ", variable_codes: ["ldl_c"], index_year_from: "2026" };
    expect(validateExport(d)).toEqual({});
    expect(exportBody(d)).toMatchObject({
      purpose: "LDL-C attainment at 12 months", visit_codes: null, variable_codes: ["ldl_c"], cohort_filter: { index_year_from: 2026 },
    });
  });

  it("lists each variable once, by category", () => {
    const g = byCategory([
      { variable_code: "ldl_c", category: "Lipids" }, { variable_code: "ldl_c", category: "Lipids" },
      { variable_code: "sbp", category: "Vitals" }, { variable_code: "x", category: null },
    ]);
    expect(g.map(([c, i]) => [c, i.length])).toEqual([["Lipids", 1], ["Vitals", 1], ["Other", 1]]);
  });

  it("turns the API's absolute link into an API path", () => {
    expect(apiPathOf("http://localhost:8000/api/v1/exports/abc/file?expires=1&sig=x")).toBe("/exports/abc/file?expires=1&sig=x");
  });
});

describe("menu", () => {
  it("shows reports and exports to the right roles", () => {
    expect(navFor("nurse").map((n) => n.href)).toEqual(["/patients", "/follow-up"]);
    expect(navFor("research_coordinator").map((n) => n.href)).toEqual(["/patients", "/follow-up", "/data-quality", "/adjudication", "/exports"]);
    expect(navFor("clinician").map((n) => n.href)).not.toContain("/exports");
  });
});
