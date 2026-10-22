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
