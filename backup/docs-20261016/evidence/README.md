# 증거 파일 디렉토리

실제 쿼리로 확인한 검증 결과를 비교 축별로 저장한다.

- 경로 규칙: `docs/evidence/<비교축>/<YYYYMMDD>-<probe>.md` (비교축 = plan/01 의 항목 번호, 예: `A-2`)
- 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
- 성능 원본 JSON 은 `scripts/testenv/results/` (gitignore). 인용할 값만 여기로 옮겨 적는다.
