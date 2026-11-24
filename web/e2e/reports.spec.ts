import { expect, test } from "@playwright/test";
import { signInAs } from "./helpers";

test.describe.configure({ mode: "serial" });
const CAD = "CEMR-CAD v1 · Coronary artery disease registry";

test("nurse sees who is due or overdue for follow-up", async ({ page }) => {
  await signInAs(page, "Nurse A", "/follow-up");
  await expect(page.getByRole("heading", { name: "Follow-up" })).toBeVisible();
  await page.getByLabel("Registry protocol").selectOption({ label: CAD });
  const overdue = page.locator(".card", { has: page.getByRole("heading", { name: /^Overdue/ }) });
  await expect(overdue.getByText("Vasant Joshi").first()).toBeVisible();
  await expect(overdue.getByText(/window closed \d+ days ago/).first()).toBeVisible();
  await expect(overdue.getByRole("link", { name: /Call 98220 00003/ }).first()).toHaveAttribute("href", "tel:9822000003");
  await page.getByRole("button", { name: "60 days" }).click();
  await expect(page.getByRole("heading", { name: /Opening in the next 60 days/ })).toBeVisible();
  await expect(page.getByRole("link", { name: "Missing data" })).toHaveCount(0);
});

test("coordinator finds the visits with missing values and opens one", async ({ page }) => {
  await signInAs(page, "Coordinator A", "/data-quality");
  await expect(page.getByRole("heading", { name: "Missing data" })).toBeVisible();
  await page.getByLabel("Registry protocol").selectOption({ label: CAD });
  await page.getByLabel("Visit", { exact: true }).selectOption({ label: "Baseline" });
  await expect(page.getByText("required values filled")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Most often missing" })).toBeVisible();
  await page.getByRole("link", { name: /PUN1-000003 · Baseline/ }).click();
  await expect(page).toHaveURL(/\/assessments\/1c000000-0000-0000-0000-000000000034/);
  await expect(page.getByText(/Still required:/)).toBeVisible();
});

test("coordinator requests an export, the PI approves it, the coordinator downloads it", async ({ browser }) => {
  const rc = await browser.newPage();
  await signInAs(rc, "Coordinator A", "/exports");
  await expect(rc.getByRole("heading", { name: "Exports", exact: true })).toBeVisible();
  await rc.getByRole("button", { name: "Request export" }).click();
  await rc.getByLabel("Registry protocol").selectOption({ label: CAD });
  await rc.getByRole("button", { name: "Send for approval" }).click();
  await expect(rc.getByText("Choose at least one variable")).toBeVisible();
  const purpose = `Baseline characteristics table ${Date.now()}`;
  await rc.getByLabel("Purpose").fill(purpose);
  await rc.getByLabel("Search variables").fill("presentation");
  await rc.getByLabel("Presentation at index event").check();
  await rc.getByRole("button", { name: "Baseline", exact: true }).click();
  await rc.getByRole("button", { name: "Send for approval" }).click();
  await expect(rc.getByText("Sent for approval.")).toBeVisible();
  const mine = rc.locator(".export-job", { hasText: purpose });
  await expect(mine.getByText("Waiting for approval")).toBeVisible();
  await expect(mine.getByText("Another principal investigator must approve it.")).toBeVisible();

  const pi = await browser.newPage();
  await signInAs(pi, "PI A", "/exports");
  const job = pi.locator(".export-job", { hasText: purpose });
  await job.getByRole("button", { name: "Review" }).click();
  await expect(job.getByText(/Variables:/)).toBeVisible();
  await job.getByRole("button", { name: "Approve" }).click();
  await expect(job.getByText(/Ready|Preparing|Approved/).first()).toBeVisible();

  await rc.reload();
  await expect(mine.getByText("Ready")).toBeVisible({ timeout: 15000 });
  const [file] = await Promise.all([rc.waitForEvent("download"), mine.getByRole("button", { name: "Download" }).click()]);
  expect(file.suggestedFilename()).toMatch(/^CEMR-CAD-export-.*\.zip$/);
});
