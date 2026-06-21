import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// notify-task-assigned
//
// Fall B of the push design: when a task is created and assigned to someone,
// push an immediate "you have a new task" to that person's devices — so it
// reaches them even with the app closed.
//
// Runs on BOTH cloud and self-host. It is the target of a Supabase Database
// Webhook on INSERT into familyfocal.tasks. It looks up the assignee's device
// tokens locally, then POSTs to PUSH_SENDER_URL (the send-notification relay),
// which is the only place holding FCM credentials:
//   - cloud:     PUSH_SENDER_URL → this instance's own send-notification
//   - self-host: PUSH_SENDER_URL → the publisher's hosted relay
//
// Time-based reminders ("due tomorrow", recurring instances) are NOT handled
// here — those are local notifications scheduled on the device.
//
// Privacy: by default the push body is generic (no task title / names); the
// app fetches details from its own server on open. Set PUSH_INCLUDE_CONTENT=
// true (cloud, where the data is already first-party) to include the title.
//
// Auth: the webhook must send `Authorization: Bearer <PUSH_WEBHOOK_SECRET>`.
// verify_jwt = false in config.toml (the caller is Postgres, not a user).
//
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, PUSH_WEBHOOK_SECRET,
// PUSH_SENDER_URL, PUSH_RELAY_KEY, optional PUSH_INCLUDE_CONTENT.

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const webhookSecret = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";
  const senderUrl = Deno.env.get("PUSH_SENDER_URL") ?? "";
  const relayKey = Deno.env.get("PUSH_RELAY_KEY") ?? "";
  const includeContent = (Deno.env.get("PUSH_INCLUDE_CONTENT") ?? "") === "true";

  if (!url || !serviceKey || !webhookSecret || !senderUrl || !relayKey) {
    return json({ error: "Push orchestration is not configured." }, 500);
  }

  const auth = req.headers.get("authorization") ?? "";
  const presented = auth.replace(/^Bearer\s+/i, "");
  if (presented.length !== webhookSecret.length || presented !== webhookSecret) {
    return json({ error: "Unauthorized." }, 401);
  }

  const payload = await req.json().catch(() => null);
  const record = payload?.record;
  // Only act on a freshly inserted, assigned, real (non-template, live) task.
  if (
    payload?.type !== "INSERT" ||
    payload?.table !== "tasks" ||
    !record ||
    !record.assignee_profile_id ||
    record.is_template === true ||
    record.deleted === true
  ) {
    return json({ skipped: true });
  }

  const admin = createClient(url, serviceKey, { db: { schema: "familyfocal" } });

  // assignee profile → auth user
  const { data: profile } = await admin
    .from("profiles")
    .select("user_id")
    .eq("id", record.assignee_profile_id)
    .maybeSingle();
  if (!profile?.user_id) return json({ skipped: "assignee has no account" });

  // Only the assignee's OWN devices — those where the assignee profile is the
  // active one (device_tokens.profile_id). Filtering by user_id instead would
  // also hit a parent's device when the child is a sub-profile under the
  // parent's account, so the parent would get a push for a chore they just
  // assigned. profile_id keeps the push to the person who has to do the task.
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("token")
    .eq("profile_id", record.assignee_profile_id);
  if (!tokens || tokens.length === 0) return json({ skipped: "no devices" });

  const body = includeContent && record.title
    ? `Neue Aufgabe: ${record.title}`
    : "Du hast eine neue Aufgabe.";
  const messages = tokens.map((t: { token: string }) => ({
    token: t.token,
    notification: { title: "Neue Aufgabe", body },
    data: {
      type: "task_assigned",
      task_id: String(record.id ?? ""),
      family_id: String(record.family_id ?? ""),
    },
  }));

  const res = await fetch(senderUrl, {
    method: "POST",
    headers: { Authorization: `Bearer ${relayKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messages }),
  });

  if (!res.ok) {
    return json({ error: `relay responded ${res.status}` }, 502);
  }
  const result = await res.json().catch(() => ({}));

  // Prune tokens FCM reported as gone, so we stop trying them.
  if (Array.isArray(result.invalidTokens) && result.invalidTokens.length > 0) {
    await admin.from("device_tokens").delete().in("token", result.invalidTokens);
  }

  return json({ sent: result.sent ?? 0, pruned: result.invalidTokens?.length ?? 0 });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
