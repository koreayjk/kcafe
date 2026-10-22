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
