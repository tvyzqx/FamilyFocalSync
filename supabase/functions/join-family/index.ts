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
    // Optional. Only used when the join token's email_target is set,
    // i.e. the receiver is claiming an email-bound profile (typically
    // a partner). For child/godchild profiles without an email_target
    // the receiver is provisioned as an anonymous device user and the
    // server picks a random password internally.
    const receiverPassword = typeof body.password === "string"
      ? body.password
      : "";
    if (!token) return json({ error: "Token is required." }, 400);

    const admin = createClient(url, serviceRoleKey, {
      db: { schema: "familyfocal" },
    });
    const { data: joinToken, error: tokenError } = await admin
      .from("join_tokens")
      .select("token, family_id, invited_role, preassigned_profile_id, expires_at, consumed_at, email_target")
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

    // Two distinct provisioning paths depending on whether the token
    // is email-bound:
    //
    // - Anonymous device user (no email_target): existing children /
    //   godchildren / guests. We make up an internal email and a
    //   random password, mark the account auto-confirmed.
    //
    // - Email-bound (email_target set): the receiver is taking
    //   ownership of a profile that the parent already attached to
    //   their email. The receiver picks the password during the join
    //   flow; the QR handoff itself is the trust gesture, so we
    //   auto-confirm the address (email_confirm: true) instead of
    //   firing a confirmation email.
    const isEmailBound = typeof joinToken.email_target === "string" &&
      joinToken.email_target.trim().length > 0;
    let email: string;
    let password: string;
    if (isEmailBound) {
      if (receiverPassword.length < 8) {
        return json(
          {
            error: "Password must be at least 8 characters.",
            code: "password_required",
          },
          400,
        );
      }
      email = joinToken.email_target.trim().toLowerCase();
      password = receiverPassword;
    } else {
      email = `join-${crypto.randomUUID()}@familyfocal.local`;
      password = randomToken(36);
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        family_id: joinToken.family_id,
        device_label: deviceLabel,
        invited_role: joinToken.invited_role,
        email_bound: isEmailBound,
      },
    });
    if (createError || !created.user) {
      const message = String(createError?.message ?? "Could not create device account.");
      if (isEmailBound &&
          (/already.*registered/i.test(message) ||
              /already exists/i.test(message))) {
        return json(
          {
            error: "An account with this email already exists. Sign in instead, or ask the parent to use a different email.",
            code: "user_already_exists",
          },
          409,
        );
      }
      throw createError ?? new Error(message);
    }

    // From here on we own a freshly minted auth.users row plus a
    // soon-to-be-consumed join token. If any downstream step blows up,
    // both must be unwound — otherwise a retry hits
    // "user already registered" (orphan auth user) or
    // "token can no longer be used" (orphan consumed_at), and the
    // join is permanently stuck for that email/token.
    let tokenConsumed = false;
    let profileUserIdSet = false;
    const rollback = async () => {
      if (profileUserIdSet && joinToken.preassigned_profile_id) {
        try {
          await admin
            .from("profiles")
            .update({ user_id: null })
            .eq("id", joinToken.preassigned_profile_id);
        } catch (_) { /* best effort */ }
      }
      if (tokenConsumed) {
        try {
          await admin
            .from("join_tokens")
            .update({ consumed_at: null, consumed_by: null })
            .eq("token", token);
        } catch (_) { /* best effort */ }
      }
      try {
        await admin.auth.admin.deleteUser(created.user.id);
      } catch (_) { /* best effort */ }
    };

    let profile = null;
    try {
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
        // Someone else already claimed it; just wipe our user.
        await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
        return json({ error: "Token can no longer be used." }, 409);
      }
      tokenConsumed = true;

      if (joinToken.preassigned_profile_id) {
        const { data, error } = await admin
          .from("profiles")
          .update({ user_id: created.user.id })
          .eq("id", joinToken.preassigned_profile_id)
          .select("*")
          .maybeSingle();
        if (error) throw error;
        profile = data;
        profileUserIdSet = data != null;
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
    } catch (downstream) {
      await rollback();
      throw downstream;
    }

    const client = createClient(url, anonKey);
    const { data: sessionData, error: signInError } = await client.auth.signInWithPassword({
      email,
      password,
    });
    if (signInError || !sessionData.session) {
      // Sign-in failure mid-flow is most likely transient (GoTrue
      // rate limit / connection blip). The auth user does exist and a
      // retry with the same token would land in "already registered",
      // so it's safer to wipe and let the receiver re-scan than to
      // leave a half-claimed profile that can never sign in.
      await rollback();
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
