# K-Food 지점별 직원 출퇴근 — 구현 인수인계 (v1)

> 이 문서 전체를 **K-Food(`koreayjk/kfr`) 저장소에서 연 새 Claude Code 세션** 첫 메시지에 붙여넣고 시작하세요.
> 원본 구현: Bahayy Cafe 앱(`koreayjk/kcafe`, `index.html`) — 같은 Supabase 프로젝트에서 현장 검증된 출퇴근 기능을 **본사 + 여러 지점** 구조로 옮기는 작업입니다.

---

## 0. 한 줄 요약
각 지점 직원이 **앱 안 카메라로 실시간 사진 + GPS**로 출퇴근하고, **시각·날짜·매장 거리·인증(✅/⚠️)은 서버(DB 트리거)가 결정**합니다.
**지점마다 주소(좌표)·허용 반경·직원 명단(PIN·근무시간)을 따로** 두고, 본사는 모든 지점의 근태를 한 화면에서 봅니다.

## 1. 확정된 결정
| 항목 | 결정 |
|---|---|
| 직원 | **지점별 직원 명단** (`kfr.employees.branch_id`). 지점마다 이름·개인 PIN·근무시간·일급 따로 |
| 누가 직원 관리 | 본사: 모든 지점 / 지점 계정: **자기 지점 직원만** 추가·수정·비활성 |
| 출근 방법 | 지점 로그인 화면의 **출퇴근 탭** → 직원 선택 + 개인 PIN → 사진 → 출근. (지점 공용 폰/태블릿, 개인 폰 모두 가능) |
| 지점 위치 | 지점마다 **주소(표시용) + 좌표 + 허용 반경(기본 100m)**. 좌표는 지점 계정이 매장 안에서 `📍 이 위치를 지점 좌표로 등록`. 본사는 반경·주소 수정 가능 |
| 시각 | 서버 `now()`, 날짜는 **Asia/Manila** 기준 |
| 사진 | 비공개 버킷 `kfr-att`, 촬영 즉시 640px·JPEG 60% 압축, 볼 때만 signed URL(5분) |
| 보관 | 출근 사진 기본 **90일**(최소 30일) 후 자동 정리 — 시각·위치 기록은 유지 |
| 수정 | 직원은 기록 수정 불가. 관리자(본사/지점) 수정은 `수정됨` + 원래 시각 보존 |
| 퇴근 잊음 | 16시간 넘게 열린 근무는 직원이 닫을 수 없음 → 관리자가 퇴근 시각 입력 (다음 날 '지금'으로 닫혀 시간이 부풀려지는 것 방지) |
| 급여 | **이번 범위 아님(2단계)**. `employees`에 일급·근무시간 칸만 미리 둠. 계산 규칙은 kcafe `shiftCalc/computePayroll` 참고 |

## 2. 현재 K-Food 구조 (작업 전 확인)
- 단일 `index.html`, supabase-js, 스키마 `kfr` (`SUPABASE_SCHEMA = "kfr"`), 공개 anon 키 + RLS allow-all.
- 로그인 = **지점 선택 + 지점 PIN** (`kfr.branches`: `id text`, `name`, `type DIRECT|FRANCHISE`, `pin`). 본사 = `id 0`.
  - 주의: `doLogin()`이 `Number($("loginBranch").value)`로 id를 **숫자**로 바꿔 `state.user.branchId`에 넣음. 새 테이블의 `branch_id`는 **text** → 쿼리/insert 때 `String(branchId)` 사용.
- 탭: `renderApp()`의 `tabs` 배열 (본사: dashboard, settle, orders, supply, payouts, daily, menurank, report, library, manage / 지점: closing, myorder, library). 라우팅은 `renderScreen()`의 `if (t === "...")`.
- 다국어: `I18N` + `tt()`(텍스트) / `tl()`(영어+따갈로그 병기). 지점 화면은 영어 기본.
- 공통 헬퍼: `$`, `fmt`, `today()`(**주의: K-Food의 today()는 기기 시간대** — 출퇴근 화면은 `new Date().toLocaleDateString("en-CA",{timeZone:"Asia/Manila"})` 사용 권장), `toast`.

## 3. DB (Supabase SQL Editor에서 실행 — 여러 번 실행해도 안전)
아래를 `supabase/attendance.sql`로 저장소에 추가하고 실행. 실행 후 **Data API → Exposed schemas**는 기존대로 `kfr` 포함이면 OK (새 스키마 없음).

```sql
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

```

검증된 동작 (로컬 PostgreSQL 16에서 확인):
- 1호점 직원이 1호점 근처(15m)에서 출근 → `verified=true`, 시각·날짜는 서버 값 (클라이언트가 보낸 시각·날짜 무시)
- 2호점 직원이 1호점 위치에서 출근 → 2호점 좌표 기준이라 `verified=false`
- 다른 지점 직원 id로 출근 시도 → `다른 지점 직원입니다` 오류
- 직원이 출근 시각 변경 시도 → 무시됨 / 관리자 수정(`admin_edit:true`) → 변경 + `orig_clock_in` 보존 + `manual_edit`

## 4. 화면

### 4-1. 지점 계정 — 새 탭 `출퇴근` (Time Clock)
1. **직원 선택 + 개인 PIN** (드롭다운: `employees where branch_id = 지점 and active`). PIN 확인은 `select pin ... eq id` 후 비교(K-Food 로그인과 같은 방식). 확인되면 그 직원으로 아래 화면. 다른 직원으로 바꾸기 버튼.
2. **출근 전**: `📷 Take photo & clock in` → 앱 안 카메라(전면, `getUserMedia({video:{facingMode:"user"}})`) + 동시에 GPS 요청 → 촬영 → 미리보기 + `📍 Store 15m (±10m) ✅` → `✅ Clock in`.
   - 업로드 경로: `{branchId}/{YYYY-MM-DD}/{employeeId}_{timestamp}.jpg` (버킷 `kfr-att`)
   - insert: `{branch_id, employee_id, date, clock_in, photo_path, lat, lng, accuracy_m}` → 트리거가 시각·날짜·거리·인증을 덮어씀. `.select("clock_in,verified,distance_m").single()`로 결과 표시.
   - GPS 실패 시 "위치 없이 출근할까요? (⚠️ 표시)" 확인 후 진행. 카메라 권한 거부 시 안내만.
3. **근무 중**: `● On duty · since 09:02 · 📍 15m ✅` + `Clock out` (확인 → GPS 받아 `update {clock_out, out_lat, out_lng}`).
4. **퇴근 잊은 근무**(16시간 초과 열린 기록): "퇴근 기록 없음 — 관리자에게 요청" 안내, **오늘 출근은 그대로 가능**.
5. 최근 기록 10건 (날짜·출근·퇴근·근무시간·✅).
6. **지점 설정 카드**(지점 계정): 주소 표시, 좌표 `등록됨/미등록`, `📍 이 위치를 지점 좌표로 등록`(매장 안에서 1회; 정확도 ±m 확인 후 저장), **직원 관리**(자기 지점만: 추가·PIN 변경·근무시간·비활성).

### 4-2. 본사 — 새 탭 `근태`
- 필터: **지점 선택(전체/각 지점) + 월**.
- 표: 행 = 날짜, 열 = (선택 지점) 직원. 칸: `09:02–18:01`, `📍 15m ✅/⚠️`, `지각 N분`(근무시간표 기준), `📷`(누를 때만 signed URL로 사진 모달), `✏️`(시각 수정: prompt `09:00-18:00` → `update {clock_in, clock_out, admin_edit:true}`), 퇴근 없는 지난 근무엔 `퇴근 입력`.
- 아래 월 합계: 직원별 근무시간·일수·⚠️ 횟수.
- `＋ 빠진 근무 추가`: 직원·날짜·출근·퇴근 → `insert {..., admin_edit:true}` (사진·위치 없이 `수정됨`).
- 본사 대시보드(선택): "지금 근무 중" 지점별 인원, 오늘 ⚠️ 출근.

### 4-3. 본사 — `관리` 탭에 추가
- **지점 위치/반경**: 지점별 주소(text), 좌표(등록 상태·초기화), 허용 반경(m).
- **지점별 직원**: 지점 선택 → 직원 목록(추가·PIN·근무시간·일급·비활성).
- **출근 사진 보관 기간**(`att_photo_retention_days`, 30~730) + `지금 정리`.

## 5. 이식할 코드 (kcafe `index.html` 함수 → K-Food로)
`koreayjk/kcafe`의 `index.html`에서 아래 함수를 가져와 이름·테이블만 바꾸면 됩니다. (접근 안 되면 아래 핵심 코드로 충분)

| kcafe 함수 | 용도 | 바꿀 점 |
|---|---|---|
| `getPosition`, `storeDistance` | GPS, 미리보기 거리 | 매장 좌표 = 현재 지점의 `branches.lat/lng` |
| `startClockIn`, `capturePhoto`, `updateGpsLine`, `confirmClockIn` | 카메라·압축·업로드·출근 | 버킷 `kfr-att`, insert에 `branch_id`·선택된 `employee_id` |
| `openShift`(+`STALE_MS`), `clockOut`, `screenClock` | 근무 상태·퇴근 | 직원 선택 단계 추가 |
| `screenAttendance`, `showPhoto`, `editShift`, `addShift` | 본사 근태표 | 지점 필터 |
| `purgeOldPhotos` | 보관기간 지난 사진 정리 | 테이블 `kfr.attendance`, 키 `att_photo_retention_days`, **DB를 먼저 비우고 비워진 것만 Storage 삭제** |
| `shiftCalc` | 지각 분 계산(근무시간표 기준) | 그대로 |

핵심 코드:
```js
// 촬영: 640px · JPEG 60%
function capturePhoto(){
  const v = $("camVideo"); if (!v || !v.videoWidth) return;
  const s = Math.min(1, 640 / v.videoWidth), c = document.createElement("canvas");
  c.width = Math.round(v.videoWidth * s); c.height = Math.round(v.videoHeight * s);
  c.getContext("2d").drawImage(v, 0, 0, c.width, c.height);
  c.toBlob((b) => { /* stopCamera(); 미리보기 + 출근 버튼 */ att.blob = b; }, "image/jpeg", 0.6);
}
// 출근
const STALE_MS = 16 * 3600e3;
async function confirmClockIn(){
  const bId = String(state.user.branchId), emp = att.employeeId, d = new Date().toLocaleDateString("en-CA", { timeZone:"Asia/Manila" });
  const path = `${bId}/${d}/${emp}_${Date.now()}.jpg`;
  const up = await sb.storage.from("kfr-att").upload(path, att.blob, { contentType:"image/jpeg", upsert:false });
  if (up.error) return toast(up.error.message);
  const { data, error } = await sb.from("attendance").insert({ branch_id: bId, employee_id: emp, date: d, clock_in: new Date().toISOString(),
    photo_path: path, lat: att.pos?.latitude ?? null, lng: att.pos?.longitude ?? null, accuracy_m: att.pos ? Math.round(att.pos.accuracy) : null })
    .select("clock_in,verified,distance_m").single();   // 시각·날짜·거리·✅ = 서버 값
  if (error) return toast(error.message);
}
// 사진 보기 (필요할 때만)
const { data } = await sb.storage.from("kfr-att").createSignedUrl(row.photo_path, 300);
// 관리자 시각 수정 (원래 시각 자동 보존)
await sb.from("attendance").update({ clock_in: inTs.toISOString(), clock_out: outTs?.toISOString() ?? null, admin_edit: true }).eq("id", id);
// 사진 정리: DB 먼저 → 비워진 것만 Storage 삭제
const up = await sb.from("attendance").update({ photo_path: null }).in("id", ids).select("id,photo_path");
const ok = new Set(up.data.filter((r) => !r.photo_path).map((r) => r.id));
await sb.storage.from("kfr-att").remove(rows.filter((r) => ok.has(r.id)).map((r) => r.photo_path));
```
CSS는 kcafe의 `.cam-wrap`(4:3, 전면 카메라는 `transform:scaleX(-1)`로 미리보기만 좌우반전), `.gps-line.ok/.warn`, `.shift`, `.late-tag`, `.att-table`(첫 열 sticky)을 가져오면 됩니다. 휴대폰 폭 390px에서 가로 넘침이 없는지 확인.

## 6. 빌드 순서
1. `supabase/attendance.sql` 추가 → 사용자에게 SQL Editor 실행 요청
2. 본사 `관리`: 지점 위치/반경 + 지점별 직원 관리
3. 지점 `출퇴근` 탭: 직원 선택+PIN → 사진+GPS 출근 → 퇴근 → 최근 기록 + 지점 설정 카드(📍 좌표 등록, 자기 지점 직원 관리)
4. 본사 `근태` 탭: 지점·월 필터 표, 사진 보기, 수정, 빠진 근무 추가
5. 사진 보관 정리 (본사 로그인 시 하루 1회 + `지금 정리`)
6. 다국어(지점 화면 영어+따갈로그), 모바일 레이아웃

## 7. 테스트 체크리스트
- [ ] 지점 A 직원이 A 매장 안에서 출근 → ✅, 시각은 서버 시각
- [ ] 지점 B 좌표가 없으면 → "위치 기록됨(지점 좌표 미등록)", ⚠️
- [ ] 지점 계정에서 다른 지점 직원은 목록에 안 보임 / DB도 거부
- [ ] 틀린 개인 PIN → 거부
- [ ] 갤러리 사진으로 출근 불가 (앱 카메라만)
- [ ] 퇴근 → 근무시간 표시, 16시간 넘은 열린 근무는 직원이 못 닫음
- [ ] 본사 근태표: 지점 필터, 📷 사진, ✏️ 수정 후 `수정됨(원래 09:12)`, 빠진 근무 추가
- [ ] 휴대폰 폭에서 가로 스크롤 없음, 기존 탭(마감·밀키트·정산 등) 그대로 동작
