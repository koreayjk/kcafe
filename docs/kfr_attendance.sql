-- ════════════════════════════════════════════════════════════════
--  K-Food — 지점별 직원 출퇴근 (사진 + GPS + 서버 시각)
--  실행 위치: Supabase SQL Editor (kfr 스키마가 있는 같은 프로젝트). 여러 번 실행해도 안전.
--  Bahayy Cafe 앱(koreayjk/kcafe)에서 현장 검증된 규칙을 지점 단위로 옮긴 것.
-- ════════════════════════════════════════════════════════════════

-- 1) 지점 위치 (출근 지오펜스 기준점) — 지점마다 따로
alter table kfr.branches
  add column if not exists address text,                     -- 표시용 주소
  add column if not exists lat double precision,             -- 지점 좌표 (지점에서 📍 버튼으로 등록)
  add column if not exists lng double precision,
  add column if not exists geofence_m integer not null default 100;  -- 허용 반경(m)

-- 2) 지점별 직원 (지점마다 명단·PIN·일급·근무시간 따로)
create table if not exists kfr.employees(
  id bigint generated always as identity primary key,
  branch_id text not null references kfr.branches(id),
  name text not null, name_en text,
  pin text not null,                                         -- 출퇴근 때 본인 확인용 개인 PIN
  role text not null default 'STAFF',                        -- STAFF / MANAGER (표시용)
  daily_rate numeric not null default 0,                     -- 일급 (급여 계산 2단계용)
  std_hours numeric not null default 8,
  shift_start time not null default '09:00',
  shift_end time not null default '18:00',
  break_min integer not null default 60,
  active boolean not null default true,                      -- 퇴사자는 삭제 대신 false (기록 보존)
  created_at timestamptz not null default now()
);
create index if not exists employees_branch_idx on kfr.employees(branch_id);

-- 3) 출퇴근 기록
create table if not exists kfr.attendance(
  id bigint generated always as identity primary key,
  branch_id text not null references kfr.branches(id),
  employee_id bigint not null references kfr.employees(id),
  date date not null,
  clock_in timestamptz, clock_out timestamptz,
  photo_path text, photo_purged_at timestamptz,
  lat double precision, lng double precision, accuracy_m integer,
  distance_m integer, verified boolean not null default false,
  out_lat double precision, out_lng double precision, out_distance_m integer,
  manual_edit boolean not null default false,                -- 본사/지점 관리자가 수정·추가한 기록 (화면에 '수정됨')
  admin_edit boolean not null default false,                 -- 이번 저장이 관리자 수정인지 (저장 후 자동 false)
  orig_clock_in timestamptz,                                 -- 수정 전 원래 출근 시각
  note text,
  created_at timestamptz not null default now()
);
create index if not exists attendance_branch_date_idx on kfr.attendance(branch_id, date);
create index if not exists attendance_emp_open_idx on kfr.attendance(employee_id) where clock_out is null;

create or replace function kfr.geo_distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns integer language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::integer
$$;

-- 시각·날짜·거리·인증은 서버(DB)가 결정. 출근 기록은 직원이 고칠 수 없음.
create or replace function kfr.attendance_guard() returns trigger
language plpgsql as $$
declare
  slat float8; slng float8; fence integer; keep integer; emp_branch text;
begin
  select lat, lng, geofence_m into slat, slng, fence from kfr.branches where id = coalesce(new.branch_id, old.branch_id);
  fence := coalesce(fence, 100);
  select nullif(value, '')::integer into keep from kfr.app_settings where key = 'att_photo_retention_days';
  keep := greatest(30, coalesce(keep, 90));

  if tg_op = 'INSERT' then
    select branch_id into emp_branch from kfr.employees where id = new.employee_id;
    if emp_branch is distinct from new.branch_id then raise exception '다른 지점 직원입니다'; end if;
    if new.admin_edit and new.clock_in is not null then
      -- 관리자가 빠진 근무를 수동 추가 (사진·위치 없음, '수정됨')
      if new.clock_in > now() or (new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now())) then
        raise exception '시각을 확인하세요';
      end if;
      new.date := (new.clock_in at time zone 'Asia/Manila')::date;
      new.manual_edit := true; new.admin_edit := false;
      new.photo_path := null; new.photo_purged_at := null; new.orig_clock_in := null;
      new.lat := null; new.lng := null; new.accuracy_m := null; new.distance_m := null; new.verified := false;
      return new;
    end if;
    new.admin_edit := false; new.orig_clock_in := null; new.manual_edit := false; new.photo_purged_at := null;
    new.clock_in := now();
    new.date := (now() at time zone 'Asia/Manila')::date;
    new.clock_out := null;
    new.distance_m := case when new.lat is not null and new.lng is not null and slat is not null and slng is not null
                           then kfr.geo_distance_m(new.lat, new.lng, slat, slng) end;
    new.verified := coalesce(new.distance_m <= fence, false);
    return new;
  end if;

  -- UPDATE
  new.branch_id := old.branch_id; new.employee_id := old.employee_id;
  if new.admin_edit and new.clock_in is distinct from old.clock_in then
    if new.clock_in is null or new.clock_in > now() then raise exception '출근 시각을 확인하세요'; end if;
    new.orig_clock_in := coalesce(old.orig_clock_in, old.clock_in);
    new.date := (new.clock_in at time zone 'Asia/Manila')::date;
  else
    new.clock_in := old.clock_in; new.date := old.date; new.orig_clock_in := old.orig_clock_in;
  end if;
  -- 사진은 보관기간(최소 30일)이 지난 기록만 비울 수 있음
  if old.photo_path is not null and new.photo_path is null and old.date < (now() at time zone 'Asia/Manila')::date - keep then
    new.photo_purged_at := now();
  else
    new.photo_path := old.photo_path; new.photo_purged_at := old.photo_purged_at;
  end if;
  new.lat := old.lat; new.lng := old.lng; new.accuracy_m := old.accuracy_m;
  new.distance_m := old.distance_m; new.verified := old.verified;

  if new.admin_edit then
    if new.clock_out is not null and (new.clock_out < new.clock_in or new.clock_out > now()) then
      raise exception '퇴근 시각을 확인하세요';
    end if;
    new.manual_edit := true;
  elsif old.clock_out is null and new.clock_out is not null then
    -- 퇴근을 잊은 근무(16시간 초과)를 다음 날 '지금'으로 닫으면 근무시간이 부풀려짐 → 관리자가 입력
    if now() - old.clock_in > interval '16 hours' then
      raise exception '지난 근무는 퇴근 시각을 관리자가 입력해야 합니다';
    end if;
    new.clock_out := now();
    new.out_distance_m := case when new.out_lat is not null and new.out_lng is not null and slat is not null and slng is not null
                               then kfr.geo_distance_m(new.out_lat, new.out_lng, slat, slng) end;
  else
    new.clock_out := old.clock_out; new.out_lat := old.out_lat; new.out_lng := old.out_lng; new.out_distance_m := old.out_distance_m;
  end if;
  if not new.admin_edit then new.manual_edit := old.manual_edit; end if;
  new.admin_edit := false;
  return new;
end $$;
drop trigger if exists attendance_guard on kfr.attendance;
create trigger attendance_guard before insert or update on kfr.attendance
  for each row execute function kfr.attendance_guard();

-- 4) 권한 + RLS (K-Food 기존 방식과 동일: anon allow-all)
grant all on kfr.employees, kfr.attendance to anon, authenticated;
grant all on all sequences in schema kfr to anon, authenticated;
alter table kfr.employees enable row level security;
alter table kfr.attendance enable row level security;
drop policy if exists allow_all on kfr.employees;
create policy allow_all on kfr.employees for all using (true) with check (true);
drop policy if exists allow_all on kfr.attendance;
create policy allow_all on kfr.attendance for all using (true) with check (true);

-- 5) 사진 저장소: 비공개 버킷 'kfr-att' (사진은 필요할 때 signed URL 로만 불러옴)
insert into storage.buckets (id, name, public) values ('kfr-att', 'kfr-att', false) on conflict (id) do nothing;
drop policy if exists kfr_att_rw on storage.objects;
create policy kfr_att_rw on storage.objects for all to anon, authenticated
  using (bucket_id = 'kfr-att') with check (bucket_id = 'kfr-att');

-- 6) 기본 설정
insert into kfr.app_settings(key, value) values ('att_photo_retention_days', '90') on conflict (key) do nothing;
