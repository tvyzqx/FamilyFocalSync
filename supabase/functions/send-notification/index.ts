// send-notification
//
// The one component that holds FCM credentials and actually talks to Google.
// It is both the cloud sender and the self-host relay:
//
//   notify-task-assigned (cloud OR self-host)  ──POST──▶  send-notification
//                                                          (this, on the relay
//                                                           host) ──▶ FCM ──▶ device
//
// Self-host servers cannot send to FCM themselves: the device tokens belong to
// the Firebase project baked into the published app, whose service account
// only the app publisher has. So every server POSTs here instead.
//
// Auth: a shared secret in `Authorization: Bearer <PUSH_RELAY_KEY>`. There is
// no user session, so this is verify_jwt = false in config.toml.
//
// Input (JSON):
//   { "messages": [
//       { "token": "<fcm token>",
//         "notification": { "title": "…", "body": "…" },   // optional
//         "data": { "type": "task_assigned", "task_id": "…" } } // optional, string values
//   ] }
//
// Output (JSON):
//   { "sent": <n>, "failed": <n>, "invalidTokens": ["…"] }
// invalidTokens are tokens FCM reported as gone (UNREGISTERED / 404); the
// caller should delete them from its own device_tokens table.
//
// Secrets: FCM_SERVICE_ACCOUNT (the full service-account JSON), PUSH_RELAY_KEY.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface OutMessage {
  token: string;
  notification?: { title?: string; body?: string };
  data?: Record<string, string>;
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const relayKey = Deno.env.get("PUSH_RELAY_KEY") ?? "";
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  if (!relayKey || !saRaw) {
    return json({ error: "Push relay is not configured." }, 500);
  }

  // Constant-ish bearer check.
  const auth = req.headers.get("authorization") ?? "";
  const presented = auth.replace(/^Bearer\s+/i, "");
  if (presented.length !== relayKey.length || presented !== relayKey) {
    return json({ error: "Unauthorized." }, 401);
  }

  let sa: ServiceAccount;
  try {
    // FCM_SERVICE_ACCOUNT may be the raw JSON or base64-encoded JSON — the
    // latter survives .env / env-var transport without quoting headaches.
    const text = saRaw.trim().startsWith("{") ? saRaw : atob(saRaw.trim());
    sa = JSON.parse(text);
    if (!sa.client_email || !sa.private_key || !sa.project_id) throw new Error();
  } catch {
    return json({ error: "FCM_SERVICE_ACCOUNT is malformed." }, 500);
  }

  const body = await req.json().catch(() => null);
  const messages: OutMessage[] = body && Array.isArray(body.messages) ? body.messages : [];
  if (messages.length === 0) return json({ error: "No messages." }, 400);

  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa);
  } catch (e) {
    return json({ error: "Could not authenticate to FCM: " + String((e as Error)?.message ?? e) }, 502);
  }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  let sent = 0;
  let failed = 0;
  const invalidTokens: string[] = [];

  for (const m of messages) {
    if (!m?.token) { failed++; continue; }
    const message: Record<string, unknown> = {
      token: m.token,
      android: { priority: "high" },
      apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default" } } },
    };
    if (m.notification) message.notification = m.notification;
    if (m.data) message.data = stringifyValues(m.data);

    const res = await fetch(endpoint, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });

    if (res.ok) {
      sent++;
    } else {
      failed++;
      const errBody = await res.json().catch(() => ({}));
      if (isUnregistered(res.status, errBody)) invalidTokens.push(m.token);
    }
  }

  return json({ sent, failed, invalidTokens });
});

// FCM marks a token as permanently gone with 404 NOT_FOUND or the UNREGISTERED
// error code. Those should be pruned; everything else is treated as transient.
function isUnregistered(status: number, errBody: unknown): boolean {
  if (status === 404) return true;
  const e = errBody as { error?: { status?: string; details?: Array<{ errorCode?: string }> } };
  if (e?.error?.status === "NOT_FOUND") return true;
  const code = e?.error?.details?.find((d) => d?.errorCode)?.errorCode;
  return code === "UNREGISTERED" || code === "INVALID_ARGUMENT";
}

// OAuth2 access token from the service account (JWT bearer grant), scoped to
// FCM. Minted per invocation — edge functions are short-lived.
async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claim))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${b64url(new Uint8Array(sig))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`token endpoint ${res.status}`);
  const tok = await res.json();
  if (!tok.access_token) throw new Error("no access_token");
  return tok.access_token as string;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function b64url(data: string | Uint8Array): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// FCM requires all data values to be strings.
function stringifyValues(data: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(data)) out[k] = typeof v === "string" ? v : String(v);
  return out;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
