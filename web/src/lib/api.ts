// Client for the CardioEMR API.  Every call carries the bearer token and, once
// a centre is chosen, X-Centre-Id and X-Acting-Role.  Errors come back as RFC
// 9457 problem documents and are thrown as ApiError.
import { API_BASE } from "./config";

export interface FieldError {
  field?: string;
  variable_code?: string;
  rule?: string;
  message?: string;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    public title: string,
    public detail?: string,
    public errors?: FieldError[],
    public current?: unknown,
  ) {
    super(title);
  }

  /** One line a person can act on. */
  get userMessage(): string {
    if (this.code === "VALIDATION_FAILED" && this.errors?.length) {
      return this.errors.map((e) => (e.field ? `${humanField(e.field)}: ${e.message}` : e.message)).join(". ");
    }
    if (this.code === "STALE_VERSION") return "Someone else changed this record while you were editing. Reload and try again.";
    if (this.code === "ROLE_NOT_HELD") return "You no longer hold this role at this centre.";
    if (this.status === 0) return "Cannot reach CardioEMR. Check the connection and try again.";
    return this.detail && this.status < 500 ? `${this.title}: ${this.detail}` : this.title;
  }
}

function humanField(field: string): string {
  const last = field.split(".").pop() ?? field;
  return last.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
}

export interface CallOptions {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  query?: Record<string, string | number | boolean | undefined | null>;
  body?: unknown;
  /** Adds an Idempotency-Key; pass the same key to retry the same POST safely. */
  idempotencyKey?: string;
  ifMatch?: string;
  changeReason?: string;
  signal?: AbortSignal;
}

export interface ApiContext {
  token: string;
  centreId?: string;
  role?: string;
}

export interface ApiResult<T> {
  data: T;
  etag: string | null;
}

export function buildUrl(path: string, query?: CallOptions["query"]): string {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== undefined && v !== null && v !== "") qs.set(k, String(v));
  }
  const s = qs.toString();
  return `${API_BASE}${path}${s ? `?${s}` : ""}`;
}

export function buildHeaders(ctx: ApiContext, opts: CallOptions): Headers {
  const h = new Headers({ Accept: "application/json, application/problem+json" });
  h.set("Authorization", `Bearer ${ctx.token}`);
  if (ctx.centreId) h.set("X-Centre-Id", ctx.centreId);
  if (ctx.role) h.set("X-Acting-Role", ctx.role);
  if (opts.body !== undefined) h.set("Content-Type", "application/json");
  if (opts.idempotencyKey) h.set("Idempotency-Key", opts.idempotencyKey);
  if (opts.ifMatch) h.set("If-Match", opts.ifMatch);
  if (opts.changeReason) h.set("X-Change-Reason", opts.changeReason);
  return h;
}

export async function parseProblem(res: Response): Promise<ApiError> {
  let body: Record<string, unknown> = {};
  try {
    body = await res.json();
  } catch {
    /* not JSON: keep the status */
  }
  return new ApiError(
    res.status,
    (body.code as string) ?? `HTTP_${res.status}`,
    (body.title as string) ?? res.statusText ?? "Request failed",
    body.detail as string | undefined,
    body.errors as FieldError[] | undefined,
    body.current,
  );
}

export async function call<T>(ctx: ApiContext, path: string, opts: CallOptions = {}): Promise<ApiResult<T>> {
  let res: Response;
  try {
    res = await fetch(buildUrl(path, opts.query), {
      method: opts.method ?? "GET",
      headers: buildHeaders(ctx, opts),
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
      signal: opts.signal,
      cache: "no-store",
      credentials: "omit",
    });
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
    throw new ApiError(0, "NETWORK", "Network error");
  }
  if (!res.ok) throw await parseProblem(res);
  const data = res.status === 204 ? (undefined as T) : ((await res.json()) as T);
  return { data, etag: res.headers.get("ETag") };
}

/** Fetches a file (e.g. an export) and returns it with the name the server gave it. */
export async function callFile(ctx: ApiContext, path: string): Promise<{ blob: Blob; filename: string | null; sha256: string | null }> {
  let res: Response;
  try {
    const h = buildHeaders(ctx, {});
    h.set("Accept", "*/*");
    res = await fetch(`${API_BASE}${path}`, { headers: h, cache: "no-store", credentials: "omit" });
  } catch {
    throw new ApiError(0, "NETWORK", "Network error");
  }
  if (!res.ok) throw await parseProblem(res);
  const cd = res.headers.get("Content-Disposition") ?? "";
  return { blob: await res.blob(), filename: /filename="([^"]+)"/.exec(cd)?.[1] ?? null, sha256: res.headers.get("X-Content-SHA256") };
}

/** The API path of an absolute or relative link the API returned (the part after /api/v1). */
export function apiPathOf(url: string): string {
  const i = url.indexOf(API_BASE);
  return i >= 0 ? url.slice(i + API_BASE.length) : url;
}

export function newIdempotencyKey(): string {
  return crypto.randomUUID().replace(/-/g, "");
}
