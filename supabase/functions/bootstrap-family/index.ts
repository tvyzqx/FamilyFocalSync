import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// bootstrap-family
//
// First parent + first family in one call.
//
// History note: an earlier version used admin.createUser +
// admin.generateLink({type:"signup"}) to ship the mail. That works in
// some self-hosted setups but skipped the mail outright in others —
// generateLink with type:"signup" expects to create the user, but it
// had just been created by admin.createUser, so GoTrue silently
// returned "user already registered" and no confirmation was sent.
// The user-facing resend path uses /auth/v1/resend, which IS reliable,
// so we now go through the canonical signup flow instead: an anon
// client calls auth.signUp, which both creates the user AND ships the
// confirmation email atomically.
//
// Steps:
// 1. anon.auth.signUp({email, password, options: {data}}) — creates
//    the auth user, ships the confirmation email. Returns user
//    immediately with no session (since email isn't confirmed yet).
// 2. Service-role admin client inserts the familyfocal.families row
//    and familyfocal.profiles row so the parent already has a family
//    the moment they confirm and sign in.
//
// Idempotency:
// - Already-confirmed existing user → signUp returns a "shadow" user
//   with identities=[] (anti-enumeration). We map to 409.
// - Already-unconfirmed existing user → signUp re-sends the
//   confirmation mail and returns the user normally. We check if a
//   profile already exists for that user — if yes, just return the
//   existing IDs (idempotent retry); if no, treat as a fresh bootstrap
//   continuation and create family + profile rows.
// - If signUp succeeds but DB inserts fail, we delete the auth user
//   and bail out so retries don't pile up half-finished accounts.
//
// Auth: anonymous. Listed as verify_jwt = false in supabase/config.toml
// (the caller has no session yet — that's the whole point).

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
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!url || !anonKey || !serviceRoleKey) {
      return json({ error: "Server auth is not configured." }, 500);
    }

    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") {
      return json({ error: "Body must be a JSON object." }, 400);
    }

    const email = stringValue(body.email).toLowerCase();
    const password = stringValue(body.password);
    const parentName = stringValue(body.parentName);
    const familyName = stringValue(body.familyName);

    if (!email || !email.includes("@")) {
      return json({ error: "A valid email is required." }, 400);
    }
    if (password.length < 8) {
      return json({ error: "Password must be at least 8 characters." }, 400);
    }
    if (!parentName) {
      return json({ error: "Parent name is required." }, 400);
    }
    if (!familyName) {
      return json({ error: "Family name is required." }, 400);
    }

    // Step 1: signUp via the public anon endpoint. This ships the
    // confirmation email and lets GoTrue handle "user already exists"
    // semantics consistently.
    const anon = createClient(url, anonKey);
    const { data: signUp, error: signUpError } = await anon.auth.signUp({
      email,
      password,
      options: { data: { display_name: parentName } },
    });

    if (signUpError) {
      const message = String(signUpError.message);
      if (/already.*registered/i.test(message) ||
          /already exists/i.test(message)) {
        return json(userAlreadyExistsResponse(), 409);
      }
      return json({ error: message }, 400);
    }
    if (!signUp.user) {
      return json({ error: "Sign-up did not return a user." }, 500);
    }
    // Anti-enumeration: existing confirmed users come back with
    // identities=[]. signUp itself doesn't error so callers can't
    // probe email existence; we surface 409 only when we're confident
    // there's a real prior account in the way.
    if (
      Array.isArray(signUp.user.identities) &&
      signUp.user.identities.length === 0
    ) {
      return json(userAlreadyExistsResponse(), 409);
    }

    const userId = signUp.user.id;
    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });

    // Idempotency on retries: if this user already has a parent
    // profile, the bootstrap is effectively a re-send of the mail.
    // Don't create a second family.
    const { data: existing } = await admin
      .from("profiles")
      .select("id, family_id, role")
      .eq("user_id", userId)
      .eq("role", "parent")
      .maybeSingle();
    if (existing) {
      return json({
        user_id: userId,
        family_id: existing.family_id,
        profile_id: existing.id,
        requires_email_confirmation: signUp.user.email_confirmed_at == null,
      });
    }

    const { data: family, error: familyError } = await admin
      .from("families")
      .insert({ name: familyName, created_by: userId })
      .select("id")
      .single();
    if (familyError || !family) {
      await rollbackUser(admin, userId);
      return json(
        { error: String(familyError?.message ?? "Could not create family.") },
        500,
      );
    }

    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .insert({
        family_id: family.id,
        user_id: userId,
        role: "parent",
        name: parentName,
      })
      .select("id")
      .single();
    if (profileError || !profile) {
      await rollbackFamily(admin, family.id);
      await rollbackUser(admin, userId);
      return json(
        {
          error: String(profileError?.message ?? "Could not create profile."),
        },
        500,
      );
    }

    return json({
      user_id: userId,
      family_id: family.id,
      profile_id: profile.id,
      requires_email_confirmation: signUp.user.email_confirmed_at == null,
    });
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

function userAlreadyExistsResponse() {
  return {
    error:
      "An account with this email already exists. Sign in instead, " +
      "or use a different address.",
    code: "user_already_exists",
  };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

async function rollbackUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
) {
  try {
    await admin.auth.admin.deleteUser(userId);
  } catch (_) {
    // intentionally ignored
  }
}

async function rollbackFamily(
  admin: ReturnType<typeof createClient>,
  familyId: string,
) {
  try {
    await admin.from("families").delete().eq("id", familyId);
  } catch (_) {
    // intentionally ignored
  }
}
