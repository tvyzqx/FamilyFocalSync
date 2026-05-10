import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// bootstrap-family
//
// First parent + first family in one call. Creates the auth user with
// email_confirm=false so Supabase sends the standard confirmation mail
// (SMTP must be configured), then writes the family row and the parent
// profile, then reports back. The app shows a "check your email" hint
// until the user confirms; after confirmation the user signs in
// normally.
//
// Idempotency:
// - If the email already has a supabase user, the helper returns 409
//   with a hint to sign in or use a different address — no merge.
// - If user creation succeeds but the DB inserts fail, the user is
//   deleted again before returning the error so retries don't pile up
//   half-finished accounts.
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
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!url || !serviceRoleKey) {
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

    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });

    const { data: created, error: createError } =
      await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: false,
        user_metadata: { display_name: parentName },
      });

    if (createError || !created?.user) {
      const message = String(createError?.message ?? "User creation failed.");
      if (
        /already registered/i.test(message) ||
        /already exists/i.test(message) ||
        /user_already_exists/i.test(message)
      ) {
        return json(
          {
            error:
              "An account with this email already exists. Sign in instead, " +
              "or use a different address.",
            code: "user_already_exists",
          },
          409,
        );
      }
      return json({ error: message }, 400);
    }

    const userId = created.user.id;

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
      requires_email_confirmation: true,
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

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

// Rollback helpers swallow their own errors — we already have a primary
// error to return to the caller; a secondary failure during cleanup
// shouldn't shadow it. The rollback gap (orphaned rows) is rare and
// recoverable manually.

async function rollbackUser(admin: ReturnType<typeof createClient>, userId: string) {
  try {
    await admin.auth.admin.deleteUser(userId);
  } catch (_) {
    // intentionally ignored
  }
}

async function rollbackFamily(admin: ReturnType<typeof createClient>, familyId: string) {
  try {
    await admin.from("families").delete().eq("id", familyId);
  } catch (_) {
    // intentionally ignored
  }
}
