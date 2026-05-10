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
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!url || !anonKey || !serviceRoleKey) {
      return json({ error: "Server auth is not configured." }, 500);
    }

    const body = await req.json();
    const token = typeof body.token === "string" ? body.token.trim() : "";
    const deviceLabel = typeof body.deviceLabel === "string"
      ? body.deviceLabel.trim()
      : "second-device";
    if (!token) return json({ error: "Token is required." }, 400);

    const admin = createClient(url, serviceRoleKey);
    const { data: joinToken, error: tokenError } = await admin
      .from("join_tokens")
      .select("token, family_id, invited_role, preassigned_profile_id, expires_at, consumed_at")
      .eq("token", token)
      .maybeSingle();
    if (tokenError) throw tokenError;
    if (!joinToken) return json({ error: "Token not found." }, 404);
    if (joinToken.consumed_at) {
      return json({ error: "Token was already used." }, 409);
    }
    if (new Date(joinToken.expires_at).getTime() <= Date.now()) {
      return json({ error: "Token has expired." }, 410);
    }

    const password = randomToken(36);
    const email = `join-${crypto.randomUUID()}@familyfocal.local`;
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        family_id: joinToken.family_id,
        device_label: deviceLabel,
        invited_role: joinToken.invited_role,
      },
    });
    if (createError || !created.user) {
      throw createError ?? new Error("Could not create device account.");
    }

    const { data: consumedRows, error: consumeError } = await admin
      .from("join_tokens")
      .update({
        consumed_at: new Date().toISOString(),
        consumed_by: created.user.id,
      })
      .eq("token", token)
      .is("consumed_at", null)
      .gt("expires_at", new Date().toISOString())
      .select("token");
    if (consumeError) throw consumeError;
    if (!consumedRows || consumedRows.length !== 1) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: "Token can no longer be used." }, 409);
    }

    let profile = null;
    if (joinToken.preassigned_profile_id) {
      const { data, error } = await admin
        .from("profiles")
        .update({ user_id: created.user.id })
        .eq("id", joinToken.preassigned_profile_id)
        .select("*")
        .maybeSingle();
      if (error) throw error;
      profile = data;
    }

    if (!profile) {
      const { data, error } = await admin
        .from("profiles")
        .select("*")
        .eq("family_id", joinToken.family_id)
        .eq("role", joinToken.invited_role)
        .is("user_id", null)
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      profile = data;
    }

    const client = createClient(url, anonKey);
    const { data: sessionData, error: signInError } = await client.auth.signInWithPassword({
      email,
      password,
    });
    if (signInError || !sessionData.session) {
      throw signInError ?? new Error("Could not create auth session.");
    }

    const { data: familyMembers, error: membersError } = await admin
      .from("profiles")
      .select("*")
      .eq("family_id", joinToken.family_id)
      .order("name");
    if (membersError) throw membersError;

    return json({
      accessToken: sessionData.session.access_token,
      refreshToken: sessionData.session.refresh_token,
      profile,
      familyMembers,
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

function randomToken(bytes: number): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return btoa(String.fromCharCode(...data))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}
