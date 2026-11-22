import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const authHeader = req.headers.get('Authorization') || '';
    const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user) return new Response(JSON.stringify({ error: 'Sign in required' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    const { data: profile } = await caller.from('profiles').select('role,active').eq('id', user.id).maybeSingle();
    if (profile?.role !== 'owner' || !profile.active) return new Response(JSON.stringify({ error: 'Owner access required' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
    const body = await req.json();
    if (body.action === 'create') {
      const { data, error } = await admin.auth.admin.createUser({ email: body.email, password: body.temporaryPassword, email_confirm: true, user_metadata: { name: body.name } });
      if (error) throw error;
      const { error: profileError } = await admin.from('profiles').upsert({ id: data.user.id, role: 'staff', display_name: body.name, email: body.email, active: true });
      if (profileError) { await admin.auth.admin.deleteUser(data.user.id); throw profileError; }
      return Response.json({ id: data.user.id, email: data.user.email }, { headers: corsHeaders });
    }
    if (body.action === 'reset' || body.action === 'remove') {
      const { data: target } = await admin.from('profiles').select('role,active').eq('id', body.id).maybeSingle();
      if (target?.role !== 'staff' || !target.active) return new Response(JSON.stringify({ error: 'Active staff account not found' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
    if (body.action === 'reset') {
      const { error } = await admin.auth.admin.updateUserById(body.id, { password: body.temporaryPassword });
      if (error) throw error;
      return Response.json({ ok: true }, { headers: corsHeaders });
    }
    if (body.action === 'remove') {
      const { error } = await admin.auth.admin.deleteUser(body.id);
      if (error) throw error;
      return Response.json({ ok: true }, { headers: corsHeaders });
    }
    return new Response(JSON.stringify({ error: 'Unknown action' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message || 'Request failed' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
