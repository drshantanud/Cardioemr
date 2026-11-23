import { expect, type Page } from "@playwright/test";

/** Signs in through the development sign-in server as one of the fixture users. */
export async function signInAs(page: Page, name: string, path = "/patients") {
  await page.goto(path);
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.getByRole("button", { name: new RegExp(`^${name}`) }).click();
}

export async function chooseRole(page: Page, role: string) {
  await expect(page.getByRole("heading", { name: "Choose where you are working" })).toBeVisible();
  await page.getByRole("button", { name: role }).click();
}

export function uniqueMobile(): string {
  return `98${String(Date.now()).slice(-8)}`;
}

/** A surname nobody else in the database has, so reruns do not trip the duplicate check. */
export function uniqueSurname(): string {
  return "Patil" + Array.from({ length: 5 }, () => String.fromCharCode(97 + Math.floor(Math.random() * 26))).join("");
}

/** Registers a fresh patient through the form and leaves the page on their overview. */
export async function registerPatient(page: Page, first = "Sunil"): Promise<string> {
  const surname = uniqueSurname();
  await page.goto("/patients/new");
  await page.getByLabel("First name").fill(first);
  await page.getByLabel("Last name").fill(surname);
  await page.getByRole("button", { name: "Age only" }).click();
  await page.getByLabel("Age in years").fill("61");
  await page.getByLabel("Sex").selectOption("male");
  await page.getByLabel("Mobile", { exact: true }).fill(uniqueMobile());
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("heading", { name: `${first} ${surname}` })).toBeVisible();
  return `${first} ${surname}`;
}
