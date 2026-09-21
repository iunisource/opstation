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

// Read the `role` claim from a JWT payload WITHOUT verifying its signature —
// safe here because the gateway (verify_jwt) has already validated it. Returns
// "service_role" / "anon" for the platform keys, "authenticated" for a user.
function jwtRole(token: string): string {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return "";
    let b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    b64 += "=".repeat((4 - (b64.length % 4)) % 4);
    const payload = JSON.parse(atob(b64));
    return String(payload.role ?? "");
  } catch (_) {
    return "";
  }
}

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

// CORS — the manual "Send test now" call comes from the browser, so preflight
// and the actual response both need these. Cron (server-to-server) ignores them.
const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  // Params come from the query string (cron) OR a JSON body (manual invoke()).
  let body: any = {};
  try { body = await req.json(); } catch (_) { /* GET / no body */ }
  const manualOrg = (url.searchParams.get("org") || body.org || "").trim() || null;
  const slotParam = String(url.searchParams.get("slot") || body.slot || "").toLowerCase();

  // Auth. The scheduled (all-org) sweep is authorized by EITHER a Bearer
  // service-role key (how the other reminder crons call in) OR the shared
  // x-cron-secret. A manual "Send test now" from the app instead carries the
  // caller's Supabase JWT — accept it if it resolves to a real user, and scope
  // that run to the one org they passed.
  const authHeader = req.headers.get("Authorization") || "";
  const bearer = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  // The gateway (verify_jwt) has already authenticated whoever got this far, so
  // the only thing we decide here is scope. A real end-user's token decodes to
  // role "authenticated" — that's the manual, single-org "Send test now". Any
  // other authorized caller (the cron's service / anon / secret key, whatever
  // its format) runs the full scheduled sweep. The shared x-cron-secret is also
  // accepted as a cron path for setups that use it.
  const isUser = jwtRole(bearer) === "authenticated";
  const cronOk = (bearer !== "" && !isUser) ||
                 (CRON_SECRET !== "" && req.headers.get("x-cron-secret") === CRON_SECRET);
  let manualOk = false;
  if (!cronOk && manualOrg && bearer !== "") {
    try {
      const ur = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        headers: { apikey: SERVICE_KEY, Authorization: authHeader },
      });
      manualOk = ur.ok;
    } catch (_) { manualOk = false; }
  }
  if (!cronOk && !manualOk) {
    return new Response("forbidden", { status: 403, headers: CORS });
  }
  const isManual = !cronOk && manualOk;

  const { date, weekday, nowMin } = pktNow();
  // Manual test picks the slot from the current PKT time unless one is given.
  const slot = (slotParam === "evening" || slotParam === "morning")
    ? slotParam
    : (isManual ? (nowMin >= 13 * 60 + 30 ? "evening" : "morning") : "morning");

  let orgs: string[];
  if (manualOrg) {
    // Manual test: just this org, and don't require the toggle to be on so it
    // can be verified before enabling the schedule.
    orgs = [manualOrg];
  } else {
    const toggles = await rest(`app_config?key=eq.org.attendance_summary&select=org_id,value`);
    orgs = toggles.filter((t) => ENABLED(t.value)).map((t) => t.org_id as string);
  }
  if (!orgs.length) {
    return json({ slot, orgs: 0, sent: 0 });
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
  let recipients = 0;   // for the manual test response
  let sendError = "";   // for the manual test response
  try {
    for (const org of orgs) {
      const [em] = await rest(
        `app_config?key=eq.org.attendance_summary_emails&org_id=eq.${enc(org)}&select=value&limit=1`,
      );
      const emails = String(em?.value ?? "")
        .split(/[,\n;]/).map((s) => s.trim()).filter(Boolean);
      if (!emails.length) continue;
      recipients = emails.length;

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
      const presentList: Emp[] = []; // everyone who worked — the evening register

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
          presentList.push(e);
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
          // Full register: everyone who worked today, with their actual times —
          // the evening email is the day's record, not just its exceptions.
          ["Day register", presentList, false],
        ];
      }

      // Colour a count chip by what it represents, so the strip reads at a glance.
      const chipColor = (l: string): [string, string] => {
        const k = l.toLowerCase();
        if (k.includes("present") || k === "in") return ["#e7f6ec", "#1e7e34"];
        if (k.includes("absent")) return ["#fdecea", "#c0392b"];
        if (k.includes("late") || k.includes("not in")) return ["#fff6e5", "#b9770e"];
        if (k.includes("leave")) return ["#eaf1ff", "#2b5fd0"];
        if (k.includes("holiday")) return ["#eef0f4", "#5a6172"];
        return ["#f1f5ff", "#334"];
      };
      const chipsHtml = chips.map(([l, n]) => {
        const [bg, fg] = chipColor(l);
        return `<span style="display:inline-block;margin:0 8px 8px 0;padding:7px 13px;border-radius:999px;` +
          `background:${bg};color:${fg};font-size:13px"><b style="font-size:15px">${n}</b>&nbsp; ${H(l)}</span>`;
      }).join("");

      const sectionAccent = (title: string): string => {
        const k = title.toLowerCase();
        if (k.includes("absent")) return "#c0392b";
        if (k.includes("late") || k.includes("not in")) return "#b9770e";
        if (k.includes("checked out") || k.includes("still")) return "#2b5fd0";
        return "#667";
      };
      const th = (label: string, align = "left") =>
        `<th style="text-align:${align};padding:7px 10px;font-size:11px;font-weight:600;color:#8a94a6;` +
        `border-bottom:2px solid #e6e9f0;text-transform:uppercase;letter-spacing:.3px">${label}</th>`;
      const td = (v: string, extra = "") =>
        `<td style="padding:8px 10px;border-bottom:1px solid #eef0f4;${extra}">${v}</td>`;
      const dash = `<span style="color:#c3c8d2">—</span>`;

      let bodyHtml = "";
      let bodyText = "";
      for (const [title, list, isLate] of sections) {
        if (!list.length) continue;
        let rows = "";
        let text = "";
        // Unify late and non-late rows: every row shows Employee, Branch, In, Out.
        const items = isLate
          ? (list as { e: Emp; cin: number; mins: number }[])
          : (list as Emp[]).map((e) => ({ e, cin: null as number | null, mins: 0 }));
        for (const it of items) {
          const e = it.e;
          const a = byEmp[e.id];
          const cin = toMin(a?.check_in);
          const cout = toMin(a?.check_out);
          const inCell = cin !== null
            ? (isLate
                ? `<span style="color:#c0392b;font-weight:600">${hhmm(cin)}</span> <span style="color:#c0392b;font-size:12px">+${it.mins}m</span>`
                : hhmm(cin))
            : dash;
          const outCell = cout !== null ? hhmm(cout) : dash;
          rows +=
            `<tr>${td(H(nm(e)), "font-weight:500")}${td(H(br(e)), "color:#8a94a6")}` +
            `${td(inCell, "text-align:right;white-space:nowrap")}${td(outCell, "text-align:right")}</tr>`;
          text += `- ${nm(e)}  [${br(e)}]  in ${cin !== null ? hhmm(cin) : "—"}  out ${cout !== null ? hhmm(cout) : "—"}\n`;
        }
        bodyHtml +=
          `<h3 style="margin:20px 0 6px;font-size:15px;color:#2d3340">` +
          `<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${sectionAccent(title)};margin-right:8px"></span>` +
          `${H(title)} <span style="color:#98a0b0;font-weight:500">(${list.length})</span></h3>` +
          `<table style="width:100%;border-collapse:collapse;font-size:14px">` +
          `<thead><tr>${th("Employee")}${th("Branch")}${th("Time In", "right")}${th("Time Out", "right")}</tr></thead>` +
          `<tbody>${rows}</tbody></table>`;
        bodyText += `\n${title} (${list.length}):\n${text}`;
      }
      if (!bodyHtml) {
        bodyHtml = `<div style="margin:18px 0;padding:14px 16px;background:#e7f6ec;border-radius:10px;color:#1e7e34;font-size:14px">✅ No exceptions — everyone is accounted for.</div>`;
        bodyText = "\nNo exceptions — everyone is accounted for.\n";
      }

      const html =
        `<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:660px;margin:0 auto;` +
        `padding:22px 24px;background:#ffffff;border:1px solid #eceef3;border-radius:14px;color:#2d3340">` +
        `<h2 style="margin:0 0 2px;font-size:20px">${H(headline)}</h2>` +
        `<p style="color:#8a94a6;margin:0 0 16px;font-size:13px">${prettyDate}</p>` +
        `<div style="margin:0 0 6px">${chipsHtml}</div>` +
        bodyHtml +
        `<p style="color:#aab0bd;font-size:12px;margin-top:22px;border-top:1px solid #eef0f4;padding-top:12px">Opstation · HR · Attendance</p></div>`;

      const text =
        `${headline} — ${prettyDate}\n` +
        chips.map(([l, n]) => `${l}: ${n}`).join("  ·  ") + "\n" +
        bodyText;

      try {
        await client.send({
          from: GMAIL_USER,
          to: emails,
          subject,
          content: text,
          html,
        });
        sent++;
      } catch (e) {
        sendError = String(e);
        if (!isManual) throw e; // cron: preserve original fail-loud behaviour
      }
    }
  } finally {
    await client.close();
  }

  return json({ slot, orgs: orgs.length, sent, recipients, manual: isManual, error: sendError || undefined });
});
