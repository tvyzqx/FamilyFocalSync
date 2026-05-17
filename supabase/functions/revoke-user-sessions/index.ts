import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// revoke-user-sessions
//
// Parent-initiated "log this person out of every device" action.
// Caller passes a target_profile_id (some other member in their
// family). We resolve that profile's auth user, then call the
// GoTrue admin "logout user" endpoint which invalidates every
// refresh token for that user across all devices. Their phones
// then either pick up the 401 on the next sync round-trip OR get
// caught by the app's onAuthStateChange listener once Supabase
// notices the token can't refresh.
//
// Auth: caller JWT required. The caller must be a parent in the
// same family as the target profile. RLS handles the
// "same-family parent" check via auth_is_parent() / auth_family_id()
// — we read the target profile through the service-role admin
// client and validate the family match in code, because the
// caller's JWT alone wouldn't tell us whether they outrank the
// target.
//
// The target's own auth user can be the caller themselves
// (parent revokes their own sessions = nuke all my logins). Allowed.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");
    // Server env-vars missing is a 500 — the deploy is broken.
    // Missing Authorization header is a 401 — the client forgot to
    // attach the parent JWT. Splitting these makes log triage and
    // any future app-side error display land on the right side.
    if (!url || !serviceRoleKey) {
      return json({ error: "Server auth is not configured." }, 500);
    }
    if (!jwt) {
      return json({ error: "Authorization header is required." }, 401);
    }

    const body = await req.json().catch(() => null);
    const targetProfileId = typeof body?.target_profile_id === "string"
      ? body.target_profile_id.trim()
      : "";
    if (!targetProfileId) {
      return json({ error: "target_profile_id is required." }, 400);
    }

    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });

    // Identify the caller. getUser() decodes the JWT and confirms it
    // matches an active auth.users row.
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData.user) {
      return json({ error: "Unauthorized" }, 401);
    }
    const callerUserId = userData.user.id;

    // Caller's profile — must exist, must be parent.
    const { data: callerProfile, error: callerErr } = await admin
      .from("profiles")
      .select("id, family_id, role")
      .eq("user_id", callerUserId)
      .eq("deleted", false)
      .maybeSingle();
    if (callerErr) throw callerErr;
    if (!callerProfile || callerProfile.role !== "parent") {
      return json({ error: "Parents only." }, 403);
    }

    // Target profile — must exist in caller's family, must have a
    // bound auth user (otherwise there's nothing to log out).
    const { data: targetProfile, error: targetErr } = await admin
      .from("profiles")
      .select("id, family_id, user_id, name")
      .eq("id", targetProfileId)
      .maybeSingle();
    if (targetErr) throw targetErr;
    if (!targetProfile) {
      return json({ error: "Target profile not found." }, 404);
    }
    if (targetProfile.family_id !== callerProfile.family_id) {
      return json({ error: "Target is not in your family." }, 403);
    }
    if (!targetProfile.user_id) {
      // No auth user attached — nothing to revoke. Return success
      // so the UI doesn't surface a confusing error for an
      // already-detached profile.
      return json({ ok: true, sessions_revoked: 0 });
    }

    // GoTrue's admin "log this user out everywhere" endpoint.
    // supabase-js doesn't expose it directly (signOut is per-JWT),
    // so we fetch the REST route with the service-role key.
    const logoutResp = await fetch(
      `${url}/auth/v1/admin/users/${targetProfile.user_id}/logout`,
      {
        method: "POST",
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
      },
    );
    if (!logoutResp.ok && logoutResp.status !== 204) {
      const text = await logoutResp.text().catch(() => "");
      return json(
        {
          error: `GoTrue rejected the logout (HTTP ${logoutResp.status}): ${text}`,
        },
        500,
      );
    }

    return json({ ok: true, target_name: targetProfile.name });
  } catch (error) {
    return json(
      {
        error: String(
          (error as { message?: unknown })?.message ?? error ?? "Unknown error.",
        ),
      },
      400,
    );
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
