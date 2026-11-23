import { expect, test } from "@playwright/test";
import { signInAs, uniqueMobile, uniqueSurname } from "./helpers";

test.describe.configure({ mode: "serial" });

test("assistant signs in, lands on the patient list and finds a patient", async ({ page }) => {
  await signInAs(page, "Assistant A");
  await expect(page).toHaveURL(/\/patients$/);
  await expect(page.getByRole("heading", { name: "Patients" })).toBeVisible();
  await expect(page.getByText("Registered at Pune Main")).toBeVisible();
  await expect(page.getByRole("button", { name: /Pune Main/ })).toContainText("Clinic assistant");

  await page.getByPlaceholder("Name, patient ID or mobile").fill("98220 00001");
  const row = page.getByRole("row", { name: /Ramesh Kulkarni/ });
  await expect(row).toBeVisible();
  await expect(page.getByRole("row")).toHaveCount(2);   // header + one match
  await row.click();

  await expect(page.getByRole("heading", { name: "Ramesh Kulkarni" })).toBeVisible();
  await expect(page.getByText("PUN1-000001").first()).toBeVisible();
  await expect(page.getByText("Clinical care")).toBeVisible();
  // Assistants do not see registry enrolment.
  await expect(page.getByRole("heading", { name: "Registries" })).toHaveCount(0);
});

test("register a patient, catch a duplicate, then edit with a reason", async ({ page }) => {
  const mobile = uniqueMobile();
  const surname = uniqueSurname();
  const fullName = `Savitri ${surname}`;
  await signInAs(page, "Assistant A", "/patients/new");
  await expect(page.getByRole("heading", { name: "Register patient" })).toBeVisible();

  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Enter the first name")).toBeVisible();

  await page.getByLabel("First name").fill("Savitri");
  await page.getByLabel("Last name").fill(surname);
  await page.getByRole("button", { name: "Age only" }).click();
  await page.getByLabel("Age in years").fill("67");
  await page.getByLabel("Sex").selectOption("female");
  await page.getByLabel("Mobile", { exact: true }).fill(mobile);
  await page.getByLabel("City / town").fill("Pune");
  await page.getByLabel("State").selectOption("MH");
  await page.getByRole("button", { name: "Save" }).click();

  await expect(page.getByText(/Registered as/)).toBeVisible();
  await expect(page.getByRole("heading", { name: fullName })).toBeVisible();
  const code = (await page.locator(".patient-header .mono").first().textContent())!;
  expect(code).toMatch(/^PUN1-\d{6}$/);

  // Same mobile again: the app warns before creating a second record.
  await page.goto("/patients/new");
  await page.getByLabel("First name").fill("Savitri");
  await page.getByRole("button", { name: "Age only" }).click();
  await page.getByLabel("Age in years").fill("67");
  await page.getByLabel("Sex").selectOption("female");
  await page.getByLabel("Mobile", { exact: true }).fill(mobile);
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("This may be a patient already registered here.")).toBeVisible();
  await expect(page.getByText(code)).toBeVisible();
  await page.getByRole("link", { name: "Open" }).click();
  await expect(page.getByRole("heading", { name: fullName })).toBeVisible();

  // Edit needs a reason.
  await page.getByRole("link", { name: "Edit details" }).click();
  await page.getByLabel("City / town").fill("Satara");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Say briefly why the details are changing")).toBeVisible();
  await page.getByLabel("Reason for change").fill("Moved to Satara");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("heading", { name: fullName })).toBeVisible();
  await expect(page.getByText(/Satara/)).toBeVisible();
});

test("cardiologist sees registries; Mumbai sees nothing of Pune", async ({ page, context }) => {
  await signInAs(page, "Dr A");
  await page.getByPlaceholder("Name, patient ID or mobile").fill("Ramesh");
  await page.getByRole("row", { name: /Ramesh Kulkarni/ }).click();
  await expect(page.getByRole("heading", { name: "Registries" })).toBeVisible();
  await expect(page.getByText("HF registry")).toBeVisible();
  const puneUrl = page.url();

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("heading", { name: "You have signed out" })).toBeVisible();
  await context.clearCookies();

  await signInAs(page, "Dr B");
  await expect(page.getByText("Registered at Mumbai Cardiology")).toBeVisible();
  await page.getByPlaceholder("Name, patient ID or mobile").fill("PUN1");
  await expect(page.getByText(/No patient matches/)).toBeVisible();
  await page.goto(puneUrl);
  await expect(page.getByText("No patient with this ID is registered at this centre.")).toBeVisible();
});

test("a sign-in with no CardioEMR account is told so", async ({ page }) => {
  await signInAs(page, "No account");
  await expect(page.getByText(/there is no active CardioEMR account for you/)).toBeVisible();
});
