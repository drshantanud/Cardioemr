import { expect, test } from "@playwright/test";
import { signInAs } from "./helpers";

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
