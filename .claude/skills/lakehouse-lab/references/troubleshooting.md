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
| `lab-hive-metastore` 가 `Exited (137)`, 로그가 ObjectStore 초기화 중간에 끊김 | SIGKILL = 컨테이너 메모리 한도 초과. 이미지가 `-Xmx1G` 를 강제하는데 `HMS_MEM` 이 그보다 작음 | 프로파일의 **`HMS_MEM` 을 올린다**(힙을 줄이면 GC 스래싱으로 더 나빠진다 — 512m 에서 schematool 이 6분간 정지한 실측 있음). `common.sh` 의 `lab_check_hms_mem` 이 렌더링 단계에서 미리 막는다 |
| Hive 3 에서 HMS 가 PostgreSQL 인증에 실패 | 이미지 동봉 `postgresql-9.4` 드라이버가 SCRAM-SHA-256 미지원 (PG16 기본 인증) | `conf/hms/Dockerfile` 이 9.4 를 제거하고 42.7.4 만 남긴다. 이미지를 다시 구울 것: `dc build --no-cache hive-metastore` |
| `up.sh` 가 `hive 변형이 바뀌었다 (현재 .env=4 → 요청=3)` 로 종료 | **의도된 가드.** Hive 3/4 는 metastore 스키마 버전이 다르다(3.1.0 vs 4.0.0). 같은 볼륨에서 바꾸면 죽거나 반쯤 동작한다 | `bin/reset.sh <profile> --hive N`. 볼륨을 지우므로 시드가 다시 만들어진다 |
| `lab-trino-coordinator` 가 기동 직후 종료 | `query.max-memory-per-node` 가 힙 대비 과다 | 힙 = `TRINO_*_MEM` × 0.8, 허용치 = 힙 × 0.7. 프로파일 값 조정 |
| `lab-starrocks-be` 가 OOMKilled | `SR_BE_MEM_LIMIT` ≥ 컨테이너 `SR_BE_MEM` | **`profiles/*.env` 의 `SR_BE_MEM_LIMIT`** 을 `SR_BE_MEM` 보다 작게. (이 값은 docker-compose.yml 의 기동 명령이 be.conf 말미에 주입한다 — be.conf 파일 자체에는 없다) |
| HMS 로그에 `ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem` | S3A jar 주입 실패 | `HADOOP_AWS_VERSION` 이 base 이미지의 Hadoop 버전과 다름. `docker run --rm --entrypoint sh <hive-image> -c 'ls /opt/hive/lib \| grep hadoop-common'` 로 확인 후 **`hive/hive3.env` 또는 `hive/hive4.env`** 수정 → `dc build --no-cache hive-metastore` |
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
| 스크립트가 끝나지 않고 멈춤 (컨테이너는 healthy, 작업은 이미 완료돼 있음) | `docker compose exec -T` 가 stdin EOF 를 기다림. nohup·백그라운드 잡·CI·에이전트처럼 stdin 이 열린 채 EOF 가 안 오는 실행에서 발생 | `common.sh` 의 `lab_sr_exec` 와 `q.sh` 는 stdin 을 `/dev/null` 로 끊는다. 새로 `dc exec` 를 쓰는 코드를 추가한다면 **반드시 같이 끊을 것** |

## 리눅스에서만 나는 문제

랩은 리눅스에서 실행 검증된 적이 없다(macOS arm64 에서 hive 3/4 모두 확인). 예상 지점:

| 증상 | 원인 | 조치 |
|---|---|---|
| arm64 리눅스에서 `--hive 3` 이 `exec format error` | hive 3 은 amd64 단독 이미지인데 qemu binfmt 미등록. Docker Desktop 은 자동 제공하지만 네이티브 도커는 아니다 | `docker run --privileged --rm tonistiigi/binfmt --install amd64` |
| 메모리 검사를 통과했는데 OOM | 리눅스 네이티브 도커에서 `docker info` 의 MemTotal 은 호스트 총 RAM 이라 다른 프로세스 몫이 빠지지 않는다 | 여유를 직접 확인하거나 더 작은 프로파일 사용 |
| compose 가 포트 바인딩 에러로 죽음 | 8080/9000/9001/8030/9030/9083/8040 중 충돌. 사전 검사 없음 | `ss -ltnp` 로 점유 프로세스 확인 후 정리 |

## 상태가 꼬였을 때

```bash
bin/down.sh --purge && bin/up.sh    # 볼륨까지 지우고 처음부터
```

버전을 올린 뒤(`versions.env` 수정)에는 **반드시** `bin/reset.sh` 를 돌린다. StarRocks FE 메타와 HMS DB가 이전 버전 상태로 남으면 조용히 이상 동작한다.
