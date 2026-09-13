// Attendance summary digest — TWO daily runs for ALL tenant orgs at once.
//
// Scheduled via pg_cron (service role) at 04:30 and 13:30 UTC, i.e.
// 9:30am and 6:30pm PKT (Asia/Karachi = UTC+5, no DST). The morning job calls
// this with ?slot=morning, the evening job with ?slot=evening.
//
// For every org that turned org.attendance_summary on, this emails the
// org.attendance_summary_emails recipients a "counts + exceptions" summary for
// today (PKT). One function, one loop over all orgs — not one job per org.
//
// Mirrors the facility-reminders / asset-maintenance-reminders functions.

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GMAIL_USER = Deno.env.get("GMAIL_USER")!;
const GMAIL_PASS = Deno.env.get("GMAIL_APP_PASSWORD")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const enc = (s: string) => encodeURIComponent(s);
const H = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function rest(path: string): Promise<any[]> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    });
    if (!r.ok) return [];
    return await r.json();
  } catch (_) {
    return [];
  }
}

// "HH:MM" -> minutes since midnight (attendance/shift times are stored this way).
function toMin(hhmm?: string | null): number | null {
  if (!hhmm) return null;
  const p = String(hhmm).split(":");
  if (p.length < 2) return null;
  const h = parseInt(p[0], 10), m = parseInt(p[1], 10);
  if (isNaN(h) || isNaN(m)) return null;
  return h * 60 + m;
}
const hhmm = (min: number) =>
  `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;

const ENABLED = (v: unknown) =>
  ["true", "1", "on", "yes"].includes(String(v).toLowerCase());

// Today in PKT (UTC+5): its date, weekday (Sun=0..Sat=6), and minutes-of-day.
function pktNow() {
  const shifted = new Date(Date.now() + 5 * 60 * 60000);
  return {
    date: shifted.toISOString().slice(0, 10),
    weekday: shifted.getUTCDay(),
    nowMin: shifted.getUTCHours() * 60 + shifted.getUTCMinutes(),
  };
}

type Emp = { id: string; full_name: string; employee_code?: string; branch_id?: string; shift_id?: string };

Deno.serve(async (req) => {
  if (CRON_SECRET && req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  const url = new URL(req.url);
  const slot = (url.searchParams.get("slot") || "morning").toLowerCase() === "evening"
    ? "evening"
    : "morning";
  const { date, weekday } = pktNow();

  const toggles = await rest(`app_config?key=eq.org.attendance_summary&select=org_id,value`);
  const orgs = toggles.filter((t) => ENABLED(t.value)).map((t) => t.org_id as string);
  if (!orgs.length) {
    return new Response(JSON.stringify({ slot, orgs: 0, sent: 0 }), {
      headers: { "content-type": "application/json" },
    });
  }

  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_USER, password: GMAIL_PASS },
    },
  });

  let sent = 0;
  try {
    for (const org of orgs) {
      const [em] = await rest(
        `app_config?key=eq.org.attendance_summary_emails&org_id=eq.${enc(org)}&select=value&limit=1`,
      );
      const emails = String(em?.value ?? "")
        .split(/[,\n;]/).map((s) => s.trim()).filter(Boolean);
      if (!emails.length) continue;

      const [rd] = await rest(
        `app_config?key=eq.org.weekly_rest_day&org_id=eq.${enc(org)}&select=value&limit=1`,
      );
      const restDay = rd?.value != null && rd.value !== "" ? parseInt(String(rd.value), 10) : null;
      const isRestToday = restDay !== null && weekday === restDay;

      const emps = await rest(
        `hr_employees?org_id=eq.${enc(org)}&status=eq.active` +
          `&select=id,full_name,employee_code,branch_id,shift_id`,
      ) as Emp[];
      if (!emps.length) continue;

      const shifts = await rest(`hr_shifts?org_id=eq.${enc(org)}&select=id,start_time`);
      const shiftStart: Record<string, number | null> = {};
      for (const s of shifts) shiftStart[s.id] = toMin(s.start_time);

      const branches = await rest(`branches?org_id=eq.${enc(org)}&select=id,name`);
      const bName: Record<string, string> = {};
      for (const b of branches) bName[b.id] = b.name;

      const att = await rest(
        `hr_attendance?org_id=eq.${enc(org)}&att_date=eq.${date}` +
          `&select=employee_id,status,check_in,check_out`,
      );
      const byEmp: Record<string, any> = {};
      for (const a of att) byEmp[a.employee_id] = a;

      // Classify every active employee for today.
      let present = 0, late = 0, notIn = 0, leave = 0, holiday = 0, absent = 0, notOut = 0;
      const lateList: { e: Emp; cin: number; mins: number }[] = [];
      const notInList: Emp[] = [];
      const absentList: Emp[] = [];
      const notOutList: Emp[] = [];

      for (const e of emps) {
        const a = byEmp[e.id];
        const st = a?.status as string | undefined;
        const cin = toMin(a?.check_in);
        const worked = cin !== null;

        if (st === "leave") { leave++; continue; }
        if (st === "holiday") { holiday++; continue; }
        // Weekly rest (explicit status, or the org rest weekday with no check-in):
        // not expected to attend, so never counted as absent.
        if (st === "rest_day" || (isRestToday && !worked)) continue;

        if (worked) {
          present++;
          const threshold = shiftStart[e.shift_id ?? ""] ?? 570; // fallback 9:30
          if (cin! > threshold) { late++; lateList.push({ e, cin: cin!, mins: cin! - threshold }); }
          if (!a?.check_out) { notOut++; notOutList.push(e); }
        } else {
          if (slot === "morning") { notIn++; notInList.push(e); }
          else { absent++; absentList.push(e); }
        }
      }

      const br = (e: Emp) => e.branch_id && bName[e.branch_id] ? bName[e.branch_id] : "—";
      const nm = (e: Emp) => e.full_name + (e.employee_code ? ` (${e.employee_code})` : "");

      const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
      const prettyDate = (() => {
        const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(date)!;
        return `${parseInt(m[3],10)} ${MONTHS[parseInt(m[2],10)-1]} ${m[1]}`;
      })();

      // Build the counts strip + exception tables per slot.
      let subject: string, headline: string, chips: [string, number][], sections: [string, Emp[] | { e: Emp; cin: number; mins: number }[], boolean][];

      if (slot === "morning") {
        subject = `Morning attendance — ${present} in, ${notIn} not in yet · ${prettyDate}`;
        headline = `Morning attendance · as of 9:30am`;
        chips = [["In", present], ["Late", late], ["Not in yet", notIn], ["On leave", leave]];
        sections = [
          ["Late arrivals", lateList, true],
          ["Not in yet", notInList, false],
        ];
      } else {
        subject = `Daily attendance — ${present} present, ${absent} absent · ${prettyDate}`;
        headline = `Daily attendance · end of day`;
        chips = [["Present", present], ["Absent", absent], ["Late", late], ["On leave", leave], ["Holiday", holiday]];
        sections = [
          ["Absent", absentList, false],
          ["Still not checked out", notOutList, false],
        ];
      }

      const chipsHtml = chips.map(([l, n]) =>
        `<span style="display:inline-block;margin:0 10px 6px 0;padding:6px 12px;border-radius:999px;` +
        `background:#f1f5ff;font-size:13px"><b>${n}</b> <span style="color:#667">${H(l)}</span></span>`
      ).join("");

      let bodyHtml = "";
      let bodyText = "";
      for (const [title, list, isLate] of sections) {
        if (!list.length) continue;
        let rows = "";
        let text = "";
        if (isLate) {
          for (const it of (list as { e: Emp; cin: number; mins: number }[])) {
            rows += `<tr><td style="padding:6px 8px;border-top:1px solid #eee">${H(nm(it.e))}</td>` +
              `<td style="padding:6px 8px;border-top:1px solid #eee;color:#888">${H(br(it.e))}</td>` +
              `<td style="padding:6px 8px;border-top:1px solid #eee;text-align:right;color:#c0392b">` +
              `in ${hhmm(it.cin)} · +${it.mins}m</td></tr>`;
            text += `- ${nm(it.e)} [${br(it.e)}] in ${hhmm(it.cin)} (+${it.mins}m)\n`;
          }
        } else {
          for (const e of (list as Emp[])) {
            rows += `<tr><td style="padding:6px 8px;border-top:1px solid #eee">${H(nm(e))}</td>` +
              `<td style="padding:6px 8px;border-top:1px solid #eee;color:#888" colspan="2">${H(br(e))}</td></tr>`;
            text += `- ${nm(e)} [${br(e)}]\n`;
          }
        }
        bodyHtml +=
          `<h3 style="margin:16px 0 4px;font-size:15px">${H(title)} <span style="color:#888">(${list.length})</span></h3>` +
          `<table style="width:100%;border-collapse:collapse;font-size:14px"><tbody>${rows}</tbody></table>`;
        bodyText += `\n${title} (${list.length}):\n${text}`;
      }
      if (!bodyHtml) {
        bodyHtml = `<p style="color:#2e7d32;margin:16px 0">No exceptions — all clear.</p>`;
        bodyText = "\nNo exceptions — all clear.\n";
      }

      const html =
        `<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:640px">` +
        `<h2 style="margin:0 0 2px">${H(headline)}</h2>` +
        `<p style="color:#666;margin:0 0 12px">${prettyDate}</p>` +
        `<div style="margin:0 0 4px">${chipsHtml}</div>` +
        bodyHtml +
        `<p style="color:#999;font-size:12px;margin-top:16px">Opstation · HR · Attendance</p></div>`;

      const text =
        `${headline} — ${prettyDate}\n` +
        chips.map(([l, n]) => `${l}: ${n}`).join("  ·  ") + "\n" +
        bodyText;

      await client.send({
        from: GMAIL_USER,
        to: emails,
        subject,
        content: text,
        html,
      });
      sent++;
    }
  } finally {
    await client.close();
  }

  return new Response(JSON.stringify({ slot, orgs: orgs.length, sent }), {
    headers: { "content-type": "application/json" },
  });
});
