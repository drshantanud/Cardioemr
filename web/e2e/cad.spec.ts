import { expect, test, type Page } from "@playwright/test";
import { registerPatient, signInAs } from "./helpers";

test.describe.configure({ mode: "serial" });

const daysAgo = (n: number) => new Date(Date.now() - n * 86400000).toLocaleDateString("en-CA");
let patientUrl = "";

async function enrolInCad(page: Page) {
  await page.getByRole("button", { name: "Record consent" }).click();
  await page.getByLabel("Registry protocol").selectOption({ label: "CEMR-CAD v1" });
  await page.getByLabel("Form version").fill("ICF v1.0");
  await page.locator(".subpanel").getByRole("button", { name: "Record consent" }).click();
  await page.getByRole("button", { name: "Screen for a registry" }).click();
  await page.getByRole("button", { name: "Coronary artery disease registry" }).click();
  await expect(page.getByRole("heading", { name: "1. Eligibility" })).toBeVisible();
  const groups = page.locator(".criteria li");
  const n = await groups.count();
  for (let i = 0; i < n; i++) {
    const row = groups.nth(i);
    const include = (await row.locator(".badge").textContent()) === "Include";
    await row.getByRole("button", { name: include ? "Yes" : "No", exact: true }).click();
  }
  await page.getByRole("button", { name: "Confirm eligible" }).click();
  await page.locator("#cad-pres").selectOption("chronic_coronary_syndrome");
  await page.getByLabel("Index event date").fill(daysAgo(10));
  await page.getByRole("button", { name: "Enrol", exact: true }).click();
  await expect(page.locator(".patient-header").getByText("enrolled", { exact: true })).toBeVisible();
}

test("cardiologist records a PCI with two stents and reports an MI", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await registerPatient(page, "Suresh");
  patientUrl = page.url().replace(/\?.*$/, "");
  await enrolInCad(page);
  await page.goto(patientUrl);

  // PCI: one LAD lesion with two stents.
  await page.getByRole("link", { name: "Record PCI" }).click();
  await expect(page.getByRole("heading", { name: "Record PCI" })).toBeVisible();
  await page.getByRole("button", { name: "Save procedure" }).click();
  await expect(page.getByText("Some answers need attention.")).toBeVisible();
  await expect(page.getByText("Choose the indication")).toBeVisible();

  await page.getByLabel("Procedure date").fill(daysAgo(9));
  await page.getByLabel("Indication").selectOption("chronic_coronary_syndrome");
  await page.getByLabel("Intravascular imaging").selectOption("IVUS");
  await page.getByRole("button", { name: "None", exact: true }).first().click();      // complications: none
  await page.locator("#l1-vessel").selectOption("LAD");
  await page.locator("#l1-seg").fill("6");
  await page.locator("#l1-pre").fill("90");
  await page.locator("#l1-s1-dev").fill("Xience Sierra");
  await page.locator("#l1-s1-dia").fill("3.0");
  await page.locator("#l1-s1-len").fill("28");
  await page.getByRole("button", { name: "Add stent" }).click();
  await page.locator("#l1-s2-dev").fill("Xience Sierra");
  await page.locator("#l1-s2-dia").fill("2.75");
  await page.locator("#l1-s2-len").fill("18");
  await page.locator("#l1-finaltimi").selectOption("3");
  await page.locator("#l1-resid").fill("0");
  await page.getByRole("button", { name: "Save procedure" }).click();
  await expect(page.getByText("Lesion 1").first()).toBeVisible();
  await expect(page.getByText("LAD (6) · 90% → 0% · 2 stents")).toBeVisible();
  await expect(page.getByText(/Stent 2: Xience Sierra 2.75 × 18 mm/)).toBeVisible();

  // Editing a final procedure asks for a reason.
  await page.getByRole("button", { name: "Edit" }).click();
  await page.locator("#pci-contrast").fill("140");
  await page.getByRole("button", { name: "Save procedure" }).click();
  await expect(page.getByText("Give a reason for changing a recorded procedure.")).toBeVisible();
  await page.getByLabel("Reason for the change").fill("Contrast volume from the cath lab log");
  await page.getByRole("button", { name: "Save procedure" }).click();
  await expect(page.getByText("140 mL")).toBeVisible();

  // MI reported from the record; the CAD registry opens an MI outcome.
  await page.goto(patientUrl);
  await expect(page.getByText("LAD (6) · 90% → 0% · 2 stents")).toBeVisible();
  await page.getByRole("link", { name: "Report event" }).click();
  await page.locator("#ev-type").selectOption("mi");
  await page.locator("#ev-date").fill(daysAgo(2));
  await page.getByLabel("MI type (as reported)").selectOption("1");
  await page.getByLabel("Admitted to hospital").selectOption("yes");
  await page.locator("#ev-adm").fill(daysAgo(2));
  await page.getByLabel("Description").fill("Chest pain, troponin rise, anterior ST depression.");
  await page.getByRole("button", { name: "Report event" }).click();
  await expect(page.getByRole("heading", { name: /Myocardial infarction · type 1/ })).toBeVisible();
  const outcomes = page.locator(".card", { hasText: "Registry outcomes" });
  await expect(outcomes.getByText("CEMR-CAD").first()).toBeVisible();
  await expect(outcomes.getByText("Waiting").first()).toBeVisible();
  await expect(page.getByText("You reported this event, so another clinician or the PI adjudicates it.")).toBeVisible();
});

test("PI adjudicates the MI from the queue", async ({ page }) => {
  await signInAs(page, "PI A", "/adjudication");
  await expect(page.getByRole("heading", { name: "Adjudication" })).toBeVisible();
  await page.getByLabel("Registry protocol").selectOption({ label: "CEMR-CAD v1 · Coronary artery disease registry" });
  const item = page.locator(".adj-item").filter({ hasText: "Myocardial infarction" }).last();
  await expect(item).toBeVisible();
  await item.click();
  await expect(page.getByText("Chest pain, troponin rise, anterior ST depression.")).toBeVisible();
  await page.getByLabel(/Classification/).selectOption("1");
  await expect(page.getByText("Meets the endpoint")).toBeVisible();
  await page.getByRole("button", { name: "Save decision" }).click();
  await expect(page.getByText(/Saved: .*adjudicated/)).toBeVisible();

  await page.getByRole("button", { name: "Adjudicated", exact: true }).click();
  await page.locator(".adj-item").filter({ hasText: "Myocardial infarction" }).last().click();
  await expect(page.getByLabel("Reason for changing the decision")).toBeVisible();
});

test("nurse can report but not adjudicate", async ({ page }) => {
  await signInAs(page, "Nurse A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Adjudication" })).toHaveCount(0);
  await page.goto(patientUrl);
  await expect(page.getByRole("link", { name: "Report event" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Record PCI" })).toHaveCount(0);
});
