# CardioEMR web app

Next.js (App Router, TypeScript), responsive from phone to desktop. The browser talks only to this app's own
origin: `/api/v1/*` is passed through to the FastAPI backend (`CEMR_API_URL`), so the API needs no CORS.

## What is in it

| Page | Who | What |
|---|---|---|
| `/login`, `/auth/callback` | everyone | OpenID Connect sign-in (authorisation code + PKCE, no client secret) |
| `/select-centre` | users with more than one centre or role | choose where and as what you are working; one choice is picked automatically |
| `/patients` | assistant, nurse, clinician, coordinator, PI | search by name, patient ID or mobile; newest first |
| `/patients/new` | same | register; warns about a possible duplicate at this centre before creating a second record |
| `/patients/{id}` | same | header with allergies, details, consent (record and withdraw), current medicines, problem list, latest vitals, recent consultations, PCI procedures and clinical events; registries for clinician, coordinator and PI (start screening from a suggestion or for any registry, dismiss a suggestion); clinicians start or continue a consultation |
| `/patients/{id}/consultations/{eid}` | clinician writes and signs; nurse helps with the draft; others read | complaints, history, examination with vitals, NYHA/CCS/phenotype, diagnoses, medicines, plan and follow-up; saves itself while you type; the last visit, medicines, problems and latest results sit alongside (behind a fold on phones); a signed note is read-only and amended field by field with a reason |
| `/patients/{id}/registries/{eid}` | clinician, coordinator, PI (clinician or PI confirms eligibility and enrols) | screening: eligibility checklist from the protocol's criteria, research consent, registry baseline (HF, lipid or CAD; LVEF, LDL-C and Lp(a) filled in from the chart to check); once enrolled: visit schedule with windows and due or overdue visits, end of participation |
| `/patients/{id}/registries/{eid}/assessments/{aid}` | same; coordinator or PI locks, PI unlocks | the visit form built from the protocol's data dictionary: values filled from the chart are marked and left unverified; verify or query each value, change a saved value with a reason, mark not done or unknown, complete or record a missed visit; HF shows the four GDMT pillars against target dose with reasons, lipid shows LDL-C against ESC/EAS 2019 and LAI 2020 targets |
| `/patients/{id}/pci/{pid}` (`new` to record) | clinician records and edits; nurse, coordinator and PI read | PCI procedure (indication, access, imaging, physiology, support, contrast, complications) with each lesion (vessel, segment, ACC/AHA type, CTO, bifurcation with Medina, preparation, TIMI, residual stenosis, treatment) and its stents; saved lesions and stents cannot be removed, a final procedure is changed with a reason, a wrong one is marked entered in error |
| `/patients/{id}/events/{evid}` (`new` to report) | clinician, coordinator and nurse report; clinician or coordinator corrects | a clinical event (death, MI, stroke, HF hospitalisation, bleeding, stent thrombosis and others) with only the details its type needs; past history is kept apart and not counted as an outcome; the registry outcomes it opened and their status |
| `/adjudication` | clinician, coordinator, PI (clinician or PI decides) | the adjudication queue per protocol, by study code, with waiting and decided tabs; classify against the endpoint's system (UDMI-4, BARC, ARC-2, HF-ARC), mark in review, needs more data or not an event; a changed decision needs a reason, and nobody adjudicates an event they reported |
| `/patients/{id}/edit` | same | change details; needs a reason, refuses to overwrite someone else's newer edit |

Every request sends `X-Centre-Id` and `X-Acting-Role`; the API and row-level security decide what is allowed.
The app only hides what a role cannot use.

## Run it locally

```bash
cd web && npm install
CEMR_DEV_RESET=1 ./dev/run-local.sh     # database cemr_dev, sign-in server :9400, API :8000, app :3000
```

Open http://localhost:3000 and pick a test user (Dr A, Assistant A, Nurse A, Coordinator A, PI A at Pune; Dr B at
Mumbai). `dev/dev-idp.mjs` is a password-less sign-in server **for development and tests only**.

## Settings (build time)

| Variable | Meaning |
|---|---|
| `NEXT_PUBLIC_OIDC_AUTHORITY` | Identity provider issuer URL |
| `NEXT_PUBLIC_OIDC_CLIENT_ID` | Public client registered for the app (redirect `https://<host>/auth/callback`) |
| `NEXT_PUBLIC_OIDC_SCOPE` | Default `openid profile email` (add `offline_access` for refresh tokens) |
| `NEXT_PUBLIC_OIDC_AUDIENCE` | Only for providers that need an audience parameter |
| `CEMR_API_URL` | Backend base URL for the `/api/v1` pass-through (default `http://localhost:8000`) |

## Checks

```bash
npm run typecheck && npm test           # unit tests (vitest)
npm run build
npm run e2e                             # Playwright, against the running local stack
```
