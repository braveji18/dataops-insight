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
| `bin/up.sh [profile]` | 기동. profile = `functional`(기본) \| `perf` |
| `bin/status.sh` | 상태 점검. **exit 0 = 비교 실험 가능** |
| `bin/q.sh <trino\|sr> "SQL"` | 쿼리. 출력은 양쪽 모두 TSV+헤더로 통일 |
| `bin/seed.sh [--force] [--with-native]` | 시드 적재 |
| `bin/bench.sh --label X -f q.sql` | 양쪽 시간 측정 → `results/*.json` |
| `bin/down.sh [--purge]` | 종료 (`--purge` 는 볼륨까지) |
| `bin/reset.sh [profile]` | 완전 초기화 후 재기동 |

## 프로파일

| | functional (기본) | perf |
|---|---|---|
| 데이터 | TPC-H SF 0.01 | TPC-H SF 1 |
| Docker 메모리 | 8GB 이상 | 16GB 이상 |
| 용도 | 기능·플랜·방언 검증 | 같은 호스트에서의 상대 시간 비교 |

## 파일 구조

```
versions.env              ★ 버전 단일 소스. works/ 클론 태그와 반드시 일치시킬 것
profiles/*.env            프로파일별 자원·데이터 규모
docker-compose.yml
conf/trino/               coordinator / worker / catalog(iceberg, tpch, tpcds)
conf/starrocks/           fe.conf, be.conf (이미지 기본 설정에 append 되는 오버라이드)
conf/hms/                 Dockerfile(S3A jar 주입) + metastore-site.xml
sql/                      StarRocks 카탈로그 등록 DDL, 시드 SQL
bin/                      실행 스크립트
results/                  bench 결과 JSON (gitignore)
.env                      up.sh 생성물 (gitignore)
```

## 주의

- **성능 수치는 이 랩 조건에서의 상대값**이다. worker 1대 / BE 1대, 컨테이너 자원 제약, arm64에서는 SIMD 경로까지 다르다. 운영 환경 절대값으로 인용하지 말 것.
- 버전을 바꿀 때는 `versions.env` 만 수정하고 `bin/reset.sh` 를 돌린다. 볼륨을 남기면 이전 버전 메타가 섞인다.
- 설계 근거(FE+BE를 고른 이유, 버전 고정 이유 등)는 `plan/02-테스트환경-설계.md`.
