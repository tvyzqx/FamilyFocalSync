import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// delete-account
//
// Permanent account deletion (App Store Guideline 5.1.1(v)). The signed-in
// parent calls this with their own JWT; the app then wipes the device.
//
// Two modes, decided by family ownership (families.created_by):
//
//   owner  — tears down the WHOLE family. We delete the familyfocal.families
//            row, which cascades to profiles and every child table (all 19
//            child FKs are `on delete cascade` / `set null`), then delete
//            every auth.users row bound to a profile in that family.
//
//   member — a parent who joined someone else's family. We detach only their
//            own membership: soft-delete their profile (so the rest of the
//            family syncs the tombstone — a hard delete wouldn't propagate
//            through incremental sync) and delete their own auth user.
//
// Why order matters: families.created_by references auth.users(id) ON DELETE
// RESTRICT. The owner's auth user therefore CANNOT be removed while the
// family still exists. So we always delete the family FIRST, then the users.
// An earlier deployed version skipped the auth-user delete entirely, which
// left the email registered (sign-up returns "already registered") but with
// no profile (sign-in fails) — an unusable, undeletable orphan. This fixes
// that, and is self-healing: if the caller's own user delete fails after the
// family is gone, a retry lands on the orphan branch below and finishes it.
//
// Auth: caller JWT required (verify_jwt = true in supabase/config.toml).

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

    // Identify the caller from their JWT.
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData.user) {
      return json({ error: "Unauthorized" }, 401);
    }
    const callerUserId = userData.user.id;

    // Caller's profile. May legitimately be absent: an orphaned auth user
    // left behind by a previously-incomplete deletion. In that case there's
    // nothing to tear down — just remove the auth user so the email frees up.
    const { data: profile, error: profileErr } = await admin
      .from("profiles")
      .select("id, family_id")
      .eq("user_id", callerUserId)
      .maybeSingle();
    if (profileErr) throw profileErr;

    if (!profile) {
      await deleteAuthUser(admin, callerUserId);
      return json({ ok: true, mode: "orphan" });
    }

    // Resolve the family to decide owner vs. member.
    const { data: family, error: familyErr } = await admin
      .from("families")
      .select("id, created_by")
      .eq("id", profile.family_id)
      .maybeSingle();
    if (familyErr) throw familyErr;

    const isOwner = !!family && family.created_by === callerUserId;

    if (isOwner) {
      // Snapshot every bound auth user BEFORE the cascade removes the
      // profiles we'd read them from.
      const { data: members, error: membersErr } = await admin
        .from("profiles")
        .select("user_id")
        .eq("family_id", family.id)
        .not("user_id", "is", null);
      if (membersErr) throw membersErr;

      const otherUserIds = new Set<string>();
      for (const m of members ?? []) {
        const uid = m.user_id as string | null;
        if (uid && uid !== callerUserId) otherUserIds.add(uid);
      }

      // 1. Delete the family — cascades to profiles + all child data.
      const { error: delFamErr } = await admin
        .from("families")
        .delete()
        .eq("id", family.id);
      if (delFamErr) throw delFamErr;

      // 2. Remove the other members' logins (best-effort: a sibling's
      //    failure must not block freeing the owner's own email).
      for (const uid of otherUserIds) {
        await deleteAuthUser(admin, uid, { bestEffort: true });
      }

      // 3. Remove the owner's own login last (now unblocked by step 1).
      //    Authoritative: throw on failure so the app reports it and a
      //    retry can finish the job via the orphan branch.
      await deleteAuthUser(admin, callerUserId);

      return json({
        ok: true,
        mode: "owner",
        other_users_deleted: otherUserIds.size,
      });
    }

    // Member self-deletion: detach this profile and drop this login only.
    const { error: detachErr } = await admin
      .from("profiles")
      .update({ deleted: true, user_id: null })
      .eq("id", profile.id);
    if (detachErr) throw detachErr;

    await deleteAuthUser(admin, callerUserId);
    return json({ ok: true, mode: "member" });
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
  opts: { bestEffort?: boolean } = {},
) {
  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error && !opts.bestEffort) throw error;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
