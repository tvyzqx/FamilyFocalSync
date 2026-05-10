create table if not exists public.join_tokens (
  token text primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  invited_role text not null check (invited_role in ('parent', 'child')),
  preassigned_profile_id uuid references public.profiles(id) on delete set null,
  issued_by uuid not null references auth.users(id) on delete cascade,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by uuid references auth.users(id) on delete set null
);

create index if not exists join_tokens_family_id_idx
  on public.join_tokens (family_id);

create index if not exists join_tokens_expires_at_idx
  on public.join_tokens (expires_at);

alter table public.join_tokens enable row level security;

create policy "Parents can read their own join tokens"
  on public.join_tokens
  for select
  using (issued_by = auth.uid());

create policy "Parents can create join tokens for their family"
  on public.join_tokens
  for insert
  with check (issued_by = auth.uid());
