-- =====================================================================
-- Survey Requests — Supabase schema
-- Run once in Supabase > SQL Editor > New query > Run
-- All writes go through the functions below: the tables themselves are
-- read-only for users, so roles and status transitions cannot be bypassed.
-- =====================================================================

-- ---------- Users & roles ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null default '',
  company    text not null default '',
  role       text not null default 'requester' check (role in ('admin','surveyor','requester')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- A profile is created automatically for every user you invite.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- Role of the signed-in user (null if unknown or deactivated)
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

-- ---------- Requests ----------
create sequence if not exists public.ticket_seq;

create table if not exists public.tickets (
  id             uuid primary key default gen_random_uuid(),
  number         text not null unique default ('SR-' || lpad(nextval('public.ticket_seq')::text, 4, '0')),
  status         text not null default 'requested'
                 check (status in ('requested','info_needed','accepted','scheduled','completed','signed_off','rejected','cancelled')),
  priority       text not null default 'normal' check (priority in ('normal','urgent')),
  work_type      text not null,
  area           text not null,
  location       text not null default '',
  drawing_no     text not null,
  drawing_rev    text not null,
  description    text not null,
  due_date       date not null,
  requester_id   uuid not null references public.profiles(id),
  created_by     uuid not null references public.profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  scheduled_date date,
  assignee_id    uuid references public.profiles(id),
  info_request   text,
  reject_reason  text,
  reject_note    text,
  completed_at   timestamptz,
  completion     jsonb,
  signoff        jsonb
);

create table if not exists public.ticket_events (
  id        bigint generated always as identity primary key,
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  at        timestamptz not null default now(),
  by        uuid references public.profiles(id),
  action    text not null,
  note      text not null default ''
);
create index if not exists ticket_events_ticket_idx on public.ticket_events(ticket_id, at);

-- ---------- Row level security: active users read, nobody writes directly ----------
alter table public.profiles      enable row level security;
alter table public.tickets       enable row level security;
alter table public.ticket_events enable row level security;

drop policy if exists "active users read profiles" on public.profiles;
create policy "active users read profiles" on public.profiles
  for select to authenticated using (public.my_role() is not null or id = auth.uid());

drop policy if exists "active users read tickets" on public.tickets;
create policy "active users read tickets" on public.tickets
  for select to authenticated using (public.my_role() is not null);

drop policy if exists "active users read events" on public.ticket_events;
create policy "active users read events" on public.ticket_events
  for select to authenticated using (public.my_role() is not null);

-- ---------- Create a request ----------
-- Surveyors and admins may log a request on behalf of someone (phone / verbal request).
create or replace function public.create_ticket(p jsonb) returns public.tickets
language plpgsql security definer set search_path = public as $$
declare
  r   text := public.my_role();
  req uuid := auth.uid();
  t   public.tickets;
  who text;
begin
  if r is null then raise exception 'Your account is not active.'; end if;
  if coalesce(trim(p->>'drawing_no'),'') = '' or coalesce(trim(p->>'drawing_rev'),'') = '' then
    raise exception 'Drawing number and revision are required.';
  end if;
  if coalesce(trim(p->>'work_type'),'') = '' or coalesce(trim(p->>'area'),'') = ''
     or coalesce(trim(p->>'description'),'') = '' or coalesce(p->>'due_date','') = '' then
    raise exception 'Fill in every required field.';
  end if;
  if coalesce(p->>'on_behalf_of','') <> '' then
    if r not in ('admin','surveyor') then raise exception 'Only the survey team can log a request for someone else.'; end if;
    req := (p->>'on_behalf_of')::uuid;
  end if;

  insert into public.tickets (priority, work_type, area, location, drawing_no, drawing_rev, description, due_date, requester_id, created_by)
  values (coalesce(nullif(p->>'priority',''),'normal'), trim(p->>'work_type'), trim(p->>'area'), coalesce(trim(p->>'location'),''),
          trim(p->>'drawing_no'), trim(p->>'drawing_rev'), trim(p->>'description'), (p->>'due_date')::date, req, auth.uid())
  returning * into t;

  select full_name into who from public.profiles where id = req;
  insert into public.ticket_events (ticket_id, by, action, note)
  values (t.id, auth.uid(), 'Requested',
          'Drawing ' || t.drawing_no || ' rev ' || t.drawing_rev || case when req <> auth.uid() then ' (logged for ' || coalesce(who,'?') || ')' else '' end);
  return t;
end $$;

-- ---------- Every status change goes through here ----------
create or replace function public.ticket_action(p_id uuid, p_action text, p jsonb default '{}'::jsonb)
returns public.tickets
language plpgsql security definer set search_path = public as $$
declare
  r       text := public.my_role();
  me      uuid := auth.uid();
  t       public.tickets;
  team    boolean;
  owner   boolean;
  label   text;
  note    text := coalesce(trim(p->>'note'), '');
  who     text;
begin
  if r is null then raise exception 'Your account is not active.'; end if;
  select * into t from public.tickets where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;

  team  := r in ('admin','surveyor');
  owner := (t.requester_id = me) or r = 'admin';

  case p_action
    when 'accept' then
      if not team or t.status <> 'requested' then raise exception 'Action not allowed.'; end if;
      update public.tickets set status = 'accepted' where id = p_id;
      label := 'Accepted';

    when 'schedule' then
      if not team or t.status not in ('requested','accepted','scheduled') then raise exception 'Action not allowed.'; end if;
      if coalesce(p->>'scheduled_date','') = '' or coalesce(p->>'assignee_id','') = '' then
        raise exception 'Set a date and a surveyor.'; end if;
      update public.tickets set status = 'scheduled', scheduled_date = (p->>'scheduled_date')::date,
             assignee_id = (p->>'assignee_id')::uuid where id = p_id;
      select full_name into who from public.profiles where id = (p->>'assignee_id')::uuid;
      label := case when t.status = 'scheduled' then 'Rescheduled' else 'Scheduled' end;
      note  := to_char((p->>'scheduled_date')::date, 'Mon DD, YYYY') || ', ' || coalesce(who,'?') || case when note <> '' then '. ' || note else '' end;

    when 'info' then
      if not team or t.status not in ('requested','accepted') then raise exception 'Action not allowed.'; end if;
      if note = '' then raise exception 'Say what information is missing.'; end if;
      update public.tickets set status = 'info_needed', info_request = note where id = p_id;
      label := 'Info requested';

    when 'reject' then
      if not team or t.status not in ('requested','accepted','info_needed') then raise exception 'Action not allowed.'; end if;
      if coalesce(p->>'reject_reason','') = '' then raise exception 'Choose a reason.'; end if;
      update public.tickets set status = 'rejected', reject_reason = p->>'reject_reason', reject_note = note where id = p_id;
      label := 'Rejected';
      note  := (p->>'reject_reason') || case when note <> '' then ': ' || note else '' end;

    when 'resubmit' then
      if not (owner or team) or t.status <> 'info_needed' then raise exception 'Action not allowed.'; end if;
      if coalesce(trim(p->>'drawing_no'),'') = '' or coalesce(trim(p->>'drawing_rev'),'') = '' then
        raise exception 'Drawing number and revision are required.'; end if;
      update public.tickets set status = 'requested',
             priority = coalesce(nullif(p->>'priority',''), priority),
             work_type = coalesce(nullif(trim(p->>'work_type'),''), work_type),
             area = coalesce(nullif(trim(p->>'area'),''), area),
             location = coalesce(trim(p->>'location'), location),
             drawing_no = trim(p->>'drawing_no'), drawing_rev = trim(p->>'drawing_rev'),
             description = coalesce(nullif(trim(p->>'description'),''), description),
             due_date = coalesce(nullif(p->>'due_date','')::date, due_date)
       where id = p_id;
      label := 'Updated and resubmitted';
      note  := 'Drawing ' || trim(p->>'drawing_no') || ' rev ' || trim(p->>'drawing_rev');

    when 'cancel' then
      if not (owner or team) or t.status not in ('requested','info_needed','accepted','scheduled') then raise exception 'Action not allowed.'; end if;
      update public.tickets set status = 'cancelled' where id = p_id;
      label := 'Cancelled';

    when 'done' then
      if not team or t.status <> 'scheduled' then raise exception 'Action not allowed.'; end if;
      if coalesce(p->'completion'->>'points','') = '' then raise exception 'Enter the number of points.'; end if;
      update public.tickets set status = 'completed', completed_at = now(),
             completion = (p->'completion') || jsonb_build_object('by', me) where id = p_id;
      label := 'Survey done';
      note  := (p->'completion'->>'points') || ' pts, ' || coalesce(p->'completion'->>'tolerance','');

    when 'issue' then
      if not (owner or team) or t.status <> 'completed' then raise exception 'Action not allowed.'; end if;
      if note = '' then raise exception 'Describe the issue.'; end if;
      update public.tickets set status = 'scheduled' where id = p_id;
      label := 'Issue reported';

    when 'signoff' then
      -- the requester signs on their own account, or on the surveyor's device in the field
      if not (owner or team) or t.status <> 'completed' then raise exception 'Action not allowed.'; end if;
      if coalesce(trim(p->'signoff'->>'name'),'') = '' then raise exception 'Enter the name of the person signing.'; end if;
      if coalesce(p->'signoff'->>'sig','') = '' then raise exception 'A signature is required.'; end if;
      update public.tickets set status = 'signed_off',
             signoff = (p->'signoff') || jsonb_build_object('by', me, 'at', now()) where id = p_id;
      label := 'Signed off';
      note  := coalesce(p->'signoff'->>'name','') || case when coalesce(p->'signoff'->>'company','') <> '' then ', ' || (p->'signoff'->>'company') else '' end;

    when 'note' then
      if note = '' then raise exception 'The note is empty.'; end if;
      label := 'Note';

    else
      raise exception 'Unknown action.';
  end case;

  update public.tickets set updated_at = now() where id = p_id returning * into t;
  insert into public.ticket_events (ticket_id, by, action, note) values (p_id, me, label, note);
  return t;
end $$;

-- ---------- Profile management ----------
create or replace function public.update_my_profile(p_full_name text, p_company text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_full_name),'') = '' then raise exception 'Enter your name.'; end if;
  update public.profiles set full_name = trim(p_full_name), company = coalesce(trim(p_company),'') where id = auth.uid();
end $$;

create or replace function public.set_user_role(p_user uuid, p_role text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Only an admin can change roles.'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own role.'; end if;
  if p_role not in ('admin','surveyor','requester') then raise exception 'Unknown role.'; end if;
  update public.profiles set role = p_role, active = p_active where id = p_user;
end $$;

create or replace function public.set_user_details(p_user uuid, p_full_name text, p_company text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Only an admin can edit users.'; end if;
  update public.profiles set full_name = trim(p_full_name), company = coalesce(trim(p_company),'') where id = p_user;
end $$;

-- ---------- Permissions ----------
revoke all on public.profiles, public.tickets, public.ticket_events from anon, authenticated;
grant select on public.profiles, public.tickets, public.ticket_events to authenticated;

revoke execute on function public.create_ticket(jsonb)                   from public, anon;
revoke execute on function public.ticket_action(uuid, text, jsonb)       from public, anon;
revoke execute on function public.update_my_profile(text, text)          from public, anon;
revoke execute on function public.set_user_role(uuid, text, boolean)     from public, anon;
revoke execute on function public.set_user_details(uuid, text, text)     from public, anon;
grant  execute on function public.create_ticket(jsonb)                   to authenticated;
grant  execute on function public.ticket_action(uuid, text, jsonb)       to authenticated;
grant  execute on function public.update_my_profile(text, text)          to authenticated;
grant  execute on function public.set_user_role(uuid, text, boolean)     to authenticated;
grant  execute on function public.set_user_details(uuid, text, text)     to authenticated;

-- ---------- Live updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.tickets;       exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ticket_events; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles;      exception when duplicate_object then null; end;
end $$;

-- ---------- First admin (run after you have invited yourself) ----------
-- update public.profiles set role = 'admin'
--  where id = (select id from auth.users where email = 'your.email@company.com');
