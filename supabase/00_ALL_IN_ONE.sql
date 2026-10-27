-- ════════════════════════════════════════════════════════════════
--  Bahayy Cafe — 전체 설정 한 번에 (00_ALL_IN_ONE.sql)
--  cafe_schema.sql ~ 10_test_mode.sql 을 순서대로 합친 파일입니다.
--  여러 번 실행해도 안전합니다: 기존 데이터(출퇴근·매출·재고·메모 등)는 지우지 않고,
--  빠진 표·칸·규칙만 채우고, 규칙(트리거)은 최신 버전으로 맞춥니다.
--  (직원 모드 테스트 공간 cafe_test 의 연습 기록만 초기화됩니다)
--  SQL Editor 에 전체를 붙여넣고 Run.
-- ════════════════════════════════════════════════════════════════

-- ════════ cafe_schema.sql ════════
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


-- ════════ 02_attendance.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 2단계: 출퇴근 인증 (cafe_schema.sql 실행 후 실행)
--  여러 번 실행해도 안전합니다.
--
--  핵심: 시각·거리·인증여부는 "서버(DB)"가 정합니다.
--   · clock_in / clock_out = DB의 now()  (폰 시계를 바꿔도 소용없음)
--   · date = 필리핀 시간 기준 영업일
--   · distance_m / verified = 매장 좌표(app_settings)와의 거리를 DB가 계산
-- ════════════════════════════════════════════════════════════════

alter table cafe.attendance
  add column if not exists accuracy_m integer,             -- GPS 정확도(±m)
  add column if not exists out_lat double precision,       -- 퇴근 위치
  add column if not exists out_lng double precision,
  add column if not exists out_distance_m integer,
  add column if not exists manual_edit boolean not null default false; -- 사장이 퇴근시각 수동 입력

-- 두 좌표 사이 거리(m, haversine)
create or replace function cafe.geo_distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns integer language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::integer
$$;

create or replace function cafe.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer;
begin
  select nullif(value, '')::float8 into slat from cafe.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);

  if tg_op = 'INSERT' then
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음
  new.clock_in   := old.clock_in;
  new.date       := old.date;
  new.photo_path := old.photo_path;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.manual_edit then
    -- 사장이 퇴근 누락을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and new.clock_out < old.clock_in then
      raise exception '퇴근 시각이 출근 시각보다 빠릅니다';
    end if;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe.attendance;
create trigger attendance_guard before insert or update on cafe.attendance
  for each row execute function cafe.attendance_guard();

create index if not exists attendance_open_idx on cafe.attendance(employee_id) where clock_out is null;


-- ════════ 03_board.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 3단계: 게시판 · 댓글 · 안 읽음 표시 (02_attendance.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
-- ════════════════════════════════════════════════════════════════

-- 글의 "마지막 활동"(작성/댓글) — 안 읽음 계산과 피드 정렬에 사용
alter table cafe.notes
  add column if not exists last_activity_at timestamptz not null default now(),
  add column if not exists last_activity_by bigint references cafe.employees(id);
update cafe.notes set last_activity_by = author_employee_id where last_activity_by is null;
create index if not exists notes_activity_idx on cafe.notes(last_activity_at desc);
create index if not exists note_comments_note_idx on cafe.note_comments(note_id);

-- 직원별 "어디까지 읽었나"
create table if not exists cafe.note_reads(
  note_id bigint not null references cafe.notes(id) on delete cascade,
  employee_id bigint not null references cafe.employees(id),
  last_read_at timestamptz not null default now(),
  primary key (note_id, employee_id)
);

-- 시각은 모두 서버 기준
create or replace function cafe.note_init() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.last_activity_at := now();
  new.last_activity_by := new.author_employee_id;
  return new;
end $$;
drop trigger if exists note_init on cafe.notes;
create trigger note_init before insert on cafe.notes
  for each row execute function cafe.note_init();

create or replace function cafe.note_comment_touch() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  update cafe.notes set last_activity_at = now(), last_activity_by = new.author_employee_id
   where id = new.note_id;
  return new;
end $$;
drop trigger if exists note_comment_touch on cafe.note_comments;
create trigger note_comment_touch before insert on cafe.note_comments
  for each row execute function cafe.note_comment_touch();

create or replace function cafe.note_read_now() returns trigger language plpgsql as $$
begin
  new.last_read_at := now();
  return new;
end $$;
drop trigger if exists note_read_now on cafe.note_reads;
create trigger note_read_now before insert or update on cafe.note_reads
  for each row execute function cafe.note_read_now();

-- 권한 + RLS (allow-all)
grant all on cafe.note_reads to anon, authenticated;
alter table cafe.note_reads enable row level security;
drop policy if exists allow_all on cafe.note_reads;
create policy allow_all on cafe.note_reads for all using (true) with check (true);


-- ════════ 04_inventory.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 4단계: 재고 (03_board.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  현재고(inventory_items.stock)는 입출고 장부(inventory_moves)로만 바뀝니다.
--   · IN     입고  : stock + qty
--   · OUT    출고  : stock - qty
--   · ADJUST 실사  : stock = qty (세어 본 실제 수량)
--  장부 한 줄을 지우면 그만큼 되돌립니다. 날짜·시각은 서버(필리핀) 기준.
-- ════════════════════════════════════════════════════════════════

alter table cafe.inventory_moves
  add column if not exists delta numeric,        -- 실제 증감 (ADJUST 포함)
  add column if not exists stock_after numeric;  -- 기록 직후 재고
alter table cafe.inventory_items
  add column if not exists sort integer not null default 0;
create index if not exists inventory_moves_item_idx on cafe.inventory_moves(item_id, id desc);

create or replace function cafe.inventory_move_apply() returns trigger
language plpgsql as $$
declare cur numeric;
begin
  if tg_op = 'DELETE' then
    update cafe.inventory_items set stock = stock - coalesce(old.delta, 0) where id = old.item_id;
    return old;
  end if;

  select stock into cur from cafe.inventory_items where id = new.item_id for update;
  if not found then raise exception '품목을 찾을 수 없습니다'; end if;
  if new.type not in ('IN', 'OUT', 'ADJUST') then raise exception '구분은 IN/OUT/ADJUST'; end if;
  if new.qty is null or new.qty < 0 or (new.type <> 'ADJUST' and new.qty = 0) then
    raise exception '수량을 확인하세요';
  end if;

  new.delta := case new.type when 'IN' then new.qty when 'OUT' then -new.qty else new.qty - cur end;
  new.stock_after := cur + new.delta;
  new.date := (now() at time zone 'Asia/Manila')::date;
  new.created_at := now();
  update cafe.inventory_items set stock = new.stock_after where id = new.item_id;
  return new;
end $$;

drop trigger if exists inventory_move_apply on cafe.inventory_moves;
create trigger inventory_move_apply before insert on cafe.inventory_moves
  for each row execute function cafe.inventory_move_apply();
drop trigger if exists inventory_move_undo on cafe.inventory_moves;
create trigger inventory_move_undo after delete on cafe.inventory_moves
  for each row execute function cafe.inventory_move_apply();

-- 장부는 수정 불가 (틀리면 지우고 다시 기록)
create or replace function cafe.inventory_move_no_update() returns trigger
language plpgsql as $$ begin raise exception '장부는 수정할 수 없습니다. 삭제 후 다시 기록하세요.'; end $$;
drop trigger if exists inventory_move_no_update on cafe.inventory_moves;
create trigger inventory_move_no_update before update on cafe.inventory_moves
  for each row execute function cafe.inventory_move_no_update();

-- 공급요청: 결정(승인/반려) 시각
alter table kfr.supply_requests add column if not exists decided_at timestamptz;
create index if not exists supply_requests_created_idx on kfr.supply_requests(source, created_at desc);


-- ════════ 05_kfood_link.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe ↔ K-Food — 5단계: 공급요청 연동 (04_inventory.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  kfr.supply_requests 상태 흐름 (서버가 강제)
--    PENDING ──승인(카페 사장)──▶ APPROVED ──K-Food──▶ CONFIRMED ──▶ SHIPPING ──▶ DELIVERED
--        └──반려──▶ REJECTED
--  · K-Food 담당자는 한 단계 앞으로, 또는 실수 시 한 단계 뒤로만 이동 가능
--  · 카페에서 '입고 처리'(received_at)를 한 건은 더 이상 되돌릴 수 없음
--  · 시각(status_at, decided_at, received_at)은 서버 now()
-- ════════════════════════════════════════════════════════════════

alter table kfr.supply_requests
  add column if not exists decided_at timestamptz,
  add column if not exists status_at timestamptz,   -- 마지막 상태 변경 시각
  add column if not exists received_at timestamptz; -- 카페 재고에 입고 처리한 시각
update kfr.supply_requests set status_at = coalesce(decided_at, created_at) where status_at is null;
create index if not exists supply_requests_status_at_idx on kfr.supply_requests(status, status_at desc);

create or replace function kfr.supply_request_guard() returns trigger
language plpgsql as $$
declare
  flow text[] := array['APPROVED','CONFIRMED','SHIPPING','DELIVERED'];
  i int; j int;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status_at  := now();
    new.received_at := null;
    return new;
  end if;

  -- 입고 처리: 배송완료 건에 한 번만
  if new.received_at is distinct from old.received_at then
    if old.received_at is not null then raise exception '이미 입고 처리된 요청입니다'; end if;
    if new.status <> 'DELIVERED' then raise exception '배송완료 후에 입고 처리할 수 있습니다'; end if;
    new.received_at := now();
  end if;

  if new.status is distinct from old.status then
    if old.received_at is not null then raise exception '입고 처리된 요청은 상태를 바꿀 수 없습니다'; end if;
    if old.status = 'PENDING' and new.status in ('APPROVED','REJECTED') then
      new.decided_at := now();
    else
      i := array_position(flow, old.status);
      j := array_position(flow, new.status);
      if i is null or j is null or abs(j - i) <> 1 then
        raise exception '상태를 % → % 로 바꿀 수 없습니다', old.status, new.status;
      end if;
    end if;
    new.status_at := now();
  end if;
  return new;
end $$;

drop trigger if exists supply_request_guard on kfr.supply_requests;
create trigger supply_request_guard before insert or update on kfr.supply_requests
  for each row execute function kfr.supply_request_guard();


-- ════════ 06_sales.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 6단계: 마감 · 매출 · 지출 (05_kfood_link.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  closings.items 형식: { "<menu_id>": {"q": 수량, "p": 판매단가}, "_free": {"<menu_id>": 수량} }
--   · 단가를 함께 저장하므로 나중에 메뉴 가격을 바꿔도 지난 매출이 변하지 않습니다.
-- ════════════════════════════════════════════════════════════════

alter table cafe.closings
  add column if not exists card numeric not null default 0,      -- 카드/기타 결제
  add column if not exists closed_by bigint references cafe.employees(id),
  add column if not exists updated_at timestamptz;
alter table cafe.expenses
  add column if not exists created_by bigint references cafe.employees(id),
  add column if not exists created_at timestamptz not null default now();
create index if not exists closings_date_idx on cafe.closings(date);
create index if not exists expenses_date_idx on cafe.expenses(date);

-- 하루 한 건 (cafe_schema.sql 에서 unique 로 만들었지만, 예전 테이블이면 여기서 보장)
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'cafe.closings'::regclass and contype = 'u') then
    alter table cafe.closings add constraint closings_date_key unique (date);
  end if;
end $$;

create or replace function cafe.closing_stamp() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  new.updated_at := now();
  if new.date > (now() at time zone 'Asia/Manila')::date then
    raise exception '미래 날짜는 마감할 수 없습니다';
  end if;
  return new;
end $$;
drop trigger if exists closing_stamp on cafe.closings;
create trigger closing_stamp before insert or update on cafe.closings
  for each row execute function cafe.closing_stamp();


-- ════════ 07_photo_cleanup.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 출근 사진 자동 정리 (06_sales.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  · 보관기간: app_settings.photo_retention_days (기본 90일, 최소 30일)
--  · 사장님이 앱을 열면 하루 한 번, 기간이 지난 출근 사진을 Storage 에서 지우고
--    기록의 photo_path 를 비웁니다. 출퇴근 시각·위치·✅ 기록은 그대로 남습니다.
--  · DB 는 보관기간이 지난 기록만 사진을 비울 수 있게 막습니다(최근 증거 보호).
-- ════════════════════════════════════════════════════════════════

alter table cafe.attendance add column if not exists photo_purged_at timestamptz;
create index if not exists attendance_photo_idx on cafe.attendance(date) where photo_path is not null;

create or replace function cafe.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' then
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음
  new.clock_in   := old.clock_in;
  new.date       := old.date;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.manual_edit then
    -- 사장이 퇴근 누락을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and new.clock_out < old.clock_in then
      raise exception '퇴근 시각이 출근 시각보다 빠릅니다';
    end if;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe.attendance;
create trigger attendance_guard before insert or update on cafe.attendance
  for each row execute function cafe.attendance_guard();


-- ════════ 08_field_update.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 8단계: 현장 피드백 반영 (07_photo_cleanup.sql 다음에 실행)
--  여러 번 실행해도 안전합니다. 이미 같은 이름의 메뉴/품목이 있으면 새로 넣지 않습니다.
--
--   1) 메뉴판 전체 + 모조스·감자튀김 + 바하이 세트(500)
--   2) 물품 신청 리스트(음료/디저트/음식/기타용품 · 세부 그룹) = 재고 품목
--      퇴근 전 재고 확인 품목: 우유·감자·산도·머핀·로투스·레몬파운드·파스타 면
--   3) 판매 → 재고 자동 차감(메뉴별 사용량) + 퇴근 전 재고 확인 기록
--   4) 직원 급여: 일급(기본 508)·근무시간·근무시간표 → 지각/조퇴 차감, 15일·말일 2회 지급
--   5) 퇴근 전 청소 사진(매장·야외·주방·화장실)
--   6) 마감에 유입 경로(릴스·전단지·지나가다가) 기록
-- ════════════════════════════════════════════════════════════════

-- ── 직원 급여 기준 ──
alter table cafe.employees
  add column if not exists daily_rate numeric not null default 508,   -- 하루(기준시간) 급여
  add column if not exists std_hours numeric not null default 8,      -- 하루 기준 근무시간
  add column if not exists shift_start time not null default '09:00', -- 출근 시각
  add column if not exists shift_end time not null default '18:00',   -- 퇴근 시각
  add column if not exists break_min integer not null default 60;     -- 휴게(5시간 넘게 근무 시 차감)

-- ── 출퇴근: 사장 수정/수동 추가 ──
alter table cafe.attendance
  add column if not exists admin_edit boolean not null default false,  -- 이번 저장이 사장 수정인지(저장 후 자동 false)
  add column if not exists orig_clock_in timestamptz;                  -- 수정 전 원래 출근 시각

create or replace function cafe.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' and new.admin_edit and new.clock_in is not null then
    -- 사장이 빠진 근무를 수동 추가 (사진·위치 없음, '수정됨' 표시)
    if new.clock_in > now() or (new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now())) then
      raise exception '시각을 확인하세요';
    end if;
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
    new.manual_edit := true; new.admin_edit := false;
    new.photo_path := null; new.photo_purged_at := null; new.orig_clock_in := null;
    new.lat := null; new.lng := null; new.accuracy_m := null; new.distance_m := null; new.verified := false;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.admin_edit  := false;
    new.orig_clock_in := null;
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음 — 사장 수정(admin_edit)만 시각 변경 가능
  if new.admin_edit and new.clock_in is distinct from old.clock_in then
    if new.clock_in is null or new.clock_in > now() then raise exception '출근 시각을 확인하세요'; end if;
    new.orig_clock_in := coalesce(old.orig_clock_in, old.clock_in);
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
  else
    new.clock_in := old.clock_in;
    new.date     := old.date;
    new.orig_clock_in := old.orig_clock_in;
  end if;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.admin_edit then
    -- 사장이 출퇴근 시각을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now()) then
      raise exception '퇴근 시각을 확인하세요';
    end if;
    new.manual_edit := true;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  if not new.admin_edit then new.manual_edit := old.manual_edit; end if;
  new.admin_edit := false;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe.attendance;
create trigger attendance_guard before insert or update on cafe.attendance
  for each row execute function cafe.attendance_guard();

-- ── 청소 사진 (퇴근 전 매장·야외·주방·화장실) ──
create table if not exists cafe.clean_photos(
  id bigint generated always as identity primary key,
  attendance_id bigint not null references cafe.attendance(id) on delete cascade,
  employee_id bigint references cafe.employees(id),
  area text not null,                       -- STORE / OUTSIDE / KITCHEN / RESTROOM
  photo_path text,
  photo_purged_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists clean_photos_att_idx on cafe.clean_photos(attendance_id);
create or replace function cafe.clean_photo_guard() returns trigger language plpgsql as $$
declare keep integer;
begin
  select nullif(value, '')::integer into keep from cafe.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));
  if tg_op = 'INSERT' then new.created_at := now(); new.photo_purged_at := null; return new; end if;
  if tg_op = 'DELETE' then
    if old.created_at > now() - make_interval(days => keep) then raise exception '보관기간 중인 사진은 지울 수 없습니다'; end if;
    return old;
  end if;
  if old.photo_path is not null and new.photo_path is null and old.created_at < now() - make_interval(days => keep) then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path; new.photo_purged_at := old.photo_purged_at;
  end if;
  new.attendance_id := old.attendance_id; new.area := old.area; new.created_at := old.created_at; new.employee_id := old.employee_id;
  return new;
end $$;
drop trigger if exists clean_photo_guard on cafe.clean_photos;
create trigger clean_photo_guard before insert or update or delete on cafe.clean_photos
  for each row execute function cafe.clean_photo_guard();

-- ── 급여: 기타 지급/공제, 지급 기록 ──
create table if not exists cafe.pay_adjustments(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe.employees(id),
  date date not null,
  kind text not null default 'PLUS',        -- PLUS(기타 지급) / MINUS(공제)
  amount numeric not null default 0,
  note text,
  created_by bigint references cafe.employees(id),
  created_at timestamptz not null default now()
);
create table if not exists cafe.payroll_runs(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe.employees(id),
  period_start date not null, period_end date not null,
  days integer, regular_hours numeric, ot_hours numeric, late_min integer,
  basic numeric, ot_pay numeric, other_pay numeric, deductions numeric, net numeric,
  details jsonb,
  expense_id bigint references cafe.expenses(id) on delete set null,
  paid_by bigint references cafe.employees(id),
  paid_at timestamptz not null default now(),
  unique (employee_id, period_start)
);

-- ── 재고 품목: 분류·세부 그룹·매일 확인 ──
alter table cafe.inventory_items
  add column if not exists category text,                       -- DRINK / DESSERT / FOOD / SUPPLY
  add column if not exists groups text[] not null default '{}', -- 예: {DRINK/커피, DRINK/프라페}
  add column if not exists daily_check boolean not null default false;
alter table cafe.inventory_moves add column if not exists ref text;  -- sale:YYYY-MM-DD / check:YYYY-MM-DD
create index if not exists inventory_moves_ref_idx on cafe.inventory_moves(ref);

-- 판매 1개당 재고 사용량 (마감 저장 시 자동 출고)
create table if not exists cafe.menu_usage(
  menu_id text not null references cafe.menus(id) on delete cascade,
  item_id bigint not null references cafe.inventory_items(id) on delete cascade,
  qty numeric not null default 1,
  primary key (menu_id, item_id)
);
-- 퇴근 전 재고 확인 기록
create table if not exists cafe.stock_checks(
  id bigint generated always as identity primary key,
  date date not null default current_date,
  item_id bigint not null references cafe.inventory_items(id),
  expected numeric, counted numeric, diff numeric,
  employee_id bigint references cafe.employees(id),
  created_at timestamptz not null default now()
);
create index if not exists stock_checks_date_idx on cafe.stock_checks(date);
create or replace function cafe.stock_check_stamp() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.date := (now() at time zone 'Asia/Manila')::date;
  new.diff := coalesce(new.counted, 0) - coalesce(new.expected, 0);
  return new;
end $$;
drop trigger if exists stock_check_stamp on cafe.stock_checks;
create trigger stock_check_stamp before insert on cafe.stock_checks
  for each row execute function cafe.stock_check_stamp();

-- ── 마감: 유입 경로 ──
alter table cafe.closings add column if not exists sources jsonb not null default '{}'::jsonb;  -- {REELS:n, FLYER:n, WALKIN:n, OTHER:n}

-- ── 권한 + RLS (새 테이블 포함) ──
grant all on all tables in schema cafe to anon, authenticated;
grant all on all sequences in schema cafe to anon, authenticated;
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='cafe' loop
    execute format('alter table cafe.%I enable row level security;', t);
    execute format('drop policy if exists allow_all on cafe.%I;', t);
    execute format('create policy allow_all on cafe.%I for all using (true) with check (true);', t);
  end loop;
end $$;

-- ── 메뉴판 ──
insert into cafe.menus(id, name, name_en, price, category, sort)
select v.* from (values
  ('c_americano','아메리카노','Americano',140,'COFFEE',1),
  ('c_latte','카페라떼','Cafe Latte',170,'COFFEE',2),
  ('c_spanish','스패니시 라떼','Spanish Latte',180,'COFFEE',3),
  ('c_vanilla','바닐라 라떼','Vanila Latte',190,'COFFEE',4),
  ('c_caramel','카라멜 라떼','Caramel Latte',190,'COFFEE',5),
  ('c_espresso','에스프레소','Espresso',100,'COFFEE',6),
  ('c_maxim','한국 맥심 라떼','Korea Maxim Latte',200,'COFFEE',7),
  ('c_affogato','아포가토','Affogato',190,'COFFEE',8),
  ('f_vanilla','바닐라 프라페','Vanila Frappe',160,'FRAPPE',9),
  ('f_cookie','쿠키앤크림 프라페','Cookie&Cream Frappe',180,'FRAPPE',10),
  ('f_matcha','말차 프라페','Matcha Frappe',190,'FRAPPE',11),
  ('f_mocha','모카 프라페','Mocha Frappe',190,'FRAPPE',12),
  ('f_biscuit','비스킷 프라페','Biscuit Frappe',190,'FRAPPE',13),
  ('s_pinkmatcha','핑크 말차 라떼','Pink Matcha Latte',220,'SIGNATURE',14),
  ('s_bluecream','블루 크림 라떼','Blue Cream Latte',200,'SIGNATURE',15),
  ('n_lemonade','레몬에이드','Lemonade',190,'NONCOFFEE',16),
  ('n_icetea','아이스티','Ice Tea',120,'NONCOFFEE',17),
  ('p_tomato','토마토 파스타','Tomato Pasta',180,'PASTA',18),
  ('p_cream','크림 파스타','Cream Pasta',180,'PASTA',19),
  ('p_pesto','페스토 파스타','Pesto Pasta',190,'PASTA',20),
  ('set_bahayy','바하이 세트 (파스타+산도+음료)','Bahayy Set (Pasta + Sando + Drink)',500,'SET',21),
  ('d_sando','산도','Sando',200,'DESSERT',22),
  ('d_lotus','로투스 치즈케이크','Lotus Cheese Cake',160,'DESSERT',23),
  ('d_cookie','쿠키','Cookie',120,'DESSERT',24),
  ('d_brownie','초코 브라우니','Chocolate Brownie',160,'DESSERT',25),
  ('d_muffin','머핀','Muffin',160,'DESSERT',26),
  ('d_lemonpound','레몬 파운드케이크','Lemon Pound Cake',150,'DESSERT',27),
  ('x_mojos','모조스','Mojos',140,'FOOD',28),
  ('x_fries','감자튀김','Fries',120,'FOOD',29)
) as v(id, name, name_en, price, category, sort)
where not exists (select 1 from cafe.menus m where m.id = v.id or m.name = v.name or lower(m.name_en) = lower(v.name_en));

-- ── 물품(재고) 목록 ──
insert into cafe.inventory_items(name, name_en, unit, daily_check, category, groups, sort)
select v.* from (values
  ('우유','Milk','팩',true,'DRINK',array['DRINK/커피','DRINK/프라페','DRINK/음료','DESSERT/로투스 치즈케이크']::text[],1),
  ('커피콩','Coffee beans','kg',false,'DRINK',array['DRINK/커피']::text[],2),
  ('물','Water','통',false,'DRINK',array['DRINK/커피','SUPPLY/음식관련']::text[],3),
  ('바닐라시럽','Vanilla syrup','병',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],4),
  ('연유','Condensed milk','캔',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],5),
  ('카라멜 시럽','Caramel syrup','병',false,'DRINK',array['DRINK/커피']::text[],6),
  ('맥심커피','Maxim coffee mix','박스',false,'DRINK',array['DRINK/커피']::text[],7),
  ('코코아가루','Cocoa powder','봉지',false,'DRINK',array['DRINK/커피','DRINK/프라페','DESSERT/브라우니']::text[],8),
  ('아이스크림','Ice cream','통',false,'DRINK',array['DRINK/커피','DESSERT/쿠키','DESSERT/브라우니']::text[],9),
  ('스틱오 (초코)','Stick-O (choco)','통',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],10),
  ('크림파우더','Cream powder','봉지',false,'DRINK',array['DRINK/프라페']::text[],11),
  ('생크림 가스총','Whipped cream charger','개',false,'DRINK',array['DRINK/프라페']::text[],12),
  ('오레오쿠키','Oreo cookies','팩',false,'DRINK',array['DRINK/프라페']::text[],13),
  ('오레오크럼블','Oreo crumble','봉지',false,'DRINK',array['DRINK/프라페']::text[],14),
  ('초코시럽','Chocolate syrup','병',false,'DRINK',array['DRINK/프라페','DESSERT/브라우니']::text[],15),
  ('말차파우더','Matcha powder','봉지',false,'DRINK',array['DRINK/프라페','DRINK/음료']::text[],16),
  ('비스킷','Biscuits','팩',false,'DRINK',array['DRINK/프라페','DESSERT/로투스 치즈케이크']::text[],17),
  ('비스킷크럼블','Biscuit crumble','봉지',false,'DRINK',array['DRINK/프라페','DESSERT/로투스 치즈케이크']::text[],18),
  ('생크림','Whipping cream','팩',false,'DRINK',array['DRINK/음료','DESSERT/산도','DESSERT/로투스 치즈케이크','DESSERT/머핀']::text[],19),
  ('식용색소 (핑크)','Food coloring (pink)','병',false,'DRINK',array['DRINK/음료']::text[],20),
  ('레몬에이드시럽','Lemonade syrup','병',false,'DRINK',array['DRINK/음료']::text[],21),
  ('스프라이트','Sprite','병',false,'DRINK',array['DRINK/음료']::text[],22),
  ('레몬','Lemon','개',false,'DRINK',array['DRINK/음료','DESSERT/레몬파운드케이크']::text[],23),
  ('샤인머스켓','Shine muscat','송이',false,'DRINK',array['DRINK/음료','DESSERT/산도']::text[],24),
  ('아이스티가루','Iced tea powder','봉지',false,'DRINK',array['DRINK/음료']::text[],25),
  ('산도 (완성품)','Sando (ready)','개',true,'DESSERT',array['DESSERT/산도']::text[],26),
  ('식빵','Sliced bread','봉지',false,'DESSERT',array['DESSERT/산도']::text[],27),
  ('크림치즈','Cream cheese','개',false,'DESSERT',array['DESSERT/산도','DESSERT/로투스 치즈케이크']::text[],28),
  ('설탕','Sugar','kg',false,'DESSERT',array['DESSERT/산도','DESSERT/로투스 치즈케이크']::text[],29),
  ('키위','Kiwi','개',false,'DESSERT',array['DESSERT/산도']::text[],30),
  ('망고','Mango','개',false,'DESSERT',array['DESSERT/산도']::text[],31),
  ('오렌지','Orange','개',false,'DESSERT',array['DESSERT/산도']::text[],32),
  ('로투스 치즈케이크 (완성품)','Lotus cheesecake (ready)','개',true,'DESSERT',array['DESSERT/로투스 치즈케이크']::text[],33),
  ('로투스잼','Lotus spread','병',false,'DESSERT',array['DESSERT/로투스 치즈케이크']::text[],34),
  ('레몬즙','Lemon juice','병',false,'DESSERT',array['DESSERT/로투스 치즈케이크','FOOD/모조스','DESSERT/레몬파운드케이크']::text[],35),
  ('S&R 쿠키','S&R cookies','개',false,'DESSERT',array['DESSERT/쿠키']::text[],36),
  ('S&R 브라우니','S&R brownies','개',false,'DESSERT',array['DESSERT/브라우니']::text[],37),
  ('머핀 (S&R)','Muffin (S&R)','개',true,'DESSERT',array['DESSERT/머핀']::text[],38),
  ('레몬 파운드케이크 (완성품)','Lemon pound cake (ready)','조각',true,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],39),
  ('S&R 파운드케이크','S&R pound cake','개',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],40),
  ('슈가파우더','Powdered sugar','봉지',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],41),
  ('허브','Herbs','팩',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],42),
  ('파스타 면','Pasta noodles','통',true,'FOOD',array['FOOD/파스타']::text[],43),
  ('마늘','Garlic','개',false,'FOOD',array['FOOD/파스타']::text[],44),
  ('양파','Onion','개',false,'FOOD',array['FOOD/파스타']::text[],45),
  ('식용유','Cooking oil','병',false,'FOOD',array['FOOD/파스타','FOOD/모조스','FOOD/감자튀김']::text[],46),
  ('베이컨','Bacon','팩',false,'FOOD',array['FOOD/파스타']::text[],47),
  ('햄','Ham','팩',false,'FOOD',array['FOOD/파스타']::text[],48),
  ('토마토소스','Tomato sauce','병',false,'FOOD',array['FOOD/파스타']::text[],49),
  ('크림소스','Cream sauce','병',false,'FOOD',array['FOOD/파스타']::text[],50),
  ('페스토소스','Pesto sauce','병',false,'FOOD',array['FOOD/파스타']::text[],51),
  ('소금','Salt','봉지',false,'FOOD',array['FOOD/파스타']::text[],52),
  ('후추','Pepper','병',false,'FOOD',array['FOOD/파스타']::text[],53),
  ('MSG','MSG','봉지',false,'FOOD',array['FOOD/파스타']::text[],54),
  ('슬라이스치즈','Sliced cheese','팩',false,'FOOD',array['FOOD/파스타']::text[],55),
  ('감자','Potatoes','개',true,'FOOD',array['FOOD/모조스']::text[],56),
  ('계란','Eggs','판',false,'FOOD',array['FOOD/모조스']::text[],57),
  ('밀가루','Flour','kg',false,'FOOD',array['FOOD/모조스']::text[],58),
  ('갈릭파우더','Garlic powder','봉지',false,'FOOD',array['FOOD/모조스']::text[],59),
  ('머스타드소스','Mustard sauce','병',false,'FOOD',array['FOOD/모조스']::text[],60),
  ('스틱감자','Frozen fries','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],61),
  ('케찹','Ketchup','병',false,'FOOD',array['FOOD/감자튀김']::text[],62),
  ('마요네즈','Mayonnaise','병',false,'FOOD',array['FOOD/감자튀김']::text[],63),
  ('치즈파우더','Cheese powder','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],64),
  ('어니언파우더','Onion powder','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],65),
  ('일회용컵','Disposable cups','줄',false,'SUPPLY',array['SUPPLY/음식관련']::text[],66),
  ('일회용컵 뚜껑','Cup lids','줄',false,'SUPPLY',array['SUPPLY/음식관련']::text[],67),
  ('빨대','Straws','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],68),
  ('포장용기','Takeout containers','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],69),
  ('소스포장용기','Sauce cups','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],70),
  ('샌드위치 비닐랩','Sandwich wrap','롤',false,'SUPPLY',array['SUPPLY/음식관련']::text[],71),
  ('일회용장갑','Disposable gloves','박스',false,'SUPPLY',array['SUPPLY/음식관련']::text[],72),
  ('키친타올','Kitchen towel','롤',false,'SUPPLY',array['SUPPLY/음식관련']::text[],73),
  ('물티슈','Wet wipes','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],74),
  ('소스통','Sauce bottles','개',false,'SUPPLY',array['SUPPLY/음식관련']::text[],75),
  ('설거지 퐁퐁','Dish soap','병',false,'SUPPLY',array['SUPPLY/청소관련']::text[],76),
  ('수세미','Sponges','개',false,'SUPPLY',array['SUPPLY/청소관련']::text[],77),
  ('락스','Bleach','병',false,'SUPPLY',array['SUPPLY/청소관련']::text[],78),
  ('쓰레기봉투','Trash bags','팩',false,'SUPPLY',array['SUPPLY/청소관련']::text[],79),
  ('두루마리 휴지','Toilet roll','롤',false,'SUPPLY',array['SUPPLY/매장관련']::text[],80),
  ('건전지','Batteries','개',false,'SUPPLY',array['SUPPLY/매장관련']::text[],81),
  ('전단지','Flyers','장',false,'SUPPLY',array['SUPPLY/매장관련']::text[],82),
  ('화장실용 휴지','Restroom tissue','팩',false,'SUPPLY',array['SUPPLY/매장관련']::text[],83)
) as v(name, name_en, unit, daily_check, category, groups, sort)
where not exists (select 1 from cafe.inventory_items i where i.name = v.name);

-- ── 판매 시 자동 차감 (1:1 품목만 기본 설정, 나머지는 앱 '품목 관리'에서) ──
insert into cafe.menu_usage(menu_id, item_id, qty)
select v.menu_id, i.id, v.qty from (values
  ('d_sando','산도 (완성품)',1),
  ('set_bahayy','산도 (완성품)',1),
  ('d_lotus','로투스 치즈케이크 (완성품)',1),
  ('d_muffin','머핀 (S&R)',1),
  ('d_lemonpound','레몬 파운드케이크 (완성품)',1)
) as v(menu_id, item_name, qty)
join cafe.inventory_items i on i.name = v.item_name
join cafe.menus m on m.id = v.menu_id
on conflict do nothing;

-- ── 기본 설정 ──
insert into cafe.app_settings(key, value) values
  ('ot_enabled', '1'), ('ot_multiplier', '1'), ('clean_photos_required', '1')
on conflict (key) do nothing;


-- ════════ 09_fixes.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahayy Cafe — 9: 검수 수정 (08_field_update.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--   1) 퇴근을 잊은 근무(16시간 초과)는 직원이 '지금' 퇴근 처리할 수 없음 → 사장님이 시각 입력
--   2) 공급요청은 항상 '승인 대기'로만 새로 만들 수 있음
--   3) 마감 저장 시 판매분 재고 차감을 DB 안에서 한 번에(동시 저장에도 두 번 빠지지 않게)
-- ════════════════════════════════════════════════════════════════

create or replace function cafe.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' and new.admin_edit and new.clock_in is not null then
    -- 사장이 빠진 근무를 수동 추가 (사진·위치 없음, '수정됨' 표시)
    if new.clock_in > now() or (new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now())) then
      raise exception '시각을 확인하세요';
    end if;
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
    new.manual_edit := true; new.admin_edit := false;
    new.photo_path := null; new.photo_purged_at := null; new.orig_clock_in := null;
    new.lat := null; new.lng := null; new.accuracy_m := null; new.distance_m := null; new.verified := false;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.admin_edit  := false;
    new.orig_clock_in := null;
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음 — 사장 수정(admin_edit)만 시각 변경 가능
  if new.admin_edit and new.clock_in is distinct from old.clock_in then
    if new.clock_in is null or new.clock_in > now() then raise exception '출근 시각을 확인하세요'; end if;
    new.orig_clock_in := coalesce(old.orig_clock_in, old.clock_in);
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
  else
    new.clock_in := old.clock_in;
    new.date     := old.date;
    new.orig_clock_in := old.orig_clock_in;
  end if;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.admin_edit then
    -- 사장이 출퇴근 시각을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now()) then
      raise exception '퇴근 시각을 확인하세요';
    end if;
    new.manual_edit := true;
  elsif old.clock_out is null and new.clock_out is not null then
    -- 퇴근을 잊은 지난 근무를 다음 날 '지금' 시각으로 닫으면 OT 가 수십 시간 생김 → 사장님이 입력하도록
    if now() - old.clock_in > interval '16 hours' then
      raise exception '지난 근무는 퇴근 시각을 사장님이 입력해야 합니다 (근태 탭)';
    end if;
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  if not new.admin_edit then new.manual_edit := old.manual_edit; end if;
  new.admin_edit := false;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe.attendance;
create trigger attendance_guard before insert or update on cafe.attendance
  for each row execute function cafe.attendance_guard();

create or replace function kfr.supply_request_guard() returns trigger
language plpgsql as $$
declare
  flow text[] := array['APPROVED','CONFIRMED','SHIPPING','DELIVERED'];
  i int; j int;
begin
  if tg_op = 'INSERT' then
    new.status := 'PENDING';      -- 새 요청은 항상 승인 대기에서 시작
    new.decided_at := null;
    new.approved_by := null;
    new.created_at := now();
    new.status_at  := now();
    new.received_at := null;
    return new;
  end if;

  -- 입고 처리: 배송완료 건에 한 번만
  if new.received_at is distinct from old.received_at then
    if old.received_at is not null then raise exception '이미 입고 처리된 요청입니다'; end if;
    if new.status <> 'DELIVERED' then raise exception '배송완료 후에 입고 처리할 수 있습니다'; end if;
    new.received_at := now();
  end if;

  if new.status is distinct from old.status then
    if old.received_at is not null then raise exception '입고 처리된 요청은 상태를 바꿀 수 없습니다'; end if;
    if old.status = 'PENDING' and new.status in ('APPROVED','REJECTED') then
      new.decided_at := now();
    else
      i := array_position(flow, old.status);
      j := array_position(flow, new.status);
      if i is null or j is null or abs(j - i) <> 1 then
        raise exception '상태를 % → % 로 바꿀 수 없습니다', old.status, new.status;
      end if;
    end if;
    new.status_at := now();
  end if;
  return new;
end $$;

drop trigger if exists supply_request_guard on kfr.supply_requests;
create trigger supply_request_guard before insert or update on kfr.supply_requests
  for each row execute function kfr.supply_request_guard();

-- 마감(closings.items) × 메뉴별 사용량(menu_usage) → 재고 출고. 같은 날짜를 다시 저장하면 이전 차감을 되돌리고 다시 반영.
create or replace function cafe.sync_sales_usage(p_date date, p_employee bigint) returns integer
language plpgsql as $$
declare v_items jsonb; v_ref text := 'sale:' || p_date::text; n integer;
begin
  perform pg_advisory_xact_lock(hashtext(v_ref));
  select items into v_items from cafe.closings where date = p_date;
  delete from cafe.inventory_moves where ref = v_ref;
  if v_items is null then return 0; end if;
  with lines as (
    select key as menu_id,
           case when jsonb_typeof(value) = 'object' then coalesce((value->>'q')::numeric, 0) else coalesce((value#>>'{}')::numeric, 0) end as q
      from jsonb_each(v_items) where left(key, 1) <> '_'
    union all
    select key, coalesce((value#>>'{}')::numeric, 0) from jsonb_each(coalesce(v_items->'_free', '{}'::jsonb))
  ), per as (
    select u.item_id, sum(l.q * u.qty) as qty from lines l join cafe.menu_usage u on u.menu_id = l.menu_id
     group by u.item_id having sum(l.q * u.qty) > 0
  ), ins as (
    insert into cafe.inventory_moves(item_id, type, qty, ref, note, employee_id)
    select item_id, 'OUT', qty, v_ref, '판매 차감 ' || p_date::text, p_employee from per returning 1
  ) select count(*) into n from ins;
  return n;
end $$;
grant execute on function cafe.sync_sales_usage(date, bigint) to anon, authenticated;


-- ════════ 10_test_mode.sql ════════
-- ════════════════════════════════════════════════════════════════
--  Bahayy Cafe — 10: 직원 모드(테스트) 전용 공간 cafe_test (09_fixes.sql 다음에 실행)
--  여러 번 실행해도 안전합니다. 실행 후 Exposed schemas 에 cafe_test 추가.
--
--  · 실제 데이터(cafe)와 완전히 분리된 연습용 공간입니다. 규칙(트리거)은 실제와 똑같습니다.
--  · 사장님이 '직원 모드'로 들어가면 앱이 이 공간에 읽고 씁니다.
--  · 직원 모드에 들어갈 때 마지막 초기화가 12시간 넘었으면 자동으로 다시 맞춥니다.
--  · '테스트 초기화'를 누르면 직원·메뉴·재고 품목·설정을 실제 데이터에서 다시 복사하고
--    연습 기록(출퇴근·마감·신청 등)은 모두 지웁니다.
--  · 공급요청도 이 공간 안에만 저장되어 K-Food 로 넘어가지 않습니다.
--  (아래는 cafe_schema.sql ~ 09_fixes.sql 을 cafe_test 이름으로 바꾼 복사본 — 직접 고치지 말고 다시 생성)
--  ⚠️ 실제 스키마를 바꾸는 새 SQL 을 추가하면 이 파일도 다시 만들어 실행해야 합니다.
-- ════════════════════════════════════════════════════════════════

-- ───────── (복사본) cafe_schema.sql ─────────
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
create schema if not exists cafe_test;
grant usage on schema cafe_test to anon, authenticated;

create table if not exists cafe_test.employees(
  id bigint generated always as identity primary key,
  name text not null, name_en text,
  role text not null default 'STAFF',      -- ADMIN / STAFF
  pin text not null, active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists cafe_test.attendance(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe_test.employees(id),
  date date not null,
  clock_in timestamptz, clock_out timestamptz,
  photo_path text,                          -- Storage 경로(출근 사진)
  lat double precision, lng double precision,
  distance_m integer,                       -- 매장과의 거리(m)
  verified boolean not null default false,  -- 지오펜스 통과 여부
  note text, created_at timestamptz not null default now()
);
create index if not exists attendance_date_idx on cafe_test.attendance(date);
create index if not exists attendance_emp_date_idx on cafe_test.attendance(employee_id, date);

create table if not exists cafe_test.menus(
  id text primary key, name text not null, name_en text,
  price numeric not null default 0, category text default 'GENERAL',
  sort integer not null default 0,
  active boolean not null default true
);
create table if not exists cafe_test.closings(
  id bigint generated always as identity primary key,
  date date not null unique, items jsonb not null default '{}'::jsonb,
  cash numeric not null default 0, gcash numeric not null default 0,
  note text, created_at timestamptz not null default now()
);
create table if not exists cafe_test.expenses(
  id bigint generated always as identity primary key,
  date date not null, category text, amount numeric not null default 0, note text
);
create table if not exists cafe_test.inventory_items(
  id bigint generated always as identity primary key,
  name text not null, name_en text, unit text default '개',
  stock numeric not null default 0, reorder_level numeric not null default 0,
  active boolean not null default true
);
create table if not exists cafe_test.inventory_moves(
  id bigint generated always as identity primary key,
  item_id bigint not null references cafe_test.inventory_items(id),
  type text not null,                       -- IN / OUT
  qty numeric not null default 0, date date not null default current_date,
  note text, employee_id bigint references cafe_test.employees(id),
  created_at timestamptz not null default now()
);
create table if not exists cafe_test.notes(
  id bigint generated always as identity primary key,
  author_employee_id bigint references cafe_test.employees(id),
  category text default 'GENERAL',          -- REQUEST(요청) / ISSUE(특이사항) / FIX(수정) / GENERAL
  title text, body text, photo_path text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists cafe_test.note_comments(
  id bigint generated always as identity primary key,
  note_id bigint not null references cafe_test.notes(id) on delete cascade,
  author_employee_id bigint references cafe_test.employees(id), body text,
  created_at timestamptz not null default now()
);
create table if not exists cafe_test.app_settings(key text primary key, value text);

-- 서버 시각 (출근 시각을 기기 시계가 아닌 서버 기준으로 기록할 때 사용)
create or replace function cafe_test.server_now() returns timestamptz
  language sql stable as $$ select now() $$;
grant execute on function cafe_test.server_now() to anon, authenticated;

-- ===== 2) kfr 스키마: K-Food 와 공유하는 공급요청 =====
create schema if not exists cafe_test;
grant usage on schema cafe_test to anon, authenticated;
create table if not exists cafe_test.supply_requests(
  id bigint generated always as identity primary key,
  source text not null default 'CAFE',      -- CAFE / REST(호점)
  requested_by text,                         -- 올린 사람/매장
  date date not null default current_date,
  items jsonb not null default '[]'::jsonb,  -- [{name, qty, unit}]
  status text not null default 'PENDING',    -- PENDING→APPROVED→CONFIRMED→SHIPPING→DELIVERED / REJECTED
  note text, approved_by text,
  created_at timestamptz not null default now()
);
create index if not exists supply_requests_status_idx on cafe_test.supply_requests(source, status);

-- ===== 3) 권한 + RLS (allow-all; 공개 anon 구조 — 민감정보 저장 금지) =====
grant all on all tables in schema cafe_test to anon, authenticated;
grant all on all sequences in schema cafe_test to anon, authenticated;
grant all on cafe_test.supply_requests to anon, authenticated;
grant all on all sequences in schema cafe_test to anon, authenticated;
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='cafe_test' loop
    execute format('alter table cafe_test.%I enable row level security;', t);
    execute format('drop policy if exists allow_all on cafe_test.%I;', t);
    execute format('create policy allow_all on cafe_test.%I for all using (true) with check (true);', t);
  end loop;
  execute 'alter table cafe_test.supply_requests enable row level security';
  execute 'drop policy if exists allow_all on cafe_test.supply_requests';
  execute 'create policy allow_all on cafe_test.supply_requests for all using (true) with check (true)';
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
insert into cafe_test.employees(name, name_en, role, pin)
select '사장', 'Owner', 'ADMIN', '0000'
where not exists (select 1 from cafe_test.employees where role = 'ADMIN');

-- 매장 좌표는 매장에서 앱으로 한 번 등록(관리 탭). 지오펜스 기본 100m.
insert into cafe_test.app_settings(key, value) values
  ('geofence_m', '100'),
  ('photo_retention_days', '90')
on conflict (key) do nothing;

-- ⚠️ 실행 후: Settings → API → Exposed schemas 에 'cafe'(및 'kfr') 포함

-- ───────── (복사본) 02_attendance.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 2단계: 출퇴근 인증 (cafe_schema.sql 실행 후 실행)
--  여러 번 실행해도 안전합니다.
--
--  핵심: 시각·거리·인증여부는 "서버(DB)"가 정합니다.
--   · clock_in / clock_out = DB의 now()  (폰 시계를 바꿔도 소용없음)
--   · date = 필리핀 시간 기준 영업일
--   · distance_m / verified = 매장 좌표(app_settings)와의 거리를 DB가 계산
-- ════════════════════════════════════════════════════════════════

alter table cafe_test.attendance
  add column if not exists accuracy_m integer,             -- GPS 정확도(±m)
  add column if not exists out_lat double precision,       -- 퇴근 위치
  add column if not exists out_lng double precision,
  add column if not exists out_distance_m integer,
  add column if not exists manual_edit boolean not null default false; -- 사장이 퇴근시각 수동 입력

-- 두 좌표 사이 거리(m, haversine)
create or replace function cafe_test.geo_distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns integer language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::integer
$$;

create or replace function cafe_test.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer;
begin
  select nullif(value, '')::float8 into slat from cafe_test.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe_test.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe_test.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);

  if tg_op = 'INSERT' then
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe_test.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음
  new.clock_in   := old.clock_in;
  new.date       := old.date;
  new.photo_path := old.photo_path;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.manual_edit then
    -- 사장이 퇴근 누락을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and new.clock_out < old.clock_in then
      raise exception '퇴근 시각이 출근 시각보다 빠릅니다';
    end if;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe_test.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe_test.attendance;
create trigger attendance_guard before insert or update on cafe_test.attendance
  for each row execute function cafe_test.attendance_guard();

create index if not exists attendance_open_idx on cafe_test.attendance(employee_id) where clock_out is null;

-- ───────── (복사본) 03_board.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 3단계: 게시판 · 댓글 · 안 읽음 표시 (02_attendance.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
-- ════════════════════════════════════════════════════════════════

-- 글의 "마지막 활동"(작성/댓글) — 안 읽음 계산과 피드 정렬에 사용
alter table cafe_test.notes
  add column if not exists last_activity_at timestamptz not null default now(),
  add column if not exists last_activity_by bigint references cafe_test.employees(id);
update cafe_test.notes set last_activity_by = author_employee_id where last_activity_by is null;
create index if not exists notes_activity_idx on cafe_test.notes(last_activity_at desc);
create index if not exists note_comments_note_idx on cafe_test.note_comments(note_id);

-- 직원별 "어디까지 읽었나"
create table if not exists cafe_test.note_reads(
  note_id bigint not null references cafe_test.notes(id) on delete cascade,
  employee_id bigint not null references cafe_test.employees(id),
  last_read_at timestamptz not null default now(),
  primary key (note_id, employee_id)
);

-- 시각은 모두 서버 기준
create or replace function cafe_test.note_init() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.last_activity_at := now();
  new.last_activity_by := new.author_employee_id;
  return new;
end $$;
drop trigger if exists note_init on cafe_test.notes;
create trigger note_init before insert on cafe_test.notes
  for each row execute function cafe_test.note_init();

create or replace function cafe_test.note_comment_touch() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  update cafe_test.notes set last_activity_at = now(), last_activity_by = new.author_employee_id
   where id = new.note_id;
  return new;
end $$;
drop trigger if exists note_comment_touch on cafe_test.note_comments;
create trigger note_comment_touch before insert on cafe_test.note_comments
  for each row execute function cafe_test.note_comment_touch();

create or replace function cafe_test.note_read_now() returns trigger language plpgsql as $$
begin
  new.last_read_at := now();
  return new;
end $$;
drop trigger if exists note_read_now on cafe_test.note_reads;
create trigger note_read_now before insert or update on cafe_test.note_reads
  for each row execute function cafe_test.note_read_now();

-- 권한 + RLS (allow-all)
grant all on cafe_test.note_reads to anon, authenticated;
alter table cafe_test.note_reads enable row level security;
drop policy if exists allow_all on cafe_test.note_reads;
create policy allow_all on cafe_test.note_reads for all using (true) with check (true);

-- ───────── (복사본) 04_inventory.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 4단계: 재고 (03_board.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  현재고(inventory_items.stock)는 입출고 장부(inventory_moves)로만 바뀝니다.
--   · IN     입고  : stock + qty
--   · OUT    출고  : stock - qty
--   · ADJUST 실사  : stock = qty (세어 본 실제 수량)
--  장부 한 줄을 지우면 그만큼 되돌립니다. 날짜·시각은 서버(필리핀) 기준.
-- ════════════════════════════════════════════════════════════════

alter table cafe_test.inventory_moves
  add column if not exists delta numeric,        -- 실제 증감 (ADJUST 포함)
  add column if not exists stock_after numeric;  -- 기록 직후 재고
alter table cafe_test.inventory_items
  add column if not exists sort integer not null default 0;
create index if not exists inventory_moves_item_idx on cafe_test.inventory_moves(item_id, id desc);

create or replace function cafe_test.inventory_move_apply() returns trigger
language plpgsql as $$
declare cur numeric;
begin
  if tg_op = 'DELETE' then
    update cafe_test.inventory_items set stock = stock - coalesce(old.delta, 0) where id = old.item_id;
    return old;
  end if;

  select stock into cur from cafe_test.inventory_items where id = new.item_id for update;
  if not found then raise exception '품목을 찾을 수 없습니다'; end if;
  if new.type not in ('IN', 'OUT', 'ADJUST') then raise exception '구분은 IN/OUT/ADJUST'; end if;
  if new.qty is null or new.qty < 0 or (new.type <> 'ADJUST' and new.qty = 0) then
    raise exception '수량을 확인하세요';
  end if;

  new.delta := case new.type when 'IN' then new.qty when 'OUT' then -new.qty else new.qty - cur end;
  new.stock_after := cur + new.delta;
  new.date := (now() at time zone 'Asia/Manila')::date;
  new.created_at := now();
  update cafe_test.inventory_items set stock = new.stock_after where id = new.item_id;
  return new;
end $$;

drop trigger if exists inventory_move_apply on cafe_test.inventory_moves;
create trigger inventory_move_apply before insert on cafe_test.inventory_moves
  for each row execute function cafe_test.inventory_move_apply();
drop trigger if exists inventory_move_undo on cafe_test.inventory_moves;
create trigger inventory_move_undo after delete on cafe_test.inventory_moves
  for each row execute function cafe_test.inventory_move_apply();

-- 장부는 수정 불가 (틀리면 지우고 다시 기록)
create or replace function cafe_test.inventory_move_no_update() returns trigger
language plpgsql as $$ begin raise exception '장부는 수정할 수 없습니다. 삭제 후 다시 기록하세요.'; end $$;
drop trigger if exists inventory_move_no_update on cafe_test.inventory_moves;
create trigger inventory_move_no_update before update on cafe_test.inventory_moves
  for each row execute function cafe_test.inventory_move_no_update();

-- 공급요청: 결정(승인/반려) 시각
alter table cafe_test.supply_requests add column if not exists decided_at timestamptz;
create index if not exists supply_requests_created_idx on cafe_test.supply_requests(source, created_at desc);

-- ───────── (복사본) 05_kfood_link.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe ↔ K-Food — 5단계: 공급요청 연동 (04_inventory.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  cafe_test.supply_requests 상태 흐름 (서버가 강제)
--    PENDING ──승인(카페 사장)──▶ APPROVED ──K-Food──▶ CONFIRMED ──▶ SHIPPING ──▶ DELIVERED
--        └──반려──▶ REJECTED
--  · K-Food 담당자는 한 단계 앞으로, 또는 실수 시 한 단계 뒤로만 이동 가능
--  · 카페에서 '입고 처리'(received_at)를 한 건은 더 이상 되돌릴 수 없음
--  · 시각(status_at, decided_at, received_at)은 서버 now()
-- ════════════════════════════════════════════════════════════════

alter table cafe_test.supply_requests
  add column if not exists decided_at timestamptz,
  add column if not exists status_at timestamptz,   -- 마지막 상태 변경 시각
  add column if not exists received_at timestamptz; -- 카페 재고에 입고 처리한 시각
update cafe_test.supply_requests set status_at = coalesce(decided_at, created_at) where status_at is null;
create index if not exists supply_requests_status_at_idx on cafe_test.supply_requests(status, status_at desc);

create or replace function cafe_test.supply_request_guard() returns trigger
language plpgsql as $$
declare
  flow text[] := array['APPROVED','CONFIRMED','SHIPPING','DELIVERED'];
  i int; j int;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status_at  := now();
    new.received_at := null;
    return new;
  end if;

  -- 입고 처리: 배송완료 건에 한 번만
  if new.received_at is distinct from old.received_at then
    if old.received_at is not null then raise exception '이미 입고 처리된 요청입니다'; end if;
    if new.status <> 'DELIVERED' then raise exception '배송완료 후에 입고 처리할 수 있습니다'; end if;
    new.received_at := now();
  end if;

  if new.status is distinct from old.status then
    if old.received_at is not null then raise exception '입고 처리된 요청은 상태를 바꿀 수 없습니다'; end if;
    if old.status = 'PENDING' and new.status in ('APPROVED','REJECTED') then
      new.decided_at := now();
    else
      i := array_position(flow, old.status);
      j := array_position(flow, new.status);
      if i is null or j is null or abs(j - i) <> 1 then
        raise exception '상태를 % → % 로 바꿀 수 없습니다', old.status, new.status;
      end if;
    end if;
    new.status_at := now();
  end if;
  return new;
end $$;

drop trigger if exists supply_request_guard on cafe_test.supply_requests;
create trigger supply_request_guard before insert or update on cafe_test.supply_requests
  for each row execute function cafe_test.supply_request_guard();

-- ───────── (복사본) 06_sales.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 6단계: 마감 · 매출 · 지출 (05_kfood_link.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  closings.items 형식: { "<menu_id>": {"q": 수량, "p": 판매단가}, "_free": {"<menu_id>": 수량} }
--   · 단가를 함께 저장하므로 나중에 메뉴 가격을 바꿔도 지난 매출이 변하지 않습니다.
-- ════════════════════════════════════════════════════════════════

alter table cafe_test.closings
  add column if not exists card numeric not null default 0,      -- 카드/기타 결제
  add column if not exists closed_by bigint references cafe_test.employees(id),
  add column if not exists updated_at timestamptz;
alter table cafe_test.expenses
  add column if not exists created_by bigint references cafe_test.employees(id),
  add column if not exists created_at timestamptz not null default now();
create index if not exists closings_date_idx on cafe_test.closings(date);
create index if not exists expenses_date_idx on cafe_test.expenses(date);

-- 하루 한 건 (cafe_schema.sql 에서 unique 로 만들었지만, 예전 테이블이면 여기서 보장)
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'cafe_test.closings'::regclass and contype = 'u') then
    alter table cafe_test.closings add constraint closings_date_key unique (date);
  end if;
end $$;

create or replace function cafe_test.closing_stamp() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  new.updated_at := now();
  if new.date > (now() at time zone 'Asia/Manila')::date then
    raise exception '미래 날짜는 마감할 수 없습니다';
  end if;
  return new;
end $$;
drop trigger if exists closing_stamp on cafe_test.closings;
create trigger closing_stamp before insert or update on cafe_test.closings
  for each row execute function cafe_test.closing_stamp();

-- ───────── (복사본) 07_photo_cleanup.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 출근 사진 자동 정리 (06_sales.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  · 보관기간: app_settings.photo_retention_days (기본 90일, 최소 30일)
--  · 사장님이 앱을 열면 하루 한 번, 기간이 지난 출근 사진을 Storage 에서 지우고
--    기록의 photo_path 를 비웁니다. 출퇴근 시각·위치·✅ 기록은 그대로 남습니다.
--  · DB 는 보관기간이 지난 기록만 사진을 비울 수 있게 막습니다(최근 증거 보호).
-- ════════════════════════════════════════════════════════════════

alter table cafe_test.attendance add column if not exists photo_purged_at timestamptz;
create index if not exists attendance_photo_idx on cafe_test.attendance(date) where photo_path is not null;

create or replace function cafe_test.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe_test.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe_test.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe_test.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe_test.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' then
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe_test.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음
  new.clock_in   := old.clock_in;
  new.date       := old.date;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.manual_edit then
    -- 사장이 퇴근 누락을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and new.clock_out < old.clock_in then
      raise exception '퇴근 시각이 출근 시각보다 빠릅니다';
    end if;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe_test.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe_test.attendance;
create trigger attendance_guard before insert or update on cafe_test.attendance
  for each row execute function cafe_test.attendance_guard();

-- ───────── (복사본) 08_field_update.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahay Cafe — 8단계: 현장 피드백 반영 (07_photo_cleanup.sql 다음에 실행)
--  여러 번 실행해도 안전합니다. 이미 같은 이름의 메뉴/품목이 있으면 새로 넣지 않습니다.
--
--   1) 메뉴판 전체 + 모조스·감자튀김 + 바하이 세트(500)
--   2) 물품 신청 리스트(음료/디저트/음식/기타용품 · 세부 그룹) = 재고 품목
--      퇴근 전 재고 확인 품목: 우유·감자·산도·머핀·로투스·레몬파운드·파스타 면
--   3) 판매 → 재고 자동 차감(메뉴별 사용량) + 퇴근 전 재고 확인 기록
--   4) 직원 급여: 일급(기본 508)·근무시간·근무시간표 → 지각/조퇴 차감, 15일·말일 2회 지급
--   5) 퇴근 전 청소 사진(매장·야외·주방·화장실)
--   6) 마감에 유입 경로(릴스·전단지·지나가다가) 기록
-- ════════════════════════════════════════════════════════════════

-- ── 직원 급여 기준 ──
alter table cafe_test.employees
  add column if not exists daily_rate numeric not null default 508,   -- 하루(기준시간) 급여
  add column if not exists std_hours numeric not null default 8,      -- 하루 기준 근무시간
  add column if not exists shift_start time not null default '09:00', -- 출근 시각
  add column if not exists shift_end time not null default '18:00',   -- 퇴근 시각
  add column if not exists break_min integer not null default 60;     -- 휴게(5시간 넘게 근무 시 차감)

-- ── 출퇴근: 사장 수정/수동 추가 ──
alter table cafe_test.attendance
  add column if not exists admin_edit boolean not null default false,  -- 이번 저장이 사장 수정인지(저장 후 자동 false)
  add column if not exists orig_clock_in timestamptz;                  -- 수정 전 원래 출근 시각

create or replace function cafe_test.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe_test.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe_test.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe_test.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe_test.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' and new.admin_edit and new.clock_in is not null then
    -- 사장이 빠진 근무를 수동 추가 (사진·위치 없음, '수정됨' 표시)
    if new.clock_in > now() or (new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now())) then
      raise exception '시각을 확인하세요';
    end if;
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
    new.manual_edit := true; new.admin_edit := false;
    new.photo_path := null; new.photo_purged_at := null; new.orig_clock_in := null;
    new.lat := null; new.lng := null; new.accuracy_m := null; new.distance_m := null; new.verified := false;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.admin_edit  := false;
    new.orig_clock_in := null;
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe_test.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음 — 사장 수정(admin_edit)만 시각 변경 가능
  if new.admin_edit and new.clock_in is distinct from old.clock_in then
    if new.clock_in is null or new.clock_in > now() then raise exception '출근 시각을 확인하세요'; end if;
    new.orig_clock_in := coalesce(old.orig_clock_in, old.clock_in);
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
  else
    new.clock_in := old.clock_in;
    new.date     := old.date;
    new.orig_clock_in := old.orig_clock_in;
  end if;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.admin_edit then
    -- 사장이 출퇴근 시각을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now()) then
      raise exception '퇴근 시각을 확인하세요';
    end if;
    new.manual_edit := true;
  elsif old.clock_out is null and new.clock_out is not null then
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe_test.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  if not new.admin_edit then new.manual_edit := old.manual_edit; end if;
  new.admin_edit := false;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe_test.attendance;
create trigger attendance_guard before insert or update on cafe_test.attendance
  for each row execute function cafe_test.attendance_guard();

-- ── 청소 사진 (퇴근 전 매장·야외·주방·화장실) ──
create table if not exists cafe_test.clean_photos(
  id bigint generated always as identity primary key,
  attendance_id bigint not null references cafe_test.attendance(id) on delete cascade,
  employee_id bigint references cafe_test.employees(id),
  area text not null,                       -- STORE / OUTSIDE / KITCHEN / RESTROOM
  photo_path text,
  photo_purged_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists clean_photos_att_idx on cafe_test.clean_photos(attendance_id);
create or replace function cafe_test.clean_photo_guard() returns trigger language plpgsql as $$
declare keep integer;
begin
  select nullif(value, '')::integer into keep from cafe_test.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));
  if tg_op = 'INSERT' then new.created_at := now(); new.photo_purged_at := null; return new; end if;
  if tg_op = 'DELETE' then
    if old.created_at > now() - make_interval(days => keep) then raise exception '보관기간 중인 사진은 지울 수 없습니다'; end if;
    return old;
  end if;
  if old.photo_path is not null and new.photo_path is null and old.created_at < now() - make_interval(days => keep) then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path; new.photo_purged_at := old.photo_purged_at;
  end if;
  new.attendance_id := old.attendance_id; new.area := old.area; new.created_at := old.created_at; new.employee_id := old.employee_id;
  return new;
end $$;
drop trigger if exists clean_photo_guard on cafe_test.clean_photos;
create trigger clean_photo_guard before insert or update or delete on cafe_test.clean_photos
  for each row execute function cafe_test.clean_photo_guard();

-- ── 급여: 기타 지급/공제, 지급 기록 ──
create table if not exists cafe_test.pay_adjustments(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe_test.employees(id),
  date date not null,
  kind text not null default 'PLUS',        -- PLUS(기타 지급) / MINUS(공제)
  amount numeric not null default 0,
  note text,
  created_by bigint references cafe_test.employees(id),
  created_at timestamptz not null default now()
);
create table if not exists cafe_test.payroll_runs(
  id bigint generated always as identity primary key,
  employee_id bigint not null references cafe_test.employees(id),
  period_start date not null, period_end date not null,
  days integer, regular_hours numeric, ot_hours numeric, late_min integer,
  basic numeric, ot_pay numeric, other_pay numeric, deductions numeric, net numeric,
  details jsonb,
  expense_id bigint references cafe_test.expenses(id) on delete set null,
  paid_by bigint references cafe_test.employees(id),
  paid_at timestamptz not null default now(),
  unique (employee_id, period_start)
);

-- ── 재고 품목: 분류·세부 그룹·매일 확인 ──
alter table cafe_test.inventory_items
  add column if not exists category text,                       -- DRINK / DESSERT / FOOD / SUPPLY
  add column if not exists groups text[] not null default '{}', -- 예: {DRINK/커피, DRINK/프라페}
  add column if not exists daily_check boolean not null default false;
alter table cafe_test.inventory_moves add column if not exists ref text;  -- sale:YYYY-MM-DD / check:YYYY-MM-DD
create index if not exists inventory_moves_ref_idx on cafe_test.inventory_moves(ref);

-- 판매 1개당 재고 사용량 (마감 저장 시 자동 출고)
create table if not exists cafe_test.menu_usage(
  menu_id text not null references cafe_test.menus(id) on delete cascade,
  item_id bigint not null references cafe_test.inventory_items(id) on delete cascade,
  qty numeric not null default 1,
  primary key (menu_id, item_id)
);
-- 퇴근 전 재고 확인 기록
create table if not exists cafe_test.stock_checks(
  id bigint generated always as identity primary key,
  date date not null default current_date,
  item_id bigint not null references cafe_test.inventory_items(id),
  expected numeric, counted numeric, diff numeric,
  employee_id bigint references cafe_test.employees(id),
  created_at timestamptz not null default now()
);
create index if not exists stock_checks_date_idx on cafe_test.stock_checks(date);
create or replace function cafe_test.stock_check_stamp() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.date := (now() at time zone 'Asia/Manila')::date;
  new.diff := coalesce(new.counted, 0) - coalesce(new.expected, 0);
  return new;
end $$;
drop trigger if exists stock_check_stamp on cafe_test.stock_checks;
create trigger stock_check_stamp before insert on cafe_test.stock_checks
  for each row execute function cafe_test.stock_check_stamp();

-- ── 마감: 유입 경로 ──
alter table cafe_test.closings add column if not exists sources jsonb not null default '{}'::jsonb;  -- {REELS:n, FLYER:n, WALKIN:n, OTHER:n}

-- ── 권한 + RLS (새 테이블 포함) ──
grant all on all tables in schema cafe_test to anon, authenticated;
grant all on all sequences in schema cafe_test to anon, authenticated;
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='cafe_test' loop
    execute format('alter table cafe_test.%I enable row level security;', t);
    execute format('drop policy if exists allow_all on cafe_test.%I;', t);
    execute format('create policy allow_all on cafe_test.%I for all using (true) with check (true);', t);
  end loop;
end $$;

-- ── 메뉴판 ──
insert into cafe_test.menus(id, name, name_en, price, category, sort)
select v.* from (values
  ('c_americano','아메리카노','Americano',140,'COFFEE',1),
  ('c_latte','카페라떼','Cafe Latte',170,'COFFEE',2),
  ('c_spanish','스패니시 라떼','Spanish Latte',180,'COFFEE',3),
  ('c_vanilla','바닐라 라떼','Vanila Latte',190,'COFFEE',4),
  ('c_caramel','카라멜 라떼','Caramel Latte',190,'COFFEE',5),
  ('c_espresso','에스프레소','Espresso',100,'COFFEE',6),
  ('c_maxim','한국 맥심 라떼','Korea Maxim Latte',200,'COFFEE',7),
  ('c_affogato','아포가토','Affogato',190,'COFFEE',8),
  ('f_vanilla','바닐라 프라페','Vanila Frappe',160,'FRAPPE',9),
  ('f_cookie','쿠키앤크림 프라페','Cookie&Cream Frappe',180,'FRAPPE',10),
  ('f_matcha','말차 프라페','Matcha Frappe',190,'FRAPPE',11),
  ('f_mocha','모카 프라페','Mocha Frappe',190,'FRAPPE',12),
  ('f_biscuit','비스킷 프라페','Biscuit Frappe',190,'FRAPPE',13),
  ('s_pinkmatcha','핑크 말차 라떼','Pink Matcha Latte',220,'SIGNATURE',14),
  ('s_bluecream','블루 크림 라떼','Blue Cream Latte',200,'SIGNATURE',15),
  ('n_lemonade','레몬에이드','Lemonade',190,'NONCOFFEE',16),
  ('n_icetea','아이스티','Ice Tea',120,'NONCOFFEE',17),
  ('p_tomato','토마토 파스타','Tomato Pasta',180,'PASTA',18),
  ('p_cream','크림 파스타','Cream Pasta',180,'PASTA',19),
  ('p_pesto','페스토 파스타','Pesto Pasta',190,'PASTA',20),
  ('set_bahayy','바하이 세트 (파스타+산도+음료)','Bahayy Set (Pasta + Sando + Drink)',500,'SET',21),
  ('d_sando','산도','Sando',200,'DESSERT',22),
  ('d_lotus','로투스 치즈케이크','Lotus Cheese Cake',160,'DESSERT',23),
  ('d_cookie','쿠키','Cookie',120,'DESSERT',24),
  ('d_brownie','초코 브라우니','Chocolate Brownie',160,'DESSERT',25),
  ('d_muffin','머핀','Muffin',160,'DESSERT',26),
  ('d_lemonpound','레몬 파운드케이크','Lemon Pound Cake',150,'DESSERT',27),
  ('x_mojos','모조스','Mojos',140,'FOOD',28),
  ('x_fries','감자튀김','Fries',120,'FOOD',29)
) as v(id, name, name_en, price, category, sort)
where not exists (select 1 from cafe_test.menus m where m.id = v.id or m.name = v.name or lower(m.name_en) = lower(v.name_en));

-- ── 물품(재고) 목록 ──
insert into cafe_test.inventory_items(name, name_en, unit, daily_check, category, groups, sort)
select v.* from (values
  ('우유','Milk','팩',true,'DRINK',array['DRINK/커피','DRINK/프라페','DRINK/음료','DESSERT/로투스 치즈케이크']::text[],1),
  ('커피콩','Coffee beans','kg',false,'DRINK',array['DRINK/커피']::text[],2),
  ('물','Water','통',false,'DRINK',array['DRINK/커피','SUPPLY/음식관련']::text[],3),
  ('바닐라시럽','Vanilla syrup','병',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],4),
  ('연유','Condensed milk','캔',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],5),
  ('카라멜 시럽','Caramel syrup','병',false,'DRINK',array['DRINK/커피']::text[],6),
  ('맥심커피','Maxim coffee mix','박스',false,'DRINK',array['DRINK/커피']::text[],7),
  ('코코아가루','Cocoa powder','봉지',false,'DRINK',array['DRINK/커피','DRINK/프라페','DESSERT/브라우니']::text[],8),
  ('아이스크림','Ice cream','통',false,'DRINK',array['DRINK/커피','DESSERT/쿠키','DESSERT/브라우니']::text[],9),
  ('스틱오 (초코)','Stick-O (choco)','통',false,'DRINK',array['DRINK/커피','DRINK/프라페']::text[],10),
  ('크림파우더','Cream powder','봉지',false,'DRINK',array['DRINK/프라페']::text[],11),
  ('생크림 가스총','Whipped cream charger','개',false,'DRINK',array['DRINK/프라페']::text[],12),
  ('오레오쿠키','Oreo cookies','팩',false,'DRINK',array['DRINK/프라페']::text[],13),
  ('오레오크럼블','Oreo crumble','봉지',false,'DRINK',array['DRINK/프라페']::text[],14),
  ('초코시럽','Chocolate syrup','병',false,'DRINK',array['DRINK/프라페','DESSERT/브라우니']::text[],15),
  ('말차파우더','Matcha powder','봉지',false,'DRINK',array['DRINK/프라페','DRINK/음료']::text[],16),
  ('비스킷','Biscuits','팩',false,'DRINK',array['DRINK/프라페','DESSERT/로투스 치즈케이크']::text[],17),
  ('비스킷크럼블','Biscuit crumble','봉지',false,'DRINK',array['DRINK/프라페','DESSERT/로투스 치즈케이크']::text[],18),
  ('생크림','Whipping cream','팩',false,'DRINK',array['DRINK/음료','DESSERT/산도','DESSERT/로투스 치즈케이크','DESSERT/머핀']::text[],19),
  ('식용색소 (핑크)','Food coloring (pink)','병',false,'DRINK',array['DRINK/음료']::text[],20),
  ('레몬에이드시럽','Lemonade syrup','병',false,'DRINK',array['DRINK/음료']::text[],21),
  ('스프라이트','Sprite','병',false,'DRINK',array['DRINK/음료']::text[],22),
  ('레몬','Lemon','개',false,'DRINK',array['DRINK/음료','DESSERT/레몬파운드케이크']::text[],23),
  ('샤인머스켓','Shine muscat','송이',false,'DRINK',array['DRINK/음료','DESSERT/산도']::text[],24),
  ('아이스티가루','Iced tea powder','봉지',false,'DRINK',array['DRINK/음료']::text[],25),
  ('산도 (완성품)','Sando (ready)','개',true,'DESSERT',array['DESSERT/산도']::text[],26),
  ('식빵','Sliced bread','봉지',false,'DESSERT',array['DESSERT/산도']::text[],27),
  ('크림치즈','Cream cheese','개',false,'DESSERT',array['DESSERT/산도','DESSERT/로투스 치즈케이크']::text[],28),
  ('설탕','Sugar','kg',false,'DESSERT',array['DESSERT/산도','DESSERT/로투스 치즈케이크']::text[],29),
  ('키위','Kiwi','개',false,'DESSERT',array['DESSERT/산도']::text[],30),
  ('망고','Mango','개',false,'DESSERT',array['DESSERT/산도']::text[],31),
  ('오렌지','Orange','개',false,'DESSERT',array['DESSERT/산도']::text[],32),
  ('로투스 치즈케이크 (완성품)','Lotus cheesecake (ready)','개',true,'DESSERT',array['DESSERT/로투스 치즈케이크']::text[],33),
  ('로투스잼','Lotus spread','병',false,'DESSERT',array['DESSERT/로투스 치즈케이크']::text[],34),
  ('레몬즙','Lemon juice','병',false,'DESSERT',array['DESSERT/로투스 치즈케이크','FOOD/모조스','DESSERT/레몬파운드케이크']::text[],35),
  ('S&R 쿠키','S&R cookies','개',false,'DESSERT',array['DESSERT/쿠키']::text[],36),
  ('S&R 브라우니','S&R brownies','개',false,'DESSERT',array['DESSERT/브라우니']::text[],37),
  ('머핀 (S&R)','Muffin (S&R)','개',true,'DESSERT',array['DESSERT/머핀']::text[],38),
  ('레몬 파운드케이크 (완성품)','Lemon pound cake (ready)','조각',true,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],39),
  ('S&R 파운드케이크','S&R pound cake','개',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],40),
  ('슈가파우더','Powdered sugar','봉지',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],41),
  ('허브','Herbs','팩',false,'DESSERT',array['DESSERT/레몬파운드케이크']::text[],42),
  ('파스타 면','Pasta noodles','통',true,'FOOD',array['FOOD/파스타']::text[],43),
  ('마늘','Garlic','개',false,'FOOD',array['FOOD/파스타']::text[],44),
  ('양파','Onion','개',false,'FOOD',array['FOOD/파스타']::text[],45),
  ('식용유','Cooking oil','병',false,'FOOD',array['FOOD/파스타','FOOD/모조스','FOOD/감자튀김']::text[],46),
  ('베이컨','Bacon','팩',false,'FOOD',array['FOOD/파스타']::text[],47),
  ('햄','Ham','팩',false,'FOOD',array['FOOD/파스타']::text[],48),
  ('토마토소스','Tomato sauce','병',false,'FOOD',array['FOOD/파스타']::text[],49),
  ('크림소스','Cream sauce','병',false,'FOOD',array['FOOD/파스타']::text[],50),
  ('페스토소스','Pesto sauce','병',false,'FOOD',array['FOOD/파스타']::text[],51),
  ('소금','Salt','봉지',false,'FOOD',array['FOOD/파스타']::text[],52),
  ('후추','Pepper','병',false,'FOOD',array['FOOD/파스타']::text[],53),
  ('MSG','MSG','봉지',false,'FOOD',array['FOOD/파스타']::text[],54),
  ('슬라이스치즈','Sliced cheese','팩',false,'FOOD',array['FOOD/파스타']::text[],55),
  ('감자','Potatoes','개',true,'FOOD',array['FOOD/모조스']::text[],56),
  ('계란','Eggs','판',false,'FOOD',array['FOOD/모조스']::text[],57),
  ('밀가루','Flour','kg',false,'FOOD',array['FOOD/모조스']::text[],58),
  ('갈릭파우더','Garlic powder','봉지',false,'FOOD',array['FOOD/모조스']::text[],59),
  ('머스타드소스','Mustard sauce','병',false,'FOOD',array['FOOD/모조스']::text[],60),
  ('스틱감자','Frozen fries','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],61),
  ('케찹','Ketchup','병',false,'FOOD',array['FOOD/감자튀김']::text[],62),
  ('마요네즈','Mayonnaise','병',false,'FOOD',array['FOOD/감자튀김']::text[],63),
  ('치즈파우더','Cheese powder','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],64),
  ('어니언파우더','Onion powder','봉지',false,'FOOD',array['FOOD/감자튀김']::text[],65),
  ('일회용컵','Disposable cups','줄',false,'SUPPLY',array['SUPPLY/음식관련']::text[],66),
  ('일회용컵 뚜껑','Cup lids','줄',false,'SUPPLY',array['SUPPLY/음식관련']::text[],67),
  ('빨대','Straws','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],68),
  ('포장용기','Takeout containers','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],69),
  ('소스포장용기','Sauce cups','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],70),
  ('샌드위치 비닐랩','Sandwich wrap','롤',false,'SUPPLY',array['SUPPLY/음식관련']::text[],71),
  ('일회용장갑','Disposable gloves','박스',false,'SUPPLY',array['SUPPLY/음식관련']::text[],72),
  ('키친타올','Kitchen towel','롤',false,'SUPPLY',array['SUPPLY/음식관련']::text[],73),
  ('물티슈','Wet wipes','팩',false,'SUPPLY',array['SUPPLY/음식관련']::text[],74),
  ('소스통','Sauce bottles','개',false,'SUPPLY',array['SUPPLY/음식관련']::text[],75),
  ('설거지 퐁퐁','Dish soap','병',false,'SUPPLY',array['SUPPLY/청소관련']::text[],76),
  ('수세미','Sponges','개',false,'SUPPLY',array['SUPPLY/청소관련']::text[],77),
  ('락스','Bleach','병',false,'SUPPLY',array['SUPPLY/청소관련']::text[],78),
  ('쓰레기봉투','Trash bags','팩',false,'SUPPLY',array['SUPPLY/청소관련']::text[],79),
  ('두루마리 휴지','Toilet roll','롤',false,'SUPPLY',array['SUPPLY/매장관련']::text[],80),
  ('건전지','Batteries','개',false,'SUPPLY',array['SUPPLY/매장관련']::text[],81),
  ('전단지','Flyers','장',false,'SUPPLY',array['SUPPLY/매장관련']::text[],82),
  ('화장실용 휴지','Restroom tissue','팩',false,'SUPPLY',array['SUPPLY/매장관련']::text[],83)
) as v(name, name_en, unit, daily_check, category, groups, sort)
where not exists (select 1 from cafe_test.inventory_items i where i.name = v.name);

-- ── 판매 시 자동 차감 (1:1 품목만 기본 설정, 나머지는 앱 '품목 관리'에서) ──
insert into cafe_test.menu_usage(menu_id, item_id, qty)
select v.menu_id, i.id, v.qty from (values
  ('d_sando','산도 (완성품)',1),
  ('set_bahayy','산도 (완성품)',1),
  ('d_lotus','로투스 치즈케이크 (완성품)',1),
  ('d_muffin','머핀 (S&R)',1),
  ('d_lemonpound','레몬 파운드케이크 (완성품)',1)
) as v(menu_id, item_name, qty)
join cafe_test.inventory_items i on i.name = v.item_name
join cafe_test.menus m on m.id = v.menu_id
on conflict do nothing;

-- ── 기본 설정 ──
insert into cafe_test.app_settings(key, value) values
  ('ot_enabled', '1'), ('ot_multiplier', '1'), ('clean_photos_required', '1')
on conflict (key) do nothing;

-- ───────── (복사본) 09_fixes.sql ─────────
-- ════════════════════════════════════════════════════════════════
--  Bahayy Cafe — 9: 검수 수정 (08_field_update.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--   1) 퇴근을 잊은 근무(16시간 초과)는 직원이 '지금' 퇴근 처리할 수 없음 → 사장님이 시각 입력
--   2) 공급요청은 항상 '승인 대기'로만 새로 만들 수 있음
--   3) 마감 저장 시 판매분 재고 차감을 DB 안에서 한 번에(동시 저장에도 두 번 빠지지 않게)
-- ════════════════════════════════════════════════════════════════

create or replace function cafe_test.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer;
begin
  select nullif(value, '')::float8 into slat from cafe_test.app_settings where key = 'store_lat';
  select nullif(value, '')::float8 into slng from cafe_test.app_settings where key = 'store_lng';
  select nullif(value, '')::integer into fence from cafe_test.app_settings where key = 'geofence_m';
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from cafe_test.app_settings where key = 'photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' and new.admin_edit and new.clock_in is not null then
    -- 사장이 빠진 근무를 수동 추가 (사진·위치 없음, '수정됨' 표시)
    if new.clock_in > now() or (new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now())) then
      raise exception '시각을 확인하세요';
    end if;
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
    new.manual_edit := true; new.admin_edit := false;
    new.photo_path := null; new.photo_purged_at := null; new.orig_clock_in := null;
    new.lat := null; new.lng := null; new.accuracy_m := null; new.distance_m := null; new.verified := false;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.admin_edit  := false;
    new.orig_clock_in := null;
    new.clock_in    := now();
    new.date        := (now() at time zone 'Asia/Manila')::date;
    new.clock_out   := null;
    new.manual_edit := false;
    new.photo_purged_at := null;
    new.distance_m  := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                            then cafe_test.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified    := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE: 출근 기록(시각·사진·위치·인증)은 바꿀 수 없음 — 사장 수정(admin_edit)만 시각 변경 가능
  if new.admin_edit and new.clock_in is distinct from old.clock_in then
    if new.clock_in is null or new.clock_in > now() then raise exception '출근 시각을 확인하세요'; end if;
    new.orig_clock_in := coalesce(old.orig_clock_in, old.clock_in);
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
  else
    new.clock_in := old.clock_in;
    new.date     := old.date;
    new.orig_clock_in := old.orig_clock_in;
  end if;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음 (자동 정리)
  if old.photo_path is not null and new.photo_path is null
     and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path;
    new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m;
  new.verified   := old.verified;

  if new.admin_edit then
    -- 사장이 출퇴근 시각을 수동 입력 (화면에 '수정됨' 표시)
    if new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now()) then
      raise exception '퇴근 시각을 확인하세요';
    end if;
    new.manual_edit := true;
  elsif old.clock_out is null and new.clock_out is not null then
    -- 퇴근을 잊은 지난 근무를 다음 날 '지금' 시각으로 닫으면 OT 가 수십 시간 생김 → 사장님이 입력하도록
    if now() - old.clock_in > interval '16 hours' then
      raise exception '지난 근무는 퇴근 시각을 사장님이 입력해야 합니다 (근태 탭)';
    end if;
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then cafe_test.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out;
    new.out_lat := old.out_lat; new.out_lng := old.out_lng;
    new.out_distance_m := old.out_distance_m;
  end if;
  if not new.admin_edit then new.manual_edit := old.manual_edit; end if;
  new.admin_edit := false;
  return new;
end $$;

drop trigger if exists attendance_guard on cafe_test.attendance;
create trigger attendance_guard before insert or update on cafe_test.attendance
  for each row execute function cafe_test.attendance_guard();

create or replace function cafe_test.supply_request_guard() returns trigger
language plpgsql as $$
declare
  flow text[] := array['APPROVED','CONFIRMED','SHIPPING','DELIVERED'];
  i int; j int;
begin
  if tg_op = 'INSERT' then
    new.status := 'PENDING';      -- 새 요청은 항상 승인 대기에서 시작
    new.decided_at := null;
    new.approved_by := null;
    new.created_at := now();
    new.status_at  := now();
    new.received_at := null;
    return new;
  end if;

  -- 입고 처리: 배송완료 건에 한 번만
  if new.received_at is distinct from old.received_at then
    if old.received_at is not null then raise exception '이미 입고 처리된 요청입니다'; end if;
    if new.status <> 'DELIVERED' then raise exception '배송완료 후에 입고 처리할 수 있습니다'; end if;
    new.received_at := now();
  end if;

  if new.status is distinct from old.status then
    if old.received_at is not null then raise exception '입고 처리된 요청은 상태를 바꿀 수 없습니다'; end if;
    if old.status = 'PENDING' and new.status in ('APPROVED','REJECTED') then
      new.decided_at := now();
    else
      i := array_position(flow, old.status);
      j := array_position(flow, new.status);
      if i is null or j is null or abs(j - i) <> 1 then
        raise exception '상태를 % → % 로 바꿀 수 없습니다', old.status, new.status;
      end if;
    end if;
    new.status_at := now();
  end if;
  return new;
end $$;

drop trigger if exists supply_request_guard on cafe_test.supply_requests;
create trigger supply_request_guard before insert or update on cafe_test.supply_requests
  for each row execute function cafe_test.supply_request_guard();

-- 마감(closings.items) × 메뉴별 사용량(menu_usage) → 재고 출고. 같은 날짜를 다시 저장하면 이전 차감을 되돌리고 다시 반영.
create or replace function cafe_test.sync_sales_usage(p_date date, p_employee bigint) returns integer
language plpgsql as $$
declare v_items jsonb; v_ref text := 'sale:' || p_date::text; n integer;
begin
  perform pg_advisory_xact_lock(hashtext(v_ref));
  select items into v_items from cafe_test.closings where date = p_date;
  delete from cafe_test.inventory_moves where ref = v_ref;
  if v_items is null then return 0; end if;
  with lines as (
    select key as menu_id,
           case when jsonb_typeof(value) = 'object' then coalesce((value->>'q')::numeric, 0) else coalesce((value#>>'{}')::numeric, 0) end as q
      from jsonb_each(v_items) where left(key, 1) <> '_'
    union all
    select key, coalesce((value#>>'{}')::numeric, 0) from jsonb_each(coalesce(v_items->'_free', '{}'::jsonb))
  ), per as (
    select u.item_id, sum(l.q * u.qty) as qty from lines l join cafe_test.menu_usage u on u.menu_id = l.menu_id
     group by u.item_id having sum(l.q * u.qty) > 0
  ), ins as (
    insert into cafe_test.inventory_moves(item_id, type, qty, ref, note, employee_id)
    select item_id, 'OUT', qty, v_ref, '판매 차감 ' || p_date::text, p_employee from per returning 1
  ) select count(*) into n from ins;
  return n;
end $$;
grant execute on function cafe_test.sync_sales_usage(date, bigint) to anon, authenticated;


-- ───────── 실제 데이터로 초기화 ─────────
create or replace function cafe_test.reset_from_live() returns void
language plpgsql security definer set search_path = cafe_test, public as $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'cafe_test' loop
    execute format('truncate table cafe_test.%I restart identity cascade', t);
  end loop;
  insert into cafe_test.employees overriding system value select * from cafe.employees;
  insert into cafe_test.menus select * from cafe.menus;
  insert into cafe_test.inventory_items overriding system value select * from cafe.inventory_items;
  insert into cafe_test.menu_usage select * from cafe.menu_usage;
  insert into cafe_test.app_settings select * from cafe.app_settings;
  insert into cafe_test.app_settings(key, value) values ('test_reset_at', now()::text)
    on conflict (key) do update set value = excluded.value;
  perform setval(pg_get_serial_sequence('cafe_test.employees', 'id'), greatest(1, (select coalesce(max(id), 0) from cafe_test.employees)));
  perform setval(pg_get_serial_sequence('cafe_test.inventory_items', 'id'), greatest(1, (select coalesce(max(id), 0) from cafe_test.inventory_items)));
end $$;
grant execute on function cafe_test.reset_from_live() to anon, authenticated;
select cafe_test.reset_from_live();
