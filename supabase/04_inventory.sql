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
