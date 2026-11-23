import { expect, test } from "@playwright/test";
import { registerPatient, signInAs } from "./helpers";

test.describe.configure({ mode: "serial" });

test("cardiologist screens, takes consent, enrols in HF and starts the baseline visit", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await registerPatient(page, "Vijay");

  // Research consent from the overview.
  await page.getByRole("button", { name: "Record consent" }).click();
  await page.getByLabel("Registry protocol").selectOption({ label: "CEMR-HF v1" });
  await page.getByLabel("Form version").fill("ICF v1.0");
  await page.getByLabel("Language").fill("Marathi");
  await page.locator(".subpanel").getByRole("button", { name: "Record consent" }).click();
  await expect(page.getByText("CEMR-HF").first()).toBeVisible();

  // Screening.
  await page.getByRole("button", { name: "Screen for a registry" }).click();
  await page.getByRole("button", { name: "Heart failure" }).click();
  await expect(page.getByRole("heading", { name: "1. Eligibility" })).toBeVisible();
  const groups = page.locator(".criteria li");
  const n = await groups.count();
  for (let i = 0; i < n; i++) {
    const row = groups.nth(i);
    const include = (await row.locator(".badge").textContent()) === "Include";
    await row.getByRole("button", { name: include ? "Yes" : "No", exact: true }).click();
  }
  await page.getByRole("button", { name: "Confirm eligible" }).click();
  await expect(page.getByText("consent recorded")).toBeVisible();

  // HF baseline; LVEF suggests the phenotype.
  await page.getByLabel("HF status at enrolment").selectOption("prevalent");
  await page.getByLabel("Primary aetiology").selectOption("ischaemic");
  await page.getByLabel("Baseline LVEF (%)").fill("30");
  await expect(page.getByLabel("Baseline phenotype")).toHaveValue("HFrEF");
  await page.getByRole("button", { name: "Enrol", exact: true }).click();
  await expect(page.locator(".patient-header").getByText("enrolled", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Visits" })).toBeVisible();

  // Baseline visit: opened with chart values filled in.
  await page.locator(".schedule li", { hasText: "BL" }).getByRole("button", { name: "Start visit" }).click();
  await expect(page).toHaveURL(/\/assessments\//);
  await expect(page.getByText(/filled in and marked unverified/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "Guideline-directed therapy" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Aetiology" })).toBeVisible();

  await page.locator("#var-primary_aetiology").selectOption("ischaemic");
  await page.getByRole("button", { name: /^Save 1$/ }).click();
  await expect(page.getByText("Saved 1 value.")).toBeVisible();
  const row = page.locator(".var-row", { hasText: "Primary aetiology" });
  await expect(row.getByText("entered")).toBeVisible();
  await row.getByRole("button", { name: "Verify" }).click();
  await expect(row.getByText("verified", { exact: true })).toBeVisible();

  // Changing a saved value asks for a reason.
  await page.locator("#var-primary_aetiology").selectOption("hypertensive");
  await expect(page.getByLabel("Reason for changing saved values")).toBeVisible();
  await expect(page.getByRole("button", { name: /^Save 1$/ })).toBeDisabled();
  await page.getByLabel("Reason for changing saved values").fill("Echo report read again");
  await page.getByRole("button", { name: /^Save 1$/ }).click();
  await expect(page.getByText("Saved 1 value.")).toBeVisible();
  await expect(row.getByText("unverified")).toBeVisible();

  // Not complete while required values are missing.
  await expect(page.getByText(/Still required:/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Mark complete" })).toBeDisabled();
});

test("nurse sees the suggestion but cannot screen", async ({ page }) => {
  await signInAs(page, "Nurse A");
  await page.getByPlaceholder("Name, patient ID or mobile").fill("Ramesh");
  await page.getByRole("row", { name: /Ramesh Kulkarni/ }).click();
  await expect(page.getByRole("heading", { name: "Ramesh Kulkarni" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Screen for a registry" })).toHaveCount(0);
});

test("lipid baseline: the targets panel fills the form's risk-category questions", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await registerPatient(page, "Kavita");

  await page.getByRole("button", { name: "Record consent" }).click();
  await page.getByLabel("Registry protocol").selectOption({ label: "CEMR-LIPID v1" });
  await page.getByLabel("Form version").fill("ICF v1.0");
  await page.getByLabel("Language").fill("Hindi");
  await page.locator(".subpanel").getByRole("button", { name: "Record consent" }).click();

  await page.getByRole("button", { name: "Screen for a registry" }).click();
  await page.getByRole("button", { name: "Lipid management registry" }).click();
  await expect(page.getByRole("heading", { name: "1. Eligibility" })).toBeVisible();
  const groups = page.locator(".criteria li");
  const n = await groups.count();
  for (let i = 0; i < n; i++) {
    const row = groups.nth(i);
    const include = (await row.locator(".badge").textContent()) === "Include";
    await row.getByRole("button", { name: include ? "Yes" : "No", exact: true }).click();
  }
  await page.getByRole("button", { name: "Confirm eligible" }).click();
  await page.getByLabel("Prevention").selectOption("secondary");
  await page.getByLabel("Baseline LDL-C is").selectOption("on_treatment_at_enrolment");
  await page.getByRole("button", { name: "Established CAD" }).click();
  await page.getByLabel("Baseline LDL-C (mg/dL)").fill("120");
  await page.getByRole("button", { name: "Enrol", exact: true }).click();
  await expect(page.locator(".patient-header").getByText("enrolled", { exact: true })).toBeVisible();

  await page.locator(".schedule li", { hasText: "BL" }).getByRole("button", { name: "Start visit" }).click();
  await expect(page.getByRole("heading", { name: "LDL-C targets" })).toBeVisible();
  const risk = page.locator(".var-row", { hasText: "Set from the LDL-C targets panel" }).first();
  await expect(risk).toBeVisible();

  await page.getByLabel("Risk category under ESC_EAS_2019").selectOption("very_high");
  await page.getByRole("button", { name: "Save categories" }).click();
  await expect(page.getByText(/against <55 mg\/dL/)).toBeVisible();
  await expect(page.locator("#var-risk_category")).toHaveValue("very_high");
  await expect(page.locator("#row-ldl_target input")).toHaveValue("55");
});
