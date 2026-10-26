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
