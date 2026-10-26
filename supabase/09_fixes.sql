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
