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
  - docs/evidence : 실제 쿼리로 확인한 검증 증거


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


