import { expect, test } from "@playwright/test";
import { registerPatient, signInAs } from "./helpers";

test.describe.configure({ mode: "serial" });

test("cardiologist writes, prescribes, signs and amends a consultation", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  const name = await registerPatient(page);

  // An allergy recorded on the overview shows on the consultation and blocks the drug.
  await page.getByRole("button", { name: "Add allergy" }).click();
  await page.getByLabel("Allergen").fill("Atenolol");
  await page.locator(".subpanel").getByRole("button", { name: "Add allergy" }).click();
  await expect(page.getByText("Allergy: Atenolol")).toBeVisible();

  await page.getByRole("button", { name: "Start new consultation" }).click();
  await expect(page).toHaveURL(/\/consultations\//);
  await expect(page.getByRole("heading", { name })).toBeVisible();
  await expect(page.getByText("Allergy: Atenolol")).toBeVisible();

  await page.getByRole("button", { name: "Dyspnoea" }).click();
  await page.getByLabel("Dyspnoea duration", { exact: true }).fill("3");
  await page.getByLabel("Dyspnoea duration unit").selectOption("weeks");
  await page.getByRole("button", { name: "Pedal oedema" }).click();
  await page.getByLabel("History of present illness").fill("Breathless on climbing one flight for 3 weeks.");

  await page.getByRole("button", { name: "Record vitals" }).click();
  await page.getByLabel("Systolic (mmHg)").fill("128");
  await page.getByLabel("Diastolic (mmHg)").fill("78");
  await page.getByLabel("Heart rate (/min)").fill("84");
  await page.getByLabel("Weight (kg)").fill("72");
  await page.locator(".subpanel").getByRole("button", { name: "Record vitals" }).click();
  await expect(page.locator(".consult-main").getByText(/BP 128\/78/)).toBeVisible();

  await page.getByLabel("NYHA class").selectOption("II");
  await page.getByLabel("HF phenotype").selectOption("HFrEF");
  await page.getByRole("button", { name: "Add diagnosis" }).click();
  await page.getByLabel("Diagnosis", { exact: true }).selectOption("DX_HF");
  await page.locator(".subpanel").getByRole("button", { name: "Add diagnosis" }).click();
  await expect(page.getByText(/eligible to screen for the HF registry/)).toBeVisible();

  // Prescribe: atenolol is refused for the allergy, bisoprolol goes through.
  await page.getByRole("button", { name: "Add medicine" }).click();
  await page.getByLabel("Medicine").fill("atenol");
  await page.getByRole("option", { name: /Atenolol/ }).click();
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByText("Recorded allergy: Atenolol")).toBeVisible();
  await page.getByRole("button", { name: "change medicine" }).click();
  await page.getByLabel("Medicine").fill("bisop");
  await page.getByRole("option", { name: /Bisoprolol/ }).click();
  await page.getByLabel("Strength per tablet (mg)").fill("1.25");
  await page.getByLabel("How often").selectOption("OD");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.locator(".med-item", { hasText: "Bisoprolol" })).toBeVisible();

  await page.getByLabel(/^Plan:/).fill("Up-titrate bisoprolol at next visit. Echo.");
  await page.getByRole("button", { name: "Save draft" }).click();
  await expect(page.getByText(/Saved/)).toBeVisible();

  await page.getByRole("button", { name: "Sign", exact: true }).click();
  await page.getByRole("button", { name: "Sign and lock" }).click();
  await expect(page.locator(".consult-head").getByText("signed", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Save draft" })).toHaveCount(0);
  await expect(page.getByText("Started: Bisoprolol 1.25 mg · 1 tablet OD")).toBeVisible();

  // Amend the plan with a reason; the original stays visible in the history.
  const plan = page.locator(".readonly-field", { hasText: "Plan: investigations" });
  await plan.getByRole("button", { name: "Amend" }).click();
  await page.getByLabel(/^Amended Plan/).fill("Up-titrate bisoprolol at next visit. Echo and NT-proBNP.");
  await page.getByLabel("Reason for amendment").fill("Forgot to add NT-proBNP");
  await page.getByRole("button", { name: "Save amendment" }).click();
  await expect(page.getByText("Up-titrate bisoprolol at next visit. Echo and NT-proBNP.")).toBeVisible();
  await expect(page.getByText(/Amended 1×/)).toBeVisible();

  // Back on the overview: medicine, problem and vitals are there.
  await page.getByRole("link", { name: /PUN1-/ }).click();
  await expect(page.locator(".med-item", { hasText: "Bisoprolol" })).toBeVisible();
  await expect(page.getByText("Heart failure").first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Start follow-up consultation" })).toBeVisible();
});

test("nurse can open a patient but cannot start a consultation or prescribe", async ({ page }) => {
  await signInAs(page, "Nurse A");
  await page.getByPlaceholder("Name, patient ID or mobile").fill("Ramesh");
  await page.getByRole("row", { name: /Ramesh Kulkarni/ }).click();
  await expect(page.getByRole("heading", { name: "Ramesh Kulkarni" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Start .*consultation/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Add medicine" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Record vitals" })).toBeVisible();
});
