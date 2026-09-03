# dataops-insight

## 프로젝트 개요
- 오픈소스 trino 와 StarRocks를 소스코드에서 기능을 비교하는 프로젝트입니다.
- trino git url : https://github.com/trinodb/trino.git
- StarRocks  git url : https://github.com/StarRocks/starrocks.git


## 디렉토리 구조

- works : trino와 starrocks를 소스코드를 다운받아서 코드 분석을 위한 디렉토리
- plan :  trino 와 starrocks을 비교하기 위한 계획 문서를 저장하는 디렉토리
- scripts : 비교 작업을 진행하는 코드를 저장하는 디렉토리
  - scripts/testenv : 두 엔진을 동일 조건으로 띄우는 테스트 환경(lakehouse-lab)
- docs : 비교 결과를 저장하는 디렉토리
  - docs/00-목차.md : 산출 문서 목록과 진행 상태
  - docs/evidence : 실제 쿼리로 확인한 검증 증거
  - docs/report : 경영·관리자 보고용으로 다시 쓴 문서


## 테스트 환경

소스코드 분석 결과를 실제 쿼리로 검증하기 위한 로컬 Docker 랩.
Trino(coordinator+worker)와 StarRocks(FE+BE)가 **동일한 Iceberg 카탈로그**(Hive Metastore + MinIO)를 공유한다.

```bash
cd scripts/testenv
bin/up.sh                                          # 기동 + 시드 + 상태 점검
bin/q.sh trino "SELECT count(*) FROM lineitem"
bin/q.sh sr    "SELECT count(*) FROM lineitem"
```

- 사용법: `scripts/testenv/README.md`
- 설계 근거와 한계: `plan/02-테스트환경-설계.md`
- 버전 기준선: `scripts/testenv/versions.env` (works/ 클론 태그와 반드시 일치)

AI로 작업할 때는 skill `lakehouse-lab` 과 agent `dual-engine-runner` 가 이 환경을 다룬다.


## 보고용 문서 작성 (exec-report)

`docs/` 본문은 소스 경로와 라인 번호가 촘촘히 박힌 **검증용 문서**다. 그대로는 비전문가가 읽지 못한다.
같은 내용을 **읽는 사람이 판단할 수 있는 형태**로 옮기는 절차를 skill `exec-report` 로 고정해 두었다.

절차는 원본 보강 → 코드 인용 확정 → GitHub 영구 링크 → 단위 환산 → "읽는 법" 해설 → 발췌 대조 → 목차 갱신의 7단계다.
핵심은 **모든 기능 설명에 실제 코드와 링크를 붙이고, 확인하지 못한 것을 별도 절로 명시**하는 것이다.

```bash
python3 .claude/skills/exec-report/scripts/verify-code-blocks.py docs/report/01-조인-순서-결정-보고.md
```

- 산출물: `docs/report/<번호>-<제목>-보고.md`
- 진행 상태: `docs/00-목차.md` 의 "보고용 문서" 절
- 보고서 뼈대: `.claude/skills/exec-report/references/template.md`
- 전체 절차와 사용법 예시: `.claude/skills/exec-report/SKILL.md`
