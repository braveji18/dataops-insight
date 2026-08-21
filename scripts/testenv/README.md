# lakehouse-lab — Trino vs StarRocks 비교 테스트 환경

두 엔진이 **완전히 동일한 Iceberg 테이블**을 읽도록 구성한 Docker 랩. AI 없이 사람이 직접 써도 된다.

```
MinIO(S3) ← Hive Metastore(+PostgreSQL) ← 동일한 Iceberg 카탈로그 (양쪽 다 이름이 `iceberg`)
                    ↑                              ↑
       Trino coordinator + worker         StarRocks FE + BE
```

## 빠른 시작

```bash
cd scripts/testenv
bin/up.sh                 # 기동 + 시드 + 상태 점검까지 (최초 실행은 이미지 pull 로 10~20분)
bin/q.sh trino "SELECT count(*) FROM lineitem"
bin/q.sh sr    "SELECT count(*) FROM lineitem"
bin/down.sh               # 종료 (데이터 볼륨은 유지)
```

`bin/status.sh` 가 **exit 0** 이면 비교 실험을 시작해도 되는 상태다. 컨테이너가 떠 있는 것과
비교가 가능한 것은 다르기 때문에, 판정은 눈이 아니라 이 스크립트가 한다.

접속:

| | 주소 |
|---|---|
| Trino Web UI | http://localhost:8080 |
| Trino JDBC | `jdbc:trino://localhost:8080/iceberg/bench` (user 아무거나) |
| StarRocks FE UI | http://localhost:8030 |
| StarRocks MySQL | `mysql -h127.0.0.1 -P9030 -uroot` |
| MinIO 콘솔 | http://localhost:9001 (minio / minio123) |

## 명령

| | |
|---|---|
| `bin/up.sh [profile] [--hive N] [--no-seed]` | 기동 (멱등 — 이미 떠 있으면 부족한 것만 채운다) |
| `bin/status.sh` | 상태 점검. **exit 0 = 비교 실험 가능** |
| `bin/q.sh <trino\|sr> "SQL"` | 쿼리. 출력은 양쪽 모두 TSV+헤더로 통일 |
| `bin/q.sh <trino\|sr> --explain -f q.sql` | 실행 계획 비교 |
| `bin/seed.sh [--force] [--with-native]` | 시드 적재 |
| `bin/bench.sh --label X -f q.sql` | 양쪽 시간 측정 → `results/*.json` |
| `bin/down.sh [--purge]` | 종료 (`--purge` 는 볼륨까지) |
| `bin/reset.sh [profile] [--hive N]` | 볼륨 삭제 후 완전 재기동 |

## 두 개의 축: 프로파일 × Hive 변형

랩 구성은 **자원·데이터 규모(프로파일)** 와 **HMS 버전(hive 변형)** 두 축으로 나뉜다.
서로 독립이라 조합해서 쓴다.

### 프로파일 — `profiles/*.env`

| | functional (기본) | perf |
|---|---|---|
| 데이터 | TPC-H SF 0.01 | TPC-H SF 1 |
| Docker 메모리 | 8GB 이상 | 16GB 이상 |
| 용도 | 기능·플랜·방언 검증 | 같은 호스트에서의 상대 시간 비교 |

### Hive 변형 — `hive/hive*.env`

| | hive 4 (기본) | hive 3 |
|---|---|---|
| 버전 | 4.0.1 | 3.1.3 |
| 아키텍처 | 멀티아치 (네이티브) | amd64 단독 — arm64 호스트에서는 에뮬레이션 |
| 용도 | 최신 기준선 | 실무에 많이 남아 있는 Hive 3 계열에서의 동작 확인 |

```bash
bin/up.sh                      # functional + hive 4
bin/up.sh perf                 # perf + hive 4
bin/up.sh --hive 3             # functional + hive 3
bin/reset.sh perf --hive 3     # perf + hive 3 으로 갈아엎기
```

**★ hive 변형 전환은 `reset` 이 필요하다.** Hive 3 과 4 는 metastore 백엔드 스키마 버전이
다르다(3.1.0 vs 4.0.0). 같은 볼륨 위에서 변형만 바꾸면 schematool 이 죽거나, 더 나쁘게는
반쯤 동작한다. 그래서 `up.sh` 가 전환을 감지하면 실행을 거부하고 `reset.sh` 를 안내한다.
reset 은 MinIO 데이터까지 지우므로 **시드를 다시 만든다**(functional 기준 1~2분).

## 설정이 합쳐지는 방식

```
versions.env         버전 기준선 (이미지 digest, 랩 고정 상수)
hive/hive<N>.env     HMS 변형 (이미지 / hadoop-aws / aws-sdk / 아키텍처가 한 세트)
profiles/<p>.env     자원·데이터 규모
                                  ↓  up.sh 가 합성
.env                 생성물. 직접 고치지 말 것 — 다음 up.sh 가 덮어쓴다
```

값을 바꾸려면 항상 위 세 원본 중 하나를 고친다. `.env` 는 gitignore 대상이다.

## 파일 구조

```
versions.env              ★ 버전 단일 소스. works/ 클론 태그와 반드시 일치시킬 것
hive/*.env                HMS 변형 (hive3 / hive4)
profiles/*.env            프로파일별 자원·데이터 규모
docker-compose.yml
conf/trino/               coordinator / worker / catalog(iceberg, tpch, tpcds)
conf/starrocks/           fe.conf, be.conf (이미지 기본 설정에 append 되는 오버라이드)
conf/hms/                 Dockerfile(S3A jar 주입) + metastore-site.xml + entrypoint 래퍼
sql/                      StarRocks 카탈로그 등록 DDL, 시드 SQL
queries/                  비교용 쿼리 (TPC-H Q1, 푸시다운 판별 등)
bin/                      실행 스크립트
results/                  bench 결과 JSON (gitignore)
.env                      up.sh 생성물 (gitignore)
```

## 검증 현황

| 조합 | 상태 |
|---|---|
| macOS arm64 / functional / hive 4 | ✅ 확인 (기동·시드·재기동 멱등성·행 수 일치) |
| macOS arm64 / functional / hive 3 | ✅ 확인 (에뮬레이션) |
| macOS arm64 / perf | 미검증 |
| 리눅스 (x86 / arm) | 미검증 |

리눅스는 스크립트 수준에서는 대응돼 있으나(BSD/GNU 차이 회피, bash 3.2 문법) 실행한 적이
없다. 특히 **리눅스 arm64 에서 `--hive 3` 은 qemu binfmt 등록이 별도로 필요하다** —
Docker Desktop 은 자동 제공하지만 리눅스 네이티브 도커는 그렇지 않다.

## 주의

- **성능 수치는 이 랩 조건에서의 상대값**이다. worker 1대 / BE 1대, 컨테이너 자원 제약,
  arm64 에서는 StarRocks BE 의 SIMD 경로까지 다르다. 운영 환경 절대값으로 인용하지 말 것.
- 버전을 바꿀 때는 `versions.env` 만 수정하고 `bin/reset.sh` 를 돌린다.
- 설계 근거(FE+BE를 고른 이유, 버전 고정 이유 등)는 `plan/02-테스트환경-설계.md`.
