import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// delete-account
//
// User-initiated account deletion (App Store Guideline 5.1.1(v)).
//
// The caller is a signed-in parent. Two outcomes depending on whether
// the caller created the family:
//
// - Owner (families.created_by == caller): full teardown. We collect
//   every auth user bound to a profile in the family, delete the
//   `families` row — which CASCADEs to profiles, tasks, child_accounts,
//   goals, moods, council, device_tokens, join_tokens, … (see the
//   `on delete cascade` FKs in 001+ migrations) — and then delete each
//   auth user. Result: the account and ALL family data are gone from
//   the server. Nothing recoverable.
//
//   Ordering matters: families.created_by is `on delete restrict`, so
//   the auth users can only be removed AFTER the family row is gone.
//   We therefore snapshot the user_ids BEFORE deleting the family
//   (the cascade nulls/removes the profile rows that hold them).
//
// - Joined parent (not the creator): we delete only the caller's own
//   profile (cascading their personal rows) and their auth user. The
//   family and everyone else's data stay intact for the owner.
//
// Children / godchildren never reach this endpoint — the UI exposes
// account deletion only on the parent-facing family-account screen.
// We still defend in code: non-parent callers are rejected.
//
// Auth: caller JWT required (verify_jwt = true in config.toml). We
// re-resolve the caller through the service-role admin client so the
// destructive work runs with full privileges, never on the caller's
// RLS-scoped token.

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
    if (!url || !serviceRoleKey) {
      return json({ error: "Server auth is not configured." }, 500);
    }
    if (!jwt) {
      return json({ error: "Authorization header is required." }, 401);
    }

    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });

    // Identify the caller from the JWT.
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData.user) {
      return json({ error: "Unauthorized" }, 401);
    }
    const callerUserId = userData.user.id;

    // Caller's profile — must exist and be a parent.
    const { data: callerProfile, error: callerErr } = await admin
      .from("profiles")
      .select("id, family_id, role")
      .eq("user_id", callerUserId)
      .eq("deleted", false)
      .maybeSingle();
    if (callerErr) throw callerErr;
    if (!callerProfile) {
      // No profile bound to this user. Nothing family-side to delete —
      // just remove the orphan auth user so the account is gone.
      await deleteAuthUser(admin, callerUserId);
      return json({ ok: true, scope: "user_only" });
    }
    if (callerProfile.role !== "parent") {
      return json({ error: "Only parents can delete the account." }, 403);
    }

    const familyId = callerProfile.family_id as string;

    const { data: family, error: familyErr } = await admin
      .from("families")
      .select("id, created_by")
      .eq("id", familyId)
      .maybeSingle();
    if (familyErr) throw familyErr;

    const isOwner = !!family && family.created_by === callerUserId;

    if (!isOwner) {
      // Joined parent: detach just this member. Deleting the profile
      // row cascades the member's personal data; deleting the auth
      // user removes their login. The family lives on for the owner.
      await admin.from("profiles").delete().eq("id", callerProfile.id);
      await deleteAuthUser(admin, callerUserId);
      return json({ ok: true, scope: "member" });
    }

    // Owner: full family teardown.
    //
    // 1. Snapshot every auth user bound to the family BEFORE the
    //    cascade removes the profile rows that reference them.
    const { data: memberRows, error: membersErr } = await admin
      .from("profiles")
      .select("user_id")
      .eq("family_id", familyId)
      .not("user_id", "is", null);
    if (membersErr) throw membersErr;

    const userIds = new Set<string>();
    for (const row of memberRows ?? []) {
      if (typeof row.user_id === "string" && row.user_id) {
        userIds.add(row.user_id);
      }
    }
    // The creator is always removed, even if their profile somehow
    // lost its user_id binding.
    userIds.add(callerUserId);

    // 2. Delete the family row. CASCADE handles every familyfocal.*
    //    table keyed on family_id.
    const { error: deleteFamilyErr } = await admin
      .from("families")
      .delete()
      .eq("id", familyId);
    if (deleteFamilyErr) {
      return json(
        { error: String(deleteFamilyErr.message ?? "Could not delete family.") },
        500,
      );
    }

    // 3. Delete each bound auth user. Best-effort per user — a single
    //    failure (e.g. a user still referenced by a different family)
    //    must not abort the rest. The caller's own deletion is the one
    //    that matters most and is now unblocked.
    let deleted = 0;
    for (const id of userIds) {
      if (await deleteAuthUser(admin, id)) deleted++;
    }

    return json({ ok: true, scope: "family", users_deleted: deleted });
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

async function deleteAuthUser(
  admin: ReturnType<typeof createClient>,
  userId: string,
): Promise<boolean> {
  try {
    const { error } = await admin.auth.admin.deleteUser(userId);
    return !error;
  } catch (_) {
    return false;
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
