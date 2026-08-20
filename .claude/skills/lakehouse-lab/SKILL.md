---
name: lakehouse-lab
description: Trino vs StarRocks 로컬 비교 테스트 환경을 띄우고, 상태를 확인하고, 양쪽 엔진에 쿼리를 실행할 때 사용한다. 동일한 Iceberg 카탈로그(Hive Metastore + MinIO)를 Trino(coordinator+worker)와 StarRocks(FE+BE)에 등록한 Docker 랩. "테스트 환경 띄워", "양쪽에서 쿼리 돌려봐", "이 동작 실제로 확인해줘", "성능 비교해줘" 같은 요청에 해당한다.
---

# lakehouse-lab

Trino와 StarRocks가 **완전히 동일한 Iceberg 테이블**을 읽도록 구성한 로컬 랩. `docs/`에 쓰는 소스코드 분석 주장을 실제 쿼리로 검증하기 위한 장치다.

```
MinIO(S3) ← Hive Metastore(+PostgreSQL) ← 동일한 Iceberg 카탈로그 (이름도 양쪽 다 `iceberg`)
                    ↑                              ↑
       Trino coordinator + worker         StarRocks FE + BE
```

## 원칙 — 이 파일을 읽는 AI가 지켜야 할 것

1. **compose 파일이나 설정을 새로 생성하지 않는다.** 환경 자산은 `scripts/testenv/` 에 이미 검증된 상태로 있다. 매번 생성하면 재현성이 깨진다. 필요한 건 실행뿐이다.
2. **버전을 임의로 바꾸지 않는다.** `scripts/testenv/versions.env` 가 유일한 버전 소스이고, `works/` 의 클론 태그와 반드시 짝을 이룬다. 어긋나면 런타임 증거가 코드 인용을 검증하지 못한다.
3. **green 판정은 `bin/status.sh` 의 exit code 로만 한다.** 로그를 보고 "잘 뜬 것 같다"고 판단하지 않는다.
4. **성능 수치를 인용할 때는 반드시 호스트 조건을 함께 적는다.** arm64 랩 숫자는 x86 운영 환경으로 이전 불가다.

## 명령

모든 명령은 `scripts/testenv/` 기준이다.

| 목적 | 명령 |
|---|---|
| 기동 (기능 검증용, 기본) | `bin/up.sh` |
| 기동 (성능 비교용, Docker 16GB↑) | `bin/up.sh perf` |
| 상태 확인 — **exit 0 이면 실험 가능** | `bin/status.sh` |
| 쿼리 (Trino) | `bin/q.sh trino "SELECT ..."` |
| 쿼리 (StarRocks) | `bin/q.sh sr "SELECT ..."` |
| 실행 계획 | `bin/q.sh trino --explain "SELECT ..."` |
| 시드 재적재 | `bin/seed.sh [--force] [--with-native]` |
| 성능 비교 | `bin/bench.sh --label q1 -f q.sql` |
| 종료 (데이터 유지) | `bin/down.sh` |
| 완전 초기화 | `bin/reset.sh` |

`q.sh` 의 출력은 양쪽 엔진 모두 **TSV + 헤더**로 통일돼 있어 그대로 diff 할 수 있다.
기본 카탈로그/스키마는 `iceberg` / `bench`. `system.runtime.*`, `SHOW BACKENDS` 처럼 카탈로그 지정이 방해되는 쿼리는 `--no-prelude` 를 붙인다.

## 표준 작업 흐름

```bash
cd scripts/testenv
bin/status.sh || bin/up.sh        # 이미 떠 있으면 up 은 건너뛴다
bin/q.sh trino "SELECT count(*) FROM lineitem"
bin/q.sh sr    "SELECT count(*) FROM lineitem"
```

시드 데이터는 TPC-H(`bench` 스키마: nation/region/supplier/part/partsupp/customer/orders/lineitem).
프로파일 `functional` 은 SF 0.01, `perf` 는 SF 1.

## 두 엔진의 SQL 방언 차이 (쿼리를 짤 때 자주 걸리는 것)

| | Trino | StarRocks |
|---|---|---|
| 카탈로그 전환 | `--catalog iceberg` 또는 `iceberg.bench.t` | `SET CATALOG iceberg;` 또는 `iceberg.bench.t` |
| 문자열 리터럴 | 작은따옴표만 | 작은/큰따옴표 모두 |
| 식별자 인용 | `"col"` | `` `col` `` |
| 실행 계획 | `EXPLAIN`, `EXPLAIN ANALYZE` | `EXPLAIN`, `EXPLAIN ANALYZE`, `EXPLAIN COSTS` |
| 통계 수집 | `ANALYZE iceberg.bench.t` | `ANALYZE TABLE iceberg.bench.t` |
| 프로파일 | Web UI(8080) / `system.runtime.queries` | `SHOW PROFILELIST` → `ANALYZE PROFILE FROM '<id>'` |

## 더 읽을 것

- **측정 규칙과 공정성** — 벤치마크를 돌리기 전에 반드시: `references/protocol.md`
- **깨졌을 때** — 실패 증상별 원인표: `references/troubleshooting.md`
- **왜 이렇게 구성했는가** — FE+BE 선택, 버전 고정 근거: `plan/02-테스트환경-설계.md`
