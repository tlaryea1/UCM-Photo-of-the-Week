-- ============================================================================
-- UCM Photo of the Week — Supabase setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run again: it drops and recreates functions/policies, keeps data.
--
-- Week schedule (America/New_York):
--   Mon–Thu  submit (up to 4 photos each)
--   Fri–Sun  vote   (rate every photo 0–7 once; your own photos are skipped)
--   After    closed (results + photographer names revealed)
-- An admin can override the stage for any week with set_stage().
--
-- Everything the site reads or writes goes through the functions below.
-- The tables themselves are locked (RLS on, no policies), so nobody can see
-- who shot what or how anyone voted before a week closes, and nobody can
-- break the rules by editing the site's code.
-- ============================================================================

-- ---------- tables ----------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  created_at   timestamptz not null default now()
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.stage_overrides (
  week  date primary key,
  stage text not null check (stage in ('submit','vote','closed'))
);

create table if not exists public.photos (
  id         uuid primary key default gen_random_uuid(),
  week       date not null,
  owner      uuid not null references public.profiles(id) on delete cascade,
  path       text not null unique,
  title      text check (title is null or char_length(title) <= 80),
  created_at timestamptz not null default now()
);
create index if not exists photos_week_idx on public.photos(week);

create table if not exists public.ballots (
  week       date not null,
  voter      uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (week, voter)
);

create table if not exists public.ratings (
  week     date not null,
  voter    uuid not null,
  photo_id uuid not null references public.photos(id) on delete cascade,
  stars    smallint not null check (stars between 0 and 7),
  primary key (voter, photo_id),
  foreign key (week, voter) references public.ballots(week, voter) on delete cascade
);
create index if not exists ratings_photo_idx on public.ratings(photo_id);

-- Lock every table: no direct access from the browser at all.
alter table public.profiles        enable row level security;
alter table public.admins          enable row level security;
alter table public.stage_overrides enable row level security;
alter table public.photos          enable row level security;
alter table public.ballots         enable row level security;
alter table public.ratings         enable row level security;
revoke all on public.profiles, public.admins, public.stage_overrides,
              public.photos, public.ballots, public.ratings
  from anon, authenticated;

-- ---------- only @kent.edu addresses can create an account ------------------
create or replace function public.enforce_kent_email()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is null or lower(split_part(new.email, '@', 2)) <> 'kent.edu' then
    raise exception 'Only @kent.edu email addresses can join.';
  end if;
  return new;
end $$;

drop trigger if exists enforce_kent_email on auth.users;
create trigger enforce_kent_email
  before insert or update of email on auth.users
  for each row execute function public.enforce_kent_email();

-- ---------- helpers ---------------------------------------------------------
create or replace function public.is_kent()
returns boolean language sql stable set search_path = '' as $$
  select coalesce(lower(split_part(auth.jwt() ->> 'email', '@', 2)) = 'kent.edu', false)
$$;

create or replace function public.current_week()
returns date language sql stable set search_path = '' as $$
  select date_trunc('week', now() at time zone 'America/New_York')::date
$$;

create or replace function public.stage_of(w date)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.stage from public.stage_overrides s where s.week = w),
    case
      when w < public.current_week() then 'closed'
      when w > public.current_week() then 'upcoming'
      when extract(isodow from now() at time zone 'America/New_York') between 1 and 4 then 'submit'
      else 'vote'
    end)
$$;

create or replace function public.require_kent()
returns void language plpgsql stable set search_path = '' as $$
begin
  if not public.is_kent() then
    raise exception 'Sign in with your @kent.edu email first.';
  end if;
end $$;

-- ---------- profile ---------------------------------------------------------
create or replace function public.set_my_name(p_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  perform public.require_kent();
  if char_length(n) not between 1 and 60 then
    raise exception 'Enter a name between 1 and 60 characters.';
  end if;
  insert into public.profiles (id, display_name) values (auth.uid(), n)
  on conflict (id) do update set display_name = excluded.display_name;
end $$;

-- ---------- this week's sheet ----------------------------------------------
create or replace function public.get_week()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  w  date := public.current_week();
  st text := public.stage_of(w);
  me uuid := auth.uid();
begin
  perform public.require_kent();
  return jsonb_build_object(
    'week',          w,
    'stage',         st,
    'override',      (select s.stage from public.stage_overrides s where s.week = w),
    'me',            (select p.display_name from public.profiles p where p.id = me),
    'is_admin',      exists (select 1 from public.admins a where a.user_id = me),
    'total',         (select count(*) from public.photos p where p.week = w),
    'photographers', (select count(distinct p.owner) from public.photos p where p.week = w),
    'voters',        (select count(*) from public.ballots b where b.week = w),
    'voted',         exists (select 1 from public.ballots b where b.week = w and b.voter = me),
    -- During submissions you only see your own photos. During voting you see
    -- every photo, but never who took it (only whether it is yours).
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'path', p.path, 'title', p.title, 'mine', p.owner = me)
             order by p.created_at)
      from public.photos p
      where p.week = w and (st <> 'submit' or p.owner = me)), '[]'::jsonb),
    'my_ratings', coalesce((
      select jsonb_object_agg(r.photo_id, r.stars)
      from public.ratings r where r.week = w and r.voter = me), '{}'::jsonb)
  );
end $$;

-- ---------- submissions -----------------------------------------------------
create or replace function public.submit_photo(p_path text, p_title text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  w   date := public.current_week();
  me  uuid := auth.uid();
  n   int;
  pid uuid;
begin
  perform public.require_kent();
  if not exists (select 1 from public.profiles p where p.id = me) then
    raise exception 'Add your name before submitting.';
  end if;
  if public.stage_of(w) <> 'submit' then
    raise exception 'Submissions are closed for this week.';
  end if;
  if p_path !~ ('^' || w::text || '/[0-9a-f-]{36}\.jpg$') then
    raise exception 'That upload has an unexpected file name. Try again.';
  end if;
  if not exists (select 1 from storage.objects o
                 where o.bucket_id = 'photos' and o.name = p_path and o.owner_id = me::text) then
    raise exception 'The photo upload was not found. Try again.';
  end if;

  perform pg_advisory_xact_lock(hashtext(me::text || w::text));
  select count(*) into n from public.photos p where p.week = w and p.owner = me;
  if n >= 4 then
    raise exception 'You have already submitted 4 photos this week.';
  end if;

  insert into public.photos (week, owner, path, title)
  values (w, me, p_path, nullif(left(btrim(coalesce(p_title, '')), 80), ''))
  returning id into pid;
  return pid;
end $$;

-- Returns the file path so the site can delete the file from storage.
create or replace function public.remove_photo(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare r public.photos;
begin
  perform public.require_kent();
  select * into r from public.photos p where p.id = p_id and p.owner = auth.uid();
  if not found then
    raise exception 'That photo was not found.';
  end if;
  if r.week <> public.current_week() or public.stage_of(r.week) <> 'submit' then
    raise exception 'Photos can only be removed while submissions are open.';
  end if;
  delete from public.photos p where p.id = p_id;
  return r.path;
end $$;

-- ---------- voting ----------------------------------------------------------
-- p_ratings: {"<photo id>": 0..7, ...} covering every photo except your own.
create or replace function public.cast_ballot(p_ratings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  w    date := public.current_week();
  me   uuid := auth.uid();
  pool uuid[];
  bad  int;
begin
  perform public.require_kent();
  if not exists (select 1 from public.profiles p where p.id = me) then
    raise exception 'Add your name before voting.';
  end if;
  if public.stage_of(w) <> 'vote' then
    raise exception 'Voting is not open right now.';
  end if;
  if exists (select 1 from public.ballots b where b.week = w and b.voter = me) then
    raise exception 'You have already voted this week.';
  end if;
  if jsonb_typeof(p_ratings) is distinct from 'object' then
    raise exception 'Ballot is malformed.';
  end if;

  select array_agg(p.id) into pool from public.photos p where p.week = w and p.owner <> me;
  if pool is null then
    raise exception 'There are no photos for you to rate this week.';
  end if;

  -- exactly the pool, nothing missing, nothing extra
  if (select count(*) from jsonb_object_keys(p_ratings)) <> cardinality(pool)
     or exists (select 1 from unnest(pool) as x(id) where not (p_ratings ? x.id::text)) then
    raise exception 'Rate every photo before submitting.';
  end if;

  -- every value a whole number 0–7
  select count(*) into bad
  from jsonb_each(p_ratings) e
  where case when jsonb_typeof(e.value) = 'number'
             then (e.value #>> '{}')::numeric not in (0,1,2,3,4,5,6,7)
             else true end;
  if bad > 0 then
    raise exception 'Each rating must be a whole number from 0 to 7.';
  end if;

  insert into public.ballots (week, voter) values (w, me);
  insert into public.ratings (week, voter, photo_id, stars)
  select w, me, x.id, (p_ratings ->> x.id::text)::numeric::smallint
  from unnest(pool) as x(id);
exception
  when unique_violation then
    raise exception 'You have already voted this week.';
end $$;

-- ---------- results (only once a week is closed) ---------------------------
create or replace function public.get_results(w date)
returns table (place int, photo_id uuid, path text, title text, photographer text,
               avg_stars numeric, ratings int, sevens int, voters int)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  perform public.require_kent();
  if public.stage_of(w) <> 'closed' then
    raise exception 'Results stay hidden until voting closes.';
  end if;
  return query
  with s as (
    select p.id, p.path, p.title, pr.display_name, p.created_at,
           avg(r.stars)::numeric as a,
           count(r.stars) as n,
           count(r.stars) filter (where r.stars = 7) as s7
    from public.photos p
    join public.profiles pr on pr.id = p.owner
    left join public.ratings r on r.photo_id = p.id and r.voter <> p.owner
    where p.week = w
    group by p.id, p.path, p.title, pr.display_name, p.created_at
  )
  select (row_number() over (order by s.a desc nulls last, s.s7 desc, s.n desc, s.created_at))::int,
         s.id, s.path, s.title, s.display_name, round(s.a, 2), s.n::int, s.s7::int,
         (select count(*) from public.ballots b where b.week = w)::int
  from s
  order by 1;
end $$;

-- Most recent closed weeks that have a rated winner (newest first).
create or replace function public.get_winners()
returns table (week date, photo_id uuid, path text, title text, photographer text,
               avg_stars numeric, ratings int, tied boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  perform public.require_kent();
  return query
  with s as (
    select p.week, p.id, p.path, p.title, pr.display_name, p.created_at,
           avg(r.stars)::numeric as a, count(*) as n,
           count(*) filter (where r.stars = 7) as s7
    from public.photos p
    join public.profiles pr on pr.id = p.owner
    join public.ratings r on r.photo_id = p.id and r.voter <> p.owner
    group by p.week, p.id, p.path, p.title, pr.display_name, p.created_at
  ), ranked as (
    select s.*,
           row_number() over (partition by s.week order by s.a desc, s.s7 desc, s.n desc, s.created_at) as rn,
           count(*) over (partition by s.week, s.a, s.s7, s.n) as same
    from s
  )
  select r.week, r.id, r.path, r.title, r.display_name, round(r.a, 2), r.n::int, r.same > 1
  from ranked r
  where r.rn = 1 and public.stage_of(r.week) = 'closed'
  order by r.week desc
  limit 52;
end $$;

-- ---------- admin -----------------------------------------------------------
-- p_stage: 'submit' | 'vote' | 'closed', or null / 'auto' to follow the schedule.
create or replace function public.set_stage(w date, p_stage text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_kent();
  if not exists (select 1 from public.admins a where a.user_id = auth.uid()) then
    raise exception 'Only admins can change the stage.';
  end if;
  if p_stage is null or p_stage = 'auto' then
    delete from public.stage_overrides s where s.week = w;
  elsif p_stage in ('submit','vote','closed') then
    insert into public.stage_overrides (week, stage) values (w, p_stage)
    on conflict (week) do update set stage = excluded.stage;
  else
    raise exception 'Unknown stage %', p_stage;
  end if;
end $$;

-- ---------- function permissions -------------------------------------------
revoke execute on function
  public.set_my_name(text), public.get_week(), public.submit_photo(text, text),
  public.remove_photo(uuid), public.cast_ballot(jsonb), public.get_results(date),
  public.get_winners(), public.set_stage(date, text), public.stage_of(date),
  public.require_kent(), public.enforce_kent_email()
  from public, anon;
grant execute on function
  public.set_my_name(text), public.get_week(), public.submit_photo(text, text),
  public.remove_photo(uuid), public.cast_ballot(jsonb), public.get_results(date),
  public.get_winners(), public.set_stage(date, text), public.stage_of(date),
  public.require_kent(), public.is_kent(), public.current_week()
  to authenticated;

-- ---------- photo storage ---------------------------------------------------
-- Public bucket: anyone with a file's link can view it (links are random and
-- never show who uploaded). JPEG only, 10 MB max (the site resizes first).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 10485760, array['image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "potw upload into this week" on storage.objects;
create policy "potw upload into this week" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos'
              and public.is_kent()
              and (storage.foldername(name))[1] = public.current_week()::text);

drop policy if exists "potw see own uploads" on storage.objects;
create policy "potw see own uploads" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and owner_id = auth.uid()::text);

drop policy if exists "potw delete own uploads" on storage.objects;
create policy "potw delete own uploads" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and owner_id = auth.uid()::text);
