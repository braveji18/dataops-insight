# A-2 MV 쿼리 재작성 — 판별 probe 6종

> 대상 문서: `docs/A-2-06-MV-쿼리-재작성.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64 (8 CPU / 16GB), hive=4, 캐시=기본값, 세션 변수 전부 기본값.
판별은 `EXPLAIN` 플랜의 **스캔 대상 테이블**로 한다. 실행 시간은 재지 않았다.

**probe 종료 후 생성한 객체는 전부 삭제했다** — `mvlab` 데이터베이스, MV 4개, `iceberg.bench.mvsrc` 테이블.

### 양쪽에 만든 MV (정의 동일)

```sql
-- StarRocks (default_catalog.mvlab)
CREATE MATERIALIZED VIEW mv_order_sum
DISTRIBUTED BY HASH(l_orderkey) BUCKETS 3
REFRESH ASYNC EVERY(INTERVAL 1 DAY)
PROPERTIES ("replication_num" = "1")
AS SELECT l_orderkey, sum(l_extendedprice) AS s, count(*) AS c
   FROM iceberg.bench.lineitem GROUP BY l_orderkey;

-- Trino (iceberg.bench)
CREATE MATERIALIZED VIEW iceberg.bench.mv_order_sum AS
SELECT l_orderkey, sum(l_extendedprice) AS s, count(*) AS c
FROM iceberg.bench.lineitem GROUP BY l_orderkey;
```

둘 다 갱신 후 15000행. StarRocks MV 는 `IS_ACTIVE = true`, Trino MV 는 `freshness = FRESH`.

> **주의**: StarRocks 는 외부 테이블 대상 ASYNC MV 에 갱신 주기를 요구한다 —
> 주기 없이 `REFRESH ASYNC` 만 쓰면 `Materialized view which type is ASYNC need to specify refresh interval for external table` 로 거부된다.

---

## probe 1 — MV 이름을 쓰지 않은 쿼리가 MV 로 재작성되는가

### 주장

StarRocks 는 **원본 테이블을 대상으로 쓴 쿼리**를 MV 로 바꾼다. Trino 는 바꾸지 않는다.

### 판별 쿼리

```sql
SELECT l_orderkey, sum(l_extendedprice) FROM iceberg.bench.lineitem GROUP BY l_orderkey;
```

### 결과

| 엔진 | 스캔 대상 |
|---|---|
| Trino 483 | `TableScan[table = iceberg:bench.lineitem$data@…]` — **원본** |
| StarRocks 4.0.14 | `0:OlapScanNode  TABLE: mv_order_sum` — **MV** |

### 판정

**StarRocks 만 지원.** Trino 에는 이 기능이 없다.

---

## probe 2 — 재작성의 폭 (StarRocks)

### 주장

정확히 같은 쿼리만 바뀌는 게 아니라, **MV 를 부분적으로 활용하는 쿼리**도 바뀐다.

### 판별 쿼리와 결과

| # | 쿼리 | MV 활용에 필요한 것 | 결과 |
|---|---|---|---|
| P1 | `SELECT l_orderkey, sum(l_extendedprice) … GROUP BY l_orderkey` | 정확 일치 | `OlapScanNode TABLE: mv_order_sum` |
| P2 | `SELECT sum(l_extendedprice) … WHERE l_orderkey < 100` | 술어를 MV 스캔에 밀어넣기 + `sum(s)` 롤업 | `OlapScanNode TABLE: mv_order_sum`, `PREDICATES: l_orderkey < 100` |
| P3 | `SELECT count(*) FROM lineitem` | `count(*)` → `sum(c)` 롤업 | `OlapScanNode TABLE: mv_order_sum` |
| P4 | `SELECT o_orderstatus, sum(l_extendedprice) FROM lineitem JOIN orders … GROUP BY o_orderstatus` | **조인의 한쪽 가지만 MV 로 치환** | `OlapScanNode TABLE: mv_order_sum` ⋈ `IcebergScanNode TABLE: bench.orders` |

P4 의 플랜:

```
5:HASH JOIN  (INNER JOIN, BUCKET_SHUFFLE)
├─ 0:OlapScanNode    TABLE: mv_order_sum      ← MV 로 치환된 lineitem 가지
└─ 3:IcebergScanNode TABLE: bench.orders
```

### 판정

**단일 테이블 집계뿐 아니라 조인 쿼리의 부분 치환까지 동작한다.**

---

## probe 3 — 재작성 스위치 판별

### 판별 쿼리

```sql
SET enable_materialized_view_rewrite = false;
EXPLAIN SELECT l_orderkey, sum(l_extendedprice) FROM iceberg.bench.lineitem GROUP BY l_orderkey;
```

### 결과

| 설정 | 스캔 대상 |
|---|---|
| 기본(`true`) | `OlapScanNode TABLE: mv_order_sum` |
| `false` | `IcebergScanNode TABLE: bench.lineitem` |

### 판정

**probe 1·2의 변화가 MV 재작성 때문임을 확정.** 다른 요인이 아니다.

---

## probe 4 — 재작성 결과의 정합성

### 판별 쿼리

probe 2의 P4 (조인 부분 치환)를 실제로 실행해 세 경우를 비교한다.

```sql
SELECT o_orderstatus, round(sum(l_extendedprice),2) s
FROM iceberg.bench.lineitem JOIN iceberg.bench.orders ON l_orderkey=o_orderkey
GROUP BY o_orderstatus ORDER BY 1;
```

### 결과

| 조건 | F | O | P |
|---|---|---|---|
| StarRocks 재작성 ON | 1047671851.23 | 1040494583.94 | 64023325.3 |
| StarRocks 재작성 OFF | 1047671851.23 | 1040494583.94 | 64023325.3 |
| Trino (대조군) | 1047671851.23 | 1040494583.94 | 64023325.3 |

### 판정

**동일.** 재작성이 결과를 바꾸지 않는다.

---

## probe 5 — Trino 의 MV 접근 경로와 신선도 처리

### 주장

Trino 의 MV 는 **이름으로 질의할 때만** 동작하고, 신선하면 스토리지 테이블을, 아니면 정의를 펼친다.

### 판별 절차

작은 원본 테이블(`iceberg.bench.mvsrc`, 1004행)을 만들고 그 위에 MV 를 두 개 만든다 —
하나는 `GRACE PERIOD` 를 지정하지 않고, 하나는 `GRACE PERIOD INTERVAL '0' SECOND` 로.
갱신한 뒤 원본에 1행씩 넣고 플랜을 다시 본다.

### 결과

| 상황 | 플랜 |
|---|---|
| MV 이름으로 질의, 신선 | `TableScan[table = iceberg:bench.mv_stale$materialized_view_storage$data@…]` |
| 원본 테이블로 질의(MV 이름 언급 없음) | `TableScan[iceberg:bench.lineitem…]` — **재작성 없음** |
| 원본 변경 후, **GRACE PERIOD 미지정** | `TableScan[…$materialized_view_storage$data@…]` — **여전히 MV 스토리지를 읽는다** |
| 원본 변경 후, **`GRACE PERIOD INTERVAL '0' SECOND`** | `Aggregate` → `TableScan[iceberg:bench.mvsrc$data@…]` — **정의를 펼쳐 원본을 읽는다** |

`system.metadata.materialized_views` 의 `freshness` 는 세 번째 경우에도 `STALE` 로 보고된다.
**그런데도 스토리지 테이블을 읽는다** — `GRACE PERIOD` 를 지정하지 않으면 무제한으로 취급되기 때문이다.

### 판정

**Trino 의 기본값은 "갱신할 때까지 오래된 데이터를 계속 제공"이다.** 이것을 원하지 않으면
`GRACE PERIOD` 를 명시해야 한다. 신선도 표시(`STALE`)와 실제 동작이 다르다는 점은 운영에서 오해를 부를 수 있다.

---

## probe 6 — StarRocks 의 신선도 처리

### 판별 절차

StarRocks MV(`mv_src_sum`)를 `iceberg.bench.mvsrc` 위에 만들고 갱신한 뒤,
**Trino 로** 원본에 1행을 넣고 StarRocks 플랜을 다시 본다.

### 결과

| 단계 | StarRocks 가 보는 원본 행 수 | 플랜 | 결과 |
|---|---|---|---|
| 갱신 직후 | 1006 | `OlapScanNode TABLE: mv_src_sum` | 정답 |
| 원본 +1행 직후 | **1006** (외부 카탈로그 메타데이터 캐시가 아직 옛 스냅샷) | `OlapScanNode TABLE: mv_src_sum` | 옛 값 |
| `REFRESH EXTERNAL TABLE iceberg.bench.mvsrc` 후 | 1007 | **`IcebergScanNode TABLE: bench.mvsrc`** | 정답 (258행 / 35697290.12, Trino 와 일치) |

### 판정

**StarRocks 는 MV 가 낡았다고 판단하면 재작성을 포기하고 원본을 읽는다.**
투명한 재작성은 결과를 바꾸면 안 되므로 당연한 선택이다.

**단, 중간 단계가 중요하다.** StarRocks 가 옛 값을 준 것은 MV 때문이 아니라 **외부 카탈로그 메타데이터 캐시** 때문이었다.
같은 쿼리를 재작성 없이 돌려도 같은 옛 값이 나온다. 이 두 가지를 섞어서 해석하면 안 된다.

---

## 정리

| probe | 판정 |
|---|---|
| 1 이름 없는 쿼리의 재작성 | **StarRocks 만 지원** |
| 2 재작성의 폭 | 롤업 · 술어 밀어넣기 · 조인 부분 치환까지 동작 |
| 3 스위치 판별 | 원인 확정 |
| 4 결과 정합성 | 동일 |
| 5 Trino 신선도 | 이름 질의 전용. **기본값은 무제한 grace — 낡아도 계속 제공** |
| 6 StarRocks 신선도 | 낡으면 재작성 포기, 원본 fallback |

### 이 probe 로 판별하지 못한 것

- **실행 시간과 이득 크기** — SF 0.01 이라 MV 를 읽는 이득을 측정할 수 없다(`perf` 프로파일 필요, `plan/02` 6-2절)
- **부분 갱신(UNION) 재작성** — StarRocks 소스에는 `compensation/` 패키지(7개 클래스)로 파티션 단위 보정이 있으나, 이 랩의 Iceberg 테이블은 파티션이 없어 경로를 타지 못했다. `enable_materialized_view_union_rewrite` 기본 `true`
- **중첩 MV** — `nested_mv_rewrite_max_level` 기본 3. 시험하지 않았다
- **StarRocks 네이티브 테이블 위의 MV** — 전부 Iceberg 외부 테이블 대상으로만 쟀다. 동기(SYNC) MV, 증분 갱신은 네이티브 테이블 전용이다
- **뷰 기반 재작성 / 텍스트 매칭 재작성** — `enable_view_based_mv_rewrite`, `TextMatchBasedRewriteRule` 경로는 시험하지 않았다
- **재작성 실패 시의 진단** — StarRocks 는 `MVRewriteValidator` 로 추적 정보를 남기지만 확인하지 않았다
