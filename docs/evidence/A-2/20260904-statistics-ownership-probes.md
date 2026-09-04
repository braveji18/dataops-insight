# A-2 통계 수집 주체 — 판별 probe 5종

> 대상 문서: `docs/A-2-07-통계-수집-주체.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64 (8 CPU / 16GB), hive=4, 세션 변수·FE Config 전부 기본값.
**probe 종료 후 생성한 테이블(`iceberg.bench.statprobe`, `statprobe2`)과 그 통계는 삭제했다.**

---

## probe 1 — 통계가 어디에 저장되는가

### 주장

StarRocks 는 **엔진 자신의 데이터베이스**에 통계를 쌓는다. Trino 는 **테이블 포맷 안**에 있는 것을 읽는다.

### 판별

```sql
-- StarRocks
SHOW TABLES FROM _statistics_;
```

### 결과

StarRocks 에 `_statistics_` 라는 내부 데이터베이스가 실재하고, 통계 테이블이 들어 있다.

```
column_statistics              external_column_statistics
histogram_statistics           external_histogram_statistics
multi_column_statistics        table_statistic_v1
predicate_columns              query_history / spm_baselines / loads_history / pipe_file_list
```

`external_column_statistics` 의 스키마:

| 컬럼 | 타입 |
|---|---|
| `table_uuid`, `partition_name`, `column_name` | varchar (키) |
| `catalog_name`, `db_name`, `table_name` | varchar |
| `row_count`, `data_size`, `null_count` | bigint |
| **`ndv`** | **`hll`** — HLL 스케치로 저장(병합 가능) |
| `min`, `max` | varchar(1048576) |
| `update_time` | datetime |

Iceberg 시드 테이블 8개에 대해 **65행**이 쌓여 있었다(`seed.sh` 가 적재 후 `ANALYZE` 를 돌린 결과).

Trino 쪽에는 대응물이 없다. `io/trino/spi/statistics/` 에 저장 관련 클래스가 없고,
Iceberg 커넥터는 manifest 요약(행 수·null 수·min/max)과 **Puffin blob**(NDV, `apache-datasketches-theta-v1`)에서 읽는다.

### 판정

**저장 주체가 다르다.** StarRocks = 엔진 내부 테이블 / Trino = 테이블 포맷 자체.

---

## probe 2 — 같은 테이블에 대해 무엇을 아는가

### 판별 쿼리

```sql
-- StarRocks
SELECT column_name, row_count, hll_cardinality(ndv) ndv, null_count, min, max
FROM _statistics_.external_column_statistics WHERE table_name='lineitem';

-- Trino
SHOW STATS FOR lineitem;
```

### 결과 (lineitem, 60175행)

| 컬럼 | 참 NDV | StarRocks NDV | Trino NDV | StarRocks min/max | Trino low/high |
|---|---|---|---|---|---|
| `l_orderkey` | 15000 | **15022** | **14819** | 1 / 60000 | 1 / 60000 |
| `l_suppkey` | 100 | 100 | 100 | 1 / 100 | 1 / 100 |
| `l_shipdate` | — | 2530 | 2518 | 1992-01-04 / 1998-11-29 | 1992-01-04 / 1998-11-29 |
| `l_returnflag` | 3 | 3 | 3 | **A / R** | **(없음)** |

두 가지가 눈에 띈다.

- **NDV 는 양쪽 다 근사값이고 방향이 다르다.** StarRocks 는 HLL, Trino 는 Theta 스케치를 쓴다. `l_orderkey` 참값 15000 에 대해 +0.15% / −1.2%
- **문자열 컬럼의 min/max 가 Trino 에는 없다.** `l_returnflag` 에 StarRocks 는 `A`/`R` 을 갖고 있지만 Trino 는 빈칸이다

후자는 SPI 구조에서 나온다 — `core/trino-spi/.../ColumnStatistics.java:26-29` 의 `range` 필드가 `Optional<DoubleRange>` 다. **숫자 범위만 표현할 수 있는 타입이다.**

### 판정

**수치 통계는 동등, 문자열 범위는 Trino 가 표현할 수 없다.**

---

## probe 3 — 한쪽이 만든 통계를 다른 쪽이 읽는가

### 주장

같은 Iceberg 테이블인데도 **통계는 공유되지 않는다.**

### 판별 절차

1. Trino 로 새 테이블을 만든다 (`CREATE TABLE … AS SELECT`). Trino 는 `collect_extended_statistics_on_write` 기본값이 `true` 라 **ANALYZE 없이도** NDV 를 테이블에 쓴다
2. Trino 에서 `SHOW STATS` 로 확인
3. StarRocks 에서 같은 테이블의 컬럼 통계를 확인

```sql
CREATE TABLE iceberg.bench.statprobe2 AS SELECT l_orderkey, l_suppkey FROM iceberg.bench.lineitem;
```

### 결과

| 확인 | 값 |
|---|---|
| Trino `SHOW STATS FOR statprobe2` | `l_orderkey` NDV **14830**, `l_suppkey` NDV **100**, row_count 60175 |
| StarRocks `_statistics_.external_column_statistics` 행 수 | **0** |
| StarRocks `EXPLAIN COSTS` 의 컬럼 통계 | `l_suppkey-->[99.0, Infinity, 0.0, 1.0, 1.0]` **`UNKNOWN`** |
| StarRocks 스캔 노드 카디널리티(술어 없음) | **60175** — 행 수는 안다 |

**행 수는 Iceberg 메타데이터에서 읽지만, 컬럼 통계는 읽지 않는다.**
Trino 가 Puffin 에 써 둔 NDV 가 그 테이블 안에 있는데도 StarRocks 는 `UNKNOWN` 으로 취급한다.

### 판정

**통계는 공유되지 않는다.** 같은 카탈로그·같은 파일을 보면서도 각자 자기 통계만 믿는다.

---

## probe 4 — StarRocks 는 자동으로, 그것도 골라서 수집한다 (★)

### 관찰

probe 3 을 진행하는 동안 **내가 실행하지 않은 `ANALYZE` 작업이 이력에 나타났다.**

```sql
SHOW ANALYZE STATUS;
```

```
27382  iceberg.bench  mvsrc       ALL                    FULL  ONCE  SUCCESS  2026-09-04 01:26:34
27494  iceberg.bench  statprobe   l_suppkey,l_shipdate   FULL  ONCE  SUCCESS  2026-09-04 01:55:34
27499  iceberg.bench  statprobe2  l_suppkey              FULL  ONCE  SUCCESS  2026-09-04 01:56:34
```

**수집된 컬럼 목록이 내가 술어에 쓴 컬럼과 정확히 일치한다.**

- `statprobe` — `WHERE l_suppkey > 50`, `WHERE l_suppkey > 99` 와 히스토그램 시도의 `l_shipdate` → `l_suppkey,l_shipdate`
- `statprobe2` — `WHERE l_suppkey > 99` 하나만 던졌다 → `l_suppkey`

테이블 생성부터 수집까지 **약 1분**이 걸렸다.

근거가 되는 저장소도 확인된다 — `_statistics_.predicate_columns`:

| fe_id | db_id | table_id | column_id | usage | last_used |
|---|---|---|---|---|---|
| 1 | 27303 | 27304 | -1 | **`normal,predicate,group_by`** | 2026-09-04 01:24:49 |

`usage` 값이 컬럼이 **어떻게 쓰였는지**(단순 참조 / 술어 / group by)를 구분해 기록한다.

### 판정

**StarRocks 는 쿼리를 관찰해 "통계가 필요한 컬럼"을 스스로 정하고 자동 수집한다.**
Trino 에는 이 개념 자체가 없다 — `ANALYZE` 는 사람이 실행해야 하고, 자동 수집은 **쓰기 시점**에만 일어난다.

> **주의**: 이 관찰은 계획된 probe 가 아니라 다른 probe 중에 드러난 것이다.
> 수집 주기(`statistic_collect_interval_sec` 기본 600초)와 술어 컬럼 영속화 주기
> (`statistic_predicate_columns_persist_interval_sec` 기본 60초)의 상호작용은 따로 재보지 않았다.

---

## probe 5 — 히스토그램

### 주장

StarRocks 에는 히스토그램이 있고 Trino 에는 개념 자체가 없다.

### 판별

```sql
-- StarRocks
ANALYZE TABLE iceberg.bench.lineitem UPDATE HISTOGRAM ON l_shipdate WITH 32 BUCKETS;
```

### 결과

| 엔진 | 결과 |
|---|---|
| StarRocks 4.0.14 | `ERROR 1064: Can't create histogram statistics on table type is ICEBERG` |
| Trino 483 | 문법 자체가 없다. `io/trino/spi/statistics/` 에 히스토그램 클래스 없음 |

StarRocks 에 저장 테이블(`histogram_statistics`, `external_histogram_statistics`)과 수집 잡
(`HistogramStatisticsCollectJob`, `ExternalHistogramStatisticsCollectJob`)이 있지만,
**Iceberg 외부 테이블에는 적용되지 않는다.**

### 판정

**StarRocks 만 히스토그램을 갖지만, 이 랩 조건(Iceberg 외부 테이블)에서는 쓸 수 없다.**
네이티브 테이블에서의 동작은 확인하지 못했다.

---

## 정리

| probe | 판정 |
|---|---|
| 1 저장 위치 | 엔진 내부 DB(SR) vs 테이블 포맷(Trino) |
| 2 통계 내용 | 수치는 동등, **문자열 min/max 는 Trino 가 표현 불가** |
| 3 공유 여부 | **공유되지 않는다.** SR 은 Iceberg 의 NDV 를 읽지 않는다(행 수는 읽는다) |
| 4 자동 수집 | **SR 만.** 그것도 술어에 쓰인 컬럼을 골라서 |
| 5 히스토그램 | SR 만 보유, 단 Iceberg 외부 테이블에는 불가 |

### 이 probe 로 판별하지 못한 것

- **통계 수집 비용** — 전체 스캔 vs 샘플링의 시간·자원 비용을 재지 않았다(`perf` 프로파일 필요, `plan/02` 6-2절)
- **StarRocks 네이티브 테이블** — 히스토그램, 동기 수집, 파티션 단위 수집은 네이티브 테이블 전용 경로다
- **자동 수집의 트리거 조건** — `statistic_auto_collect_ratio`(0.8), 소/대 테이블 구분(5GB / 10M행), 수집 주기의 상호작용을 통제된 조건에서 재보지 않았다
- **다중 컬럼 결합 통계** — `_statistics_.multi_column_statistics` 테이블은 있으나 수집·활용 경로를 시험하지 않았다(A-2-04 3-6에서 `cbo_push_down_aggregate_with_multi_column_stats` 로 등장)
- **Hive/Delta 등 다른 커넥터** — Iceberg 하나로만 확인했다. Hive 는 HMS 에 통계를 두므로 양쪽 동작이 다를 수 있다
- **통계가 틀렸을 때의 영향** — 오차가 플랜을 뒤집는 지점은 A-2-01·A-2-03의 주제다
