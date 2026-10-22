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
