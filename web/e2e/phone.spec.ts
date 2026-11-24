import { expect, test } from "@playwright/test";
import { registerPatient, signInAs } from "./helpers";

test("patient list and menu work at phone width", async ({ page }) => {
  await signInAs(page, "Nurse A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await expect(page.locator(".patients-table")).toBeHidden();
  await expect(page.locator(".patient-card").first()).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);

  await page.getByRole("button", { name: "Menu" }).click();
  await expect(page.locator("#mobile-menu").getByRole("button", { name: /Pune Main/ })).toBeVisible();
  await page.getByRole("button", { name: "Close" }).click();

  await page.locator(".patient-card", { hasText: "Ramesh Kulkarni" }).click();
  await expect(page.getByRole("heading", { name: "Ramesh Kulkarni" })).toBeVisible();
  const overflow2 = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow2).toBeLessThanOrEqual(0);
});

test("consultation fits a phone and keeps the record one tap away", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await registerPatient(page, "Asha");
  await page.getByRole("button", { name: "Start new consultation" }).click();
  await expect(page.getByRole("button", { name: "Save draft" })).toBeVisible();
  await expect(page.locator(".consult-aside")).toBeHidden();
  await page.getByText("Previous visit, medicines and results").click();
  await expect(page.locator(".summary-mobile").getByRole("heading", { name: "Latest results" })).toBeVisible();
  await page.getByRole("button", { name: "Chest pain" }).click();
  await page.getByRole("button", { name: "Add medicine" }).click();
  await page.getByLabel("Medicine").fill("amlo");
  await expect(page.getByRole("option", { name: /Amlodipine/ })).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});

test("registry visit form fits a phone", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await page.goto("/patients/10000000-0000-0000-0000-000000000003/registries/1b000000-0000-0000-0000-000000000034/assessments/1c000000-0000-0000-0000-000000000034");
  await expect(page.getByRole("button", { name: "Fill from chart" })).toBeVisible();
  await expect(page.locator(".var-row").first()).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(0);
});

test("PCI entry and the adjudication queue fit a phone", async ({ page }) => {
  await signInAs(page, "Dr A");
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await page.goto("/patients/10000000-0000-0000-0000-000000000003/pci/new");
  await expect(page.getByRole("heading", { name: "Record PCI" })).toBeVisible();
  await page.locator("#l1-vessel").selectOption("LAD");
  await page.getByRole("button", { name: "Add stent" }).click();
  await expect(page.locator("#l1-s2-dia")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);

  await page.goto("/adjudication");
  await expect(page.getByRole("heading", { name: "Adjudication" })).toBeVisible();
  await expect(page.getByLabel("Registry protocol")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});

test("reports and the export form fit a phone", async ({ page }) => {
  await signInAs(page, "Coordinator A", "/follow-up");
  await expect(page.getByRole("heading", { name: "Follow-up" })).toBeVisible();
  await expect(page.getByRole("heading", { name: /^Overdue/ })).toBeVisible();
  const noOverflow = async () => expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
  await noOverflow();
  await page.goto("/data-quality");
  await expect(page.getByText("required values filled")).toBeVisible();
  await noOverflow();
  await page.goto("/exports");
  await page.getByRole("button", { name: "Request export" }).click();
  await expect(page.getByLabel("Search variables")).toBeVisible();
  await noOverflow();
});
