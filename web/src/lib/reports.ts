import type { FollowUpItem } from "./types";

/** How far the visit window is from today, in words. */
export function closesText(i: Pick<FollowUpItem, "status" | "days_until_window_closes" | "window_opens">, today: string): string {
  const d = i.days_until_window_closes;
  if (i.status === "overdue") return `window closed ${-d} day${d === -1 ? "" : "s"} ago`;
  if (i.status === "not_due") {
    const opens = Math.round((Date.parse(i.window_opens) - Date.parse(today)) / 86400000);
    return `opens in ${opens} day${opens === 1 ? "" : "s"}`;
  }
  return d === 0 ? "window closes today" : `window closes in ${d} day${d === 1 ? "" : "s"}`;
}
