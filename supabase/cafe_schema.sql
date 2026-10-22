-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 스키마 설정 (K-Food 와 같은 Supabase 프로젝트)
--  ----------------------------------------------------------------
--  실행 위치: K-Food 가 쓰는 같은 Supabase 프로젝트 → SQL Editor 에 붙여넣고 실행
--  여러 번 실행해도 안전합니다(if not exists / on conflict).
--
--  실행 후 반드시 해야 할 일:
--    1) Dashboard → Project Settings → API → "Exposed schemas" 에
--       cafe 를 추가하고 저장 (kfr 도 계속 포함되어 있어야 함)
--    2) 아래 seed 의 관리자 PIN(0000)을 앱 '관리' 탭에서 바로 변경
-- ════════════════════════════════════════════════════════════════

-- ===== 1) cafe 스키마 =====
create schema if not exists cafe;
grant usage on schema cafe to anon, authenticated;

create table if not exists cafe.employees(
  id bigint generated always as identity primary key,
  name text not null, name_en text,
  role text not null default 'STAFF',      -- ADMIN / STAFF
  pin text not null, active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists cafe.attendance(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe.employees(id),
  date date not null,
  clock_in timestamptz, clock_out timestamptz,
  photo_path text,                          -- Storage 경로(출근 사진)
  lat double precision, lng double precision,
  distance_m integer,                       -- 매장과의 거리(m)
  verified boolean not null default false,  -- 지오펜스 통과 여부
  note text, created_at timestamptz not null default now()
);
create index if not exists attendance_date_idx on cafe.attendance(date);
create index if not exists attendance_emp_date_idx on cafe.attendance(employee_id, date);

create table if not exists cafe.menus(
  id text primary key, name text not null, name_en text,
  price numeric not null default 0, category text default 'GENERAL',
  sort integer not null default 0,
  active boolean not null default true
);
create table if not exists cafe.closings(
  id bigint generated always as identity primary key,
  date date not null unique, items jsonb not null default '{}'::jsonb,
  cash numeric not null default 0, gcash numeric not null default 0,
  note text, created_at timestamptz not null default now()
);
create table if not exists cafe.expenses(
  id bigint generated always as identity primary key,
  date date not null, category text, amount numeric not null default 0, note text
);
create table if not exists cafe.inventory_items(
  id bigint generated always as identity primary key,
  name text not null, name_en text, unit text default '개',
  stock numeric not null default 0, reorder_level numeric not null default 0,
  active boolean not null default true
);
create table if not exists cafe.inventory_moves(
  id bigint generated always as identity primary key,
  item_id bigint not null references cafe.inventory_items(id),
  type text not null,                       -- IN / OUT
  qty numeric not null default 0, date date not null default current_date,
  note text, employee_id bigint references cafe.employees(id),
  created_at timestamptz not null default now()
);
create table if not exists cafe.notes(
  id bigint generated always as identity primary key,
  author_employee_id bigint references cafe.employees(id),
  category text default 'GENERAL',          -- REQUEST(요청) / ISSUE(특이사항) / FIX(수정) / GENERAL
  title text, body text, photo_path text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists cafe.note_comments(
  id bigint generated always as identity primary key,
  note_id bigint not null references cafe.notes(id) on delete cascade,
  author_employee_id bigint references cafe.employees(id), body text,
  created_at timestamptz not null default now()
);
create table if not exists cafe.app_settings(key text primary key, value text);

-- 서버 시각 (출근 시각을 기기 시계가 아닌 서버 기준으로 기록할 때 사용)
create or replace function cafe.server_now() returns timestamptz
  language sql stable as $$ select now() $$;
grant execute on function cafe.server_now() to anon, authenticated;

-- ===== 2) kfr 스키마: K-Food 와 공유하는 공급요청 =====
create schema if not exists kfr;
grant usage on schema kfr to anon, authenticated;
create table if not exists kfr.supply_requests(
  id bigint generated always as identity primary key,
  source text not null default 'CAFE',      -- CAFE / REST(호점)
  requested_by text,                         -- 올린 사람/매장
  date date not null default current_date,
  items jsonb not null default '[]'::jsonb,  -- [{name, qty, unit}]
  status text not null default 'PENDING',    -- PENDING→APPROVED→CONFIRMED→SHIPPING→DELIVERED / REJECTED
  note text, approved_by text,
  created_at timestamptz not null default now()
);
create index if not exists supply_requests_status_idx on kfr.supply_requests(source, status);

-- ===== 3) 권한 + RLS (allow-all; 공개 anon 구조 — 민감정보 저장 금지) =====
grant all on all tables in schema cafe to anon, authenticated;
grant all on all sequences in schema cafe to anon, authenticated;
grant all on kfr.supply_requests to anon, authenticated;
grant all on all sequences in schema kfr to anon, authenticated;
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='cafe' loop
    execute format('alter table cafe.%I enable row level security;', t);
    execute format('drop policy if exists allow_all on cafe.%I;', t);
    execute format('create policy allow_all on cafe.%I for all using (true) with check (true);', t);
  end loop;
  execute 'alter table kfr.supply_requests enable row level security';
  execute 'drop policy if exists allow_all on kfr.supply_requests';
  execute 'create policy allow_all on kfr.supply_requests for all using (true) with check (true)';
end $$;

-- ===== 4) Storage 버킷 'cafe' (출근 사진 · 게시판 사진) =====
--  비공개 버킷: 사진은 signed URL 로 필요할 때만 불러옵니다(egress 절약).
insert into storage.buckets (id, name, public)
values ('cafe', 'cafe', false)
on conflict (id) do nothing;
drop policy if exists cafe_bucket_rw on storage.objects;
create policy cafe_bucket_rw on storage.objects for all to anon, authenticated
  using (bucket_id = 'cafe') with check (bucket_id = 'cafe');

-- ===== 5) 초기 데이터 =====
-- 첫 관리자 계정 (PIN 0000 → 로그인 후 '관리' 탭에서 반드시 변경)
insert into cafe.employees(name, name_en, role, pin)
select '사장', 'Owner', 'ADMIN', '0000'
where not exists (select 1 from cafe.employees where role = 'ADMIN');

-- 매장 좌표는 매장에서 앱으로 한 번 등록(관리 탭). 지오펜스 기본 100m.
insert into cafe.app_settings(key, value) values
  ('geofence_m', '100'),
  ('photo_retention_days', '90')
on conflict (key) do nothing;

-- ⚠️ 실행 후: Settings → API → Exposed schemas 에 'cafe'(및 'kfr') 포함
