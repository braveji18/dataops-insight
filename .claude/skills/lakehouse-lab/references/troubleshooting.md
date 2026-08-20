# lakehouse-lab 트러블슈팅

증상 → 원인 → 조치. 여기 없는 증상이면 로그부터 본다:

```bash
cd scripts/testenv
docker compose --env-file .env logs --tail 100 <서비스명>
# 서비스명: minio | hms-postgres | hive-metastore | trino-coordinator | trino-worker | starrocks-fe | starrocks-be
```

## 기동 실패

| 증상 | 원인 | 조치 |
|---|---|---|
| `up.sh` 가 "Docker 메모리 부족"으로 중단 | 프로파일 요구치 미달 | Docker Desktop > Settings > Resources 에서 메모리 상향. `functional` 은 8GB, `perf` 는 16GB 필요 |
| `lab-hive-metastore` 가 계속 restarting | HMS가 PostgreSQL 스키마 초기화에 실패 | `docker compose logs hive-metastore` 확인. 볼륨이 이전 버전 상태로 남았으면 `bin/reset.sh` |
| HMS 로그에 `ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem` | S3A jar 주입 실패 | `conf/hms/Dockerfile` 의 `HADOOP_AWS_VERSION` 이 base 이미지의 Hadoop 버전과 다름. `docker run --rm --entrypoint sh <hive-image> -c 'ls /opt/hive/lib \| grep hadoop-common'` 로 확인 후 `versions.env` 수정 → `dc build --no-cache hive-metastore` |
| `lab-trino-coordinator` 가 기동 직후 종료 | `query.max-memory-per-node` 가 힙 대비 과다 | 힙 = `TRINO_*_MEM` × 0.8, 허용치 = 힙 × 0.7. 프로파일 값 조정 |
| `lab-starrocks-be` 가 OOMKilled | `SR_BE_MEM_LIMIT` ≥ 컨테이너 `SR_BE_MEM` | be.conf 의 `mem_limit` 을 컨테이너 한도보다 작게 |
| BE 가 뜨는데 `SHOW BACKENDS` 가 비어 있음 | FE에 BE 등록 실패 | `bin/q.sh sr --no-prelude "ALTER SYSTEM ADD BACKEND 'starrocks-be:9050'"` 수동 실행 후 재확인 |
| `lab-starrocks-be` 가 `Exited (139)` | BE 프로세스 SIGSEGV. 자원 문제가 아니라 **버그**다 | 크래시 스택을 먼저 볼 것: `docker cp lab-starrocks-be:/opt/starrocks/be/log/be.out - \| tar -xO \| tail -40`. 실제 사례: `docs/evidence/A-5/20260820-starrocks-4.0.1-parquet-date-zonemap-crash.md` |
| BE 를 되살렸는데 쿼리가 계속 `Failed to find backend to execute` (그런데 `SHOW BACKENDS` 는 `Alive=true`) | FE 가 죽었던 BE 를 **자동 블랙리스트**에 올린 상태 | `bin/q.sh sr --no-prelude "SHOW BACKEND BLACKLIST"` → `bin/q.sh sr --no-prelude "DELETE BACKEND BLACKLIST <id>"` |

## 카탈로그 / S3

| 증상 | 원인 | 조치 |
|---|---|---|
| `Failed to create external path s3://... : null` (CREATE SCHEMA 실패) | HMS 에 `s3` 스킴 구현이 매핑돼 있지 않음 | `metastore-site.xml` 의 `fs.s3.impl` / `fs.AbstractFileSystem.s3.impl` 확인. Hadoop 은 `s3a` 만 기본 등록하지만 Trino/StarRocks 는 `s3://` 로 location 을 쓴다 |
| `UnknownHostException: lakehouse.minio` | path-style access 누락 | MinIO는 가상호스트 스타일을 못 쓴다. Trino `s3.path-style-access=true`, StarRocks `aws.s3.enable_path_style_access="true"`, HMS `fs.s3a.path.style.access=true` — **세 곳 모두** 필요 |
| Trino: `Failed to list directory` / 403 | 자격증명 불일치 | `versions.env` 의 `S3_ACCESS_KEY/SECRET` 과 `iceberg.properties`, `metastore-site.xml`, `00-starrocks-catalog.sql` 값이 전부 같아야 한다 |
| StarRocks만 테이블이 안 보임 | 카탈로그 미등록 또는 메타 캐시 | `bin/q.sh sr --no-prelude "SHOW CATALOGS"` → 없으면 `bin/q.sh sr --no-prelude -f sql/00-starrocks-catalog.sql`. 있으면 `REFRESH EXTERNAL TABLE iceberg.bench.<t>` |
| Trino만 테이블이 안 보임 | HMS 캐시 | 잠시 후 재시도하거나 coordinator 재시작 (`docker compose restart trino-coordinator`) |
| 양쪽 행 수가 다름 | 한쪽이 오래된 스냅샷을 봄 | StarRocks에서 `REFRESH EXTERNAL TABLE`. 그래도 다르면 `bin/seed.sh --force` |

## 쿼리 실행

| 증상 | 원인 | 조치 |
|---|---|---|
| `q.sh sr` 가 `ERROR 1064` 로 실패 | SQL 방언 차이 | SKILL.md 의 방언 표 확인. 식별자 인용은 Trino `"col"` / StarRocks `` `col` `` |
| `q.sh trino` 결과가 비어 있고 rc=0 | 스키마 prelude가 원인 | `--no-prelude` 로 다시. `system.*` 조회 시 특히 |
| `SET CATALOG` 가 안 먹음 | prelude 없이 실행됨 | `--no-prelude` 를 뺐는지 확인, 또는 `iceberg.bench.t` 처럼 전체 경로로 |
| 쿼리가 메모리 초과로 실패 | `functional` 프로파일의 힙이 작음 | 작은 데이터로 검증하거나 `bin/up.sh perf` |

## 상태가 꼬였을 때

```bash
bin/down.sh --purge && bin/up.sh    # 볼륨까지 지우고 처음부터
```

버전을 올린 뒤(`versions.env` 수정)에는 **반드시** `bin/reset.sh` 를 돌린다. StarRocks FE 메타와 HMS DB가 이전 버전 상태로 남으면 조용히 이상 동작한다.
