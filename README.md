# ☕ Bahay Cafe

필리핀 카페 원격 관리 웹앱. K-Food(`koreayjk/kfr`) 구조를 그대로 따른 **단일 `index.html`**(바닐라 JS + Supabase) 앱입니다.

## 처음 설정 (1회)
1. K-Food와 **같은 Supabase 프로젝트** → SQL Editor 에서 순서대로 실행
   - [`supabase/cafe_schema.sql`](supabase/cafe_schema.sql) — 기본 스키마(`cafe` 테이블, 공용 `kfr.supply_requests`, RLS, Storage 버킷 `cafe`, 첫 관리자 계정)
   - [`supabase/02_attendance.sql`](supabase/02_attendance.sql) — 출퇴근 서버 인증(시각·거리·✅를 DB가 결정)
   - [`supabase/03_board.sql`](supabase/03_board.sql) — 게시판 안 읽음 표시·마지막 활동 시각
   - [`supabase/04_inventory.sql`](supabase/04_inventory.sql) — 입출고 장부로 현재고 자동 계산
   - [`supabase/05_kfood_link.sql`](supabase/05_kfood_link.sql) — K-Food 공급요청 상태 흐름·입고 처리 잠금
   - [`supabase/06_sales.sql`](supabase/06_sales.sql) — 마감(카드/기타 결제, 마감자·수정시각)·지출 기록자
2. **Integrations → Data API → Settings → Exposed schemas** 에 `cafe` 추가 (`kfr` 도 유지)
3. 앱 접속 → `사장` / PIN `0000` 로그인 → **관리** 탭에서 PIN 변경, 직원 추가
4. 매장 안에서 **관리 → 📍 지금 위치를 매장 좌표로 등록** (출근 지오펜스 기준점, 기본 반경 100m)
5. GitHub → Settings → Pages → Source: **GitHub Actions** (main 푸시 시 자동 배포, HTTPS라 카메라·GPS 사용 가능)

## 로고 / 색
- 로고 파일을 저장소에 올리고 `index.html` 의 `const LOGO = ""` 에 경로 입력 (비우면 글자 로고)
- 색은 `index.html` 상단 `:root` 의 `--accent*` 5개 값만 바꾸면 전체 적용

## 빌드 진행
| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | SQL · 로그인(직원+PIN, role 분기) · 탭 라우팅 · 두 스키마 연결 | ✅ |
| – | 대시보드(오늘 매출·근무 중·저재고·승인 대기·미해결 글), 관리(직원·매장 좌표·반경) | ✅ |
| 2 | 출퇴근(사진+GPS+서버시각) · 근태 | ✅ |
| 3 | 게시판 + 댓글 + 대시보드 피드 | ✅ |
| 4 | 재고(입출고·저재고) + 주문요청 + 공급요청 승인 | ✅ |
| 5 | K-Food 연동 (`kfr.supply_requests` + K-Food 앱 ☕카페 UI + 배송완료 → 입고 처리) | ✅ |
| 6 | 마감/매출 · 일별 매출 · 메뉴 순위 · 월별 보고서 · 메뉴/지출 관리 | ✅ |

기획 전체는 인수인계 문서(Bahay Cafe 관리 프로그램 — 기획 & 인수인계 MD v2) 참고.
