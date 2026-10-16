# A-2 푸시다운 범위 — 판별 probe 7종

> 대상 문서: `docs/A-2-04-푸시다운-범위.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64 (8 CPU / 16GB), hive=4, 캐시=기본값, **양쪽 모두 seed 시 통계 수집 완료**.
모든 판별은 `EXPLAIN` 플랜 모양으로만 한다 — 실행 시간은 재지 않았다.

---

## probe 1 — 스캔 술어 푸시다운에 "커넥터와의 협상"이 있는가

### 주장

Trino는 술어를 커넥터에 넘겨보고 **커넥터가 책임지겠다고 한 부분만 플랜에서 제거**한다.
StarRocks는 술어를 스캔 오퍼레이터에 **무조건 흡수**하며, 그 술어는 항상 스캔 노드에 남는다.

### 판별 쿼리

파티션 컬럼(스토리지가 보장 가능)과 비파티션 컬럼(보장 불가)에 같은 형태의 술어를 건다.
차이가 나면 "누가 책임지는가"를 플랜이 구분한다는 뜻이다.

```sql
-- 판별용 파티션 테이블 (Trino 로 생성 후 삭제)
CREATE TABLE iceberg.bench.pdprobe WITH (partitioning = ARRAY['l_linestatus']) AS
  SELECT l_orderkey, l_linestatus, l_shipdate, l_extendedprice FROM iceberg.bench.lineitem;

SELECT count(*) FROM pdprobe WHERE l_linestatus = 'F';           -- 파티션 컬럼
SELECT count(*) FROM pdprobe WHERE l_shipdate > DATE '1998-01-01'; -- 비파티션 컬럼
```

### 결과

| 엔진 | 파티션 컬럼 술어 | 비파티션 컬럼 술어 |
|---|---|---|
| Trino 483 | `TableScan[... constraint on [l_linestatus]]` — **필터 노드 없음** | `ScanFilterProject[... filterPredicate = (date '1998-01-01' < l_shipdate)]` |
| StarRocks 4.0.14 | `IcebergScanNode` + `PREDICATES: l_linestatus = 'F'` | `IcebergScanNode` + `PREDICATES: l_shipdate > '1998-01-01'` |

StarRocks 는 두 경우의 플랜 모양이 **같다**. `EXPLAIN VERBOSE` 로 보면 파티션 프루닝 자체는 일어난다(`partitions=1/2`).
즉 프루닝은 양쪽 다 하지만, **술어를 플랜에서 지우는 것은 Trino 뿐**이다.

### 판정

**설계 차이 확인.** 우열 아님 — Trino 쪽이 행 단위 재평가를 줄이지만, 그 대가로 커넥터가 `applyFilter` 를 정확히 구현해야 한다.

---

## probe 2 — 커넥터가 받을 수 없는 술어의 표현

### 주장

Trino의 `applyFilter` 는 "받은 것"을 테이블 핸들에 기록한다. 받지 못하면 기록이 비어 있다.

### 판별 쿼리

```sql
EXPLAIN (TYPE IO) SELECT count(*) FROM iceberg.bench.lineitem WHERE l_shipdate > DATE '1998-01-01';
EXPLAIN (TYPE IO) SELECT count(*) FROM iceberg.bench.lineitem WHERE l_orderkey % 7 = 0;
```

### 결과

| 술어 | `constraint.columnConstraints` |
|---|---|
| `l_shipdate > DATE '1998-01-01'` | `l_shipdate` 도메인 `(1998-01-01, +∞)` 기록됨 |
| `l_orderkey % 7 = 0` | `[ ]` — **비어 있음** |

두 경우 모두 `filterPredicate` 는 스캔 위에 남는다(lineitem 은 파티션 테이블이 아니므로 enforced 가 될 수 없다).
차이는 **커넥터가 파일 프루닝에 쓸 도메인을 받았는가**에서만 난다.

StarRocks 쪽 대응물은 `MIN/MAX PREDICATES` 줄이다.

| 술어 | StarRocks 스캔 노드 |
|---|---|
| `l_shipdate > '1998-01-01'` | `PREDICATES:` + **`MIN/MAX PREDICATES:`** 둘 다 |
| `l_orderkey % 7 = 0` | `PREDICATES:` 만 |

### 판정

**기능적으로 동등한 결과, 결정 주체가 다르다.** Trino 는 커넥터에게 물어보고, StarRocks 는 엔진에 하드코딩된 화이트리스트로 판단한다(`OptExternalPartitionPruner.isSupportedMinMaxConjuncts`).

---

## probe 3 — 조인 등가 전이 추론

### 주장

한쪽에만 건 술어가 조인 등가식을 타고 반대쪽으로 전파되는가.

### 판별 쿼리

```sql
SELECT count(*) FROM lineitem JOIN orders ON l_orderkey = o_orderkey WHERE l_orderkey < 100;
```

### 결과

| 엔진 | orders 스캔에 술어가 생겼는가 |
|---|---|
| Trino 483 | ✅ `ScanFilter[orders, filterPredicate = (o_orderkey < bigint '100')]` |
| StarRocks 4.0.14 | ✅ `PREDICATES: o_orderkey < 100` + `MIN/MAX PREDICATES` |

### 판정

**동등.**

---

## probe 4 — outer join 단순화

### 주장

보존되지 않는 쪽에 NULL 을 거르는 술어가 있으면 outer join 을 inner 로 바꾼다.

### 판별 쿼리

```sql
SELECT count(*) FROM lineitem LEFT JOIN orders ON l_orderkey=o_orderkey WHERE o_totalprice > 100000;
```

### 결과

| 엔진 | 조인 타입 |
|---|---|
| Trino 483 | `InnerJoin` |
| StarRocks 4.0.14 | `INNER JOIN (PARTITIONED)` |

### 판정

**동등.**

---

## probe 5 — 집계 아래로의 술어 푸시다운

### 판별 쿼리

```sql
SELECT * FROM (SELECT l_orderkey k, count(*) c FROM lineitem GROUP BY l_orderkey) t WHERE k < 100;
```

### 결과

| 엔진 | 결과 |
|---|---|
| Trino 483 | `ScanFilter[..., filterPredicate = (l_orderkey < bigint '100')]` — 집계 아래로 내려감 |
| StarRocks 4.0.14 | `IcebergScanNode ... PREDICATES: l_orderkey < 100` — 동일 |

### 판정

**동등.**

---

## probe 6 — 조인 아래로의 집계 푸시다운 (★ 판별력 있는 항목)

### 주장

두 엔진 모두 group-by 키의 NDV 를 보고 결정하지만 **임계값이 두 자릿수 배 차이 난다.**
Trino 는 "2배만 줄여도" 내리고, StarRocks 는 "100배는 줄어야" 후보로 본다.

### 판별 쿼리

같은 형태의 star-schema 조인 두 개를, **감소비만 다르게** 만든다.

```sql
-- A) 푸시 대상 group-by 키 = s_nationkey : NDV 25 / 소스 100행  → 감소비 4배
SELECT n_name, sum(s_acctbal) FROM supplier JOIN nation ON s_nationkey=n_nationkey GROUP BY n_name;

-- B) 푸시 대상 group-by 키 = l_suppkey  : NDV 100 / 소스 60175행 → 감소비 602배
SELECT s_name, sum(l_extendedprice) FROM lineitem JOIN supplier ON l_suppkey=s_suppkey GROUP BY s_name;
```

두 엔진 모두 같은 NDV 를 갖고 있음을 먼저 확인했다.

- Trino `SHOW STATS FOR supplier` → `s_nationkey` distinct_values_count **25**, row_count **100**
- StarRocks `EXPLAIN COSTS` → `s_nationkey-->[0.0, 24.0, 0.0, 8.0, 25.0]` (NDV **25**)

### 결과

| 쿼리 | 감소비 | Trino 483 | StarRocks 4.0.14 (기본 `cbo_push_down_aggregate_mode=0`) |
|---|---|---|---|
| A | 4배 | ✅ `Aggregate[type = PARTIAL, keys = [s_nationkey]]` 가 `InnerJoin` **아래** | ❌ 집계가 조인 위에 그대로 |
| B | 602배 | ✅ `Aggregate[type = PARTIAL, keys = [l_suppkey]]` 가 조인 아래 | ✅ 조인 아래에 집계 생성 |

A 를 `SET cbo_push_down_aggregate_mode = 1` (강제)로 다시 돌리면 StarRocks 도 조인 아래로 내린다 →
**게이트는 열려 있고 임계값이 막은 것**이다.

### 내려간 집계의 모양이 다르다

B 의 StarRocks 플랜:

```
6:HASH JOIN
|----5:AGGREGATE (merge finalize)      <- 2단계 집계의 뒷단
|    4:EXCHANGE (HASH_PARTITIONED: l_suppkey)   <- 셔플이 추가로 생김
3:AGGREGATE (update serialize) STREAMING
2:IcebergScanNode (lineitem)
```

Trino 는 같은 자리에 `Aggregate[type = PARTIAL]` **하나만** 넣고 교환 노드를 추가하지 않는다.

### 판정

**설계 차이 확인, 우열 미판정.** 실행 시간을 재지 않았으므로 어느 임계값이 옳은지는 이 랩에서 말할 수 없다.
다만 **"같은 통계를 갖고도 결론이 갈린다"** 는 사실과 그 원인(임계값)은 확정됐다.

---

## probe 7 — LIMIT / TopN

### 판별 쿼리

```sql
SELECT * FROM lineitem LIMIT 10;
SELECT l_orderkey FROM lineitem ORDER BY l_shipdate LIMIT 10;
SELECT l_orderkey, o_orderdate FROM lineitem LEFT JOIN orders ON l_orderkey=o_orderkey LIMIT 10;
```

### 결과

| 쿼리 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 단순 LIMIT | `TableScan[... LIMIT 10]` + `LimitPartial` | `IcebergScanNode ... limit: 10` |
| ORDER BY + LIMIT | `TopNPartial` 3단, 스캔에는 limit 없음 | `1:TOP-N limit: 10`, 스캔에는 limit 없음 |
| LEFT JOIN + LIMIT | 보존측(lineitem) 스캔에만 `LIMIT 10` | 보존측(lineitem) 스캔에만 `limit: 10`, `cardinality=10` |

세 번째 쿼리에서 양쪽 다 `LEFT JOIN` 을 `RIGHT OUTER JOIN` 으로 뒤집고 limit 을 보존측에만 내렸다.

### 판정

**동등.**

---

## 정리

| probe | 판정 |
|---|---|
| 1 스캔 술어 협상 | 설계 차이 (Trino 만 술어를 제거) |
| 2 받을 수 없는 술어 | 결과 동등, 결정 주체 다름 |
| 3 전이 추론 | 동등 |
| 4 outer→inner | 동등 |
| 5 집계 아래 술어 | 동등 |
| 6 조인 아래 집계 | **결론이 갈림 — 임계값 차이** |
| 7 LIMIT/TopN | 동등 |

### 이 probe 로 판별하지 못한 것

- **실행 시간** — 전 항목 미측정. `perf` 프로파일 필요 (`plan/02` 6-2절)
- **다중 노드** — worker/BE 1대. 조인 아래 집계는 셔플 비용과 함께 판단되므로 노드 수에 반응할 수 있다
- **JDBC/MySQL 외부 소스로의 술어 푸시다운** — 현재 랩에 JDBC 카탈로그가 없어 `PushDownPredicateToExternalTableScanRule` 경로를 실측하지 못했다
- **StarRocks 네이티브 테이블** — 전부 Iceberg 외부 테이블로만 쟀다. OLAP 스캔의 prefix index / bitmap 경로는 다를 수 있다
