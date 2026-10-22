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
