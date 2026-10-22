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
