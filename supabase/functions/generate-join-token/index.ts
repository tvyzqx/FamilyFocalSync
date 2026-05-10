import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");
    if (!url || !serviceRoleKey || !jwt) {
      return json({ error: "Server auth is not configured." }, 500);
    }

    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    if (userError || !userData.user) {
      return json({ error: "Unauthorized" }, 401);
    }

    const body = await req.json();
    const memberId = stringValue(body.memberId);
    const role = stringValue(body.role) === "parent" ? "parent" : "child";
    let familyId = stringValue(body.familyId);
    let profileId = memberId;

    if (memberId) {
      const { data: profile, error } = await admin
        .from("profiles")
        .select("id, family_id, role")
        .eq("id", memberId)
        .maybeSingle();
      if (error) throw error;
      if (!profile) return json({ error: "Profile not found." }, 404);
      familyId = profile.family_id;
      profileId = profile.id;
    }

    if (!familyId) {
      const { data: ownProfile, error } = await admin
        .from("profiles")
        .select("family_id")
        .eq("user_id", userData.user.id)
        .eq("role", "parent")
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      familyId = ownProfile?.family_id ?? "";
    }

    if (!familyId) {
      return json({ error: "Family not found." }, 404);
    }

    const { data: parentProfile, error: parentError } = await admin
      .from("profiles")
      .select("id")
      .eq("family_id", familyId)
      .eq("user_id", userData.user.id)
      .eq("role", "parent")
      .maybeSingle();
    if (parentError) throw parentError;
    if (!parentProfile) {
      return json({ error: "Only parents can create join tokens." }, 403);
    }

    const ttlMinutes = Math.min(
      Number(Deno.env.get("JOIN_TOKEN_TTL_MINUTES") ?? "10"),
      10,
    );
    const expiresAt = new Date(Date.now() + ttlMinutes * 60 * 1000);
    const token = crypto.randomUUID() + "." + randomToken(32);

    // Token hygiene (ADR-4): when issuing a new token for a profile, retire
    // every still-open token for the same profile so two devices can't race
    // to claim the same slot. Only runs when a profile is preassigned —
    // tokens without preassigned_profile_id (rare, used for parent invites
    // without a target row yet) are issued additively.
    if (profileId) {
      const { error: hygieneError } = await admin
        .from("join_tokens")
        .update({ consumed_at: new Date().toISOString() })
        .eq("preassigned_profile_id", profileId)
        .is("consumed_at", null);
      if (hygieneError) throw hygieneError;
    }

    const { error: insertError } = await admin.from("join_tokens").insert({
      token,
      family_id: familyId,
      invited_role: role,
      preassigned_profile_id: profileId || null,
      issued_by: userData.user.id,
      expires_at: expiresAt.toISOString(),
    });
    if (insertError) throw insertError;

    return json({
      token,
      expiresAt: expiresAt.toISOString(),
      ttlSeconds: ttlMinutes * 60,
      server: url,
      anonKey,
      familyId,
      profileId,
      role,
      fallbackCode: token.replace(/[^a-zA-Z0-9]/g, "").slice(0, 8).toUpperCase(),
    });
  } catch (error) {
    return json({ error: String(error?.message ?? error) }, 400);
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

function randomToken(bytes: number): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return btoa(String.fromCharCode(...data))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}
