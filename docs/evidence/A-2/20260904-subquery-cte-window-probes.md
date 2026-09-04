# A-2 서브쿼리 · CTE · 윈도우 — 판별 probe 5군

> 대상 문서: `docs/A-2-05-서브쿼리와-CTE.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64 (8 CPU / 16GB), hive=4, 캐시=기본값, 양쪽 통계 수집 완료.
판별은 `EXPLAIN` 플랜 모양과 **성공/실패 여부**로 한다. 실행 시간은 재지 않았다.

---

## A. 상관 서브쿼리 지원 매트릭스

### 주장

두 엔진 모두 상관 서브쿼리를 **디코릴레이션(join 으로 재작성)** 으로만 처리하고,
재작성에 실패하면 **쿼리를 거부**한다. 따라서 "어떤 모양을 재작성할 수 있는가"가 곧 기능 범위다.

### 판별 쿼리 15종

| # | 모양 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|---|
| q01 | 상관 스칼라(집계), SELECT 절 | ✅ | ✅ |
| q02 | 상관 스칼라(집계), WHERE 절 | ✅ | ✅ |
| q03 | 상관 EXISTS | ✅ | ✅ |
| q04 | 상관 NOT EXISTS | ✅ | ✅ |
| q05 | 상관 IN | ✅ | ✅ |
| q06 | 상관 NOT IN | ✅ | ✅ |
| q07 | 비상관 IN | ✅ | ✅ |
| q08 | 비상관 스칼라 | ✅ | ✅ |
| q09 | 상관 스칼라 **비집계**(행 1개 보장 없음) | ✅ (계획됨) | ✅ (계획됨) |
| q10 | 상관 서브쿼리 + `LIMIT 1` | ❌ | ❌ |
| q11 | 상관 서브쿼리 + `ORDER BY … LIMIT 1` | ✅ | ❌ |
| q12 | 상관 EXISTS 안에 집계 + `HAVING` | ❌ | ✅ |
| q13 | 상관 스칼라 두 겹 중첩 | ✅ | ✅ |
| q14 | 상관 스칼라가 `OR` 의 한 항 | ✅ | ✅ |
| q15 | 윈도우 `row_number() <= 3` 필터 | ✅ | ✅ |

거부 메시지

```
Trino      : Given correlated subquery is not supported
StarRocks  : Not support the subquery!
```

### 갈린 3건의 쿼리

```sql
-- q10  둘 다 실패
SELECT count(*) FROM orders
WHERE o_totalprice > (SELECT l_extendedprice FROM lineitem WHERE l_orderkey=o_orderkey LIMIT 1);

-- q11  Trino ✅ / StarRocks ❌
SELECT count(*) FROM orders
WHERE o_totalprice > (SELECT l_extendedprice FROM lineitem WHERE l_orderkey=o_orderkey
                      ORDER BY l_linenumber LIMIT 1);

-- q12  Trino ❌ / StarRocks ✅
SELECT count(*) FROM orders
WHERE EXISTS (SELECT max(l_quantity) FROM lineitem WHERE l_orderkey=o_orderkey
              HAVING max(l_quantity) > 40);
```

q11 의 Trino 플랜은 `TopNRanking[partitionBy = [l_orderkey], orderBy = [l_linenumber ASC], limit = 1]` +
`InnerJoin` 이다 — **`ORDER BY … LIMIT n` 을 순위 윈도우로 바꿔서** 상관을 제거했다.
`LIMIT` 만 있는 q10 에는 정렬 기준이 없어 이 경로를 못 쓴다(양쪽 다 실패).

q12 의 StarRocks 플랜은 `RIGHT SEMI JOIN` 이고, 실행하면 8282 를 돌려준다.

### 판정

**양쪽 다 완전하지 않고, 못 하는 모양이 서로 다르다.** 15종 중 12종 동일, 1종 공통 실패, 2종이 정반대.
우열 없음.

---

## B. 의미론 정합성

### 주장

디코릴레이션 방식이 달라도 SQL 의미는 같아야 한다. 특히 두 곳이 위험하다 —
**스칼라 서브쿼리가 여러 행을 낼 때**, **상관 집계의 대응 행이 없을 때**.

### 판별 쿼리와 결과

```sql
-- B-1: 스칼라 서브쿼리가 여러 행 (lineitem 은 orderkey 당 최대 7행)
SELECT count(*) FROM orders WHERE o_totalprice > (SELECT l_extendedprice FROM lineitem WHERE l_orderkey=o_orderkey);
```

| 엔진 | 결과 |
|---|---|
| Trino 483 | `Scalar sub-query has returned multiple rows` (실행 중 오류) |
| StarRocks 4.0.14 | `correlate scalar subquery result must 1 row: BE:10001` (실행 중 오류) |

둘 다 **계획은 성공하고 실행 중에 거부**한다. Trino 는 코디네이터, StarRocks 는 BE 에서 난다.

```sql
-- B-2: 대응 행이 하나도 없는 상관 count (정답 = orders 전체 15000)
SELECT count(*) FROM orders
WHERE (SELECT count(*) FROM lineitem WHERE l_orderkey=o_orderkey AND l_quantity > 100) = 0;
```

| 엔진 | 결과 |
|---|---|
| Trino 483 | 15000 |
| StarRocks 4.0.14 | 15000 |

```sql
-- B-3: 자기 자신과의 상관 집계 비교
SELECT count(*) FROM lineitem l
WHERE l.l_extendedprice > (SELECT avg(l2.l_extendedprice) FROM lineitem l2 WHERE l2.l_orderkey = l.l_orderkey);
```

| 엔진 | 결과 | 스캔 수 |
|---|---|---|
| Trino 483 | 27987 | 2 |
| StarRocks 4.0.14 | 27987 | 2 |

### 판정

**동등.** 세 경우 모두 결과가 일치한다.

---

## C. 디코릴레이션 결과 플랜의 모양

### 주장

같은 쿼리를 같은 의미로 재작성해도 **사용하는 조인 연산자가 다르다.**

### 결과

| 쿼리 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| q04 상관 NOT EXISTS | `LeftJoin` + 서브쿼리측 `Aggregate(group by 상관키)` | **`LEFT ANTI JOIN`** |
| q06 상관 NOT IN | `LeftJoin[filter = ((o_orderkey IS NULL) OR (o_orderkey = l_orderkey) OR (l_orderkey IS NULL)) AND …]` | **`NULL AWARE LEFT ANTI JOIN`** |
| q03 상관 EXISTS | `InnerJoin` + 서브쿼리측 `Aggregate(group by 상관키)` | **`LEFT SEMI JOIN`** |
| B-3 자기상관 집계 | `CrossJoin` 위 `LeftJoin`, `COALESCE(avg, avg_20)` — `avg_20` 은 `Aggregate[] over Values[]`(빈 입력의 집계 기본값) | 단일 `INNER JOIN` + `other join predicates` |

Trino 는 **anti join / semi join 전용 연산자를 쓰지 않고** outer join + 필터 조합으로 표현한다.
B-3 에서 보이는 `Aggregate[] over Values[]` 는 "대응 행이 없을 때 집계가 무엇을 반환하는가"를
플랜에 명시적으로 넣은 것이다(`count` → 0 을 맞추려면 필요하다).

### 판정

**의미는 같고 표현이 다르다.** 우열 미판정 — 실행 시간을 재지 않았다.

---

## D. CTE 재사용

### 주장

StarRocks 는 CTE 를 플랜 오퍼레이터로 남기고 **한 번 계산해 여러 소비자에게 뿌릴 수 있다.**
Trino 는 `WITH` 를 참조마다 다시 계획한다.

### 판별 쿼리

```sql
WITH t AS (SELECT l_orderkey, sum(l_extendedprice) s FROM lineitem GROUP BY l_orderkey)
SELECT count(*) FROM t a JOIN t b ON a.l_orderkey = b.l_orderkey WHERE a.s > b.s;
```

### 결과

| 엔진 / 설정 | lineitem 스캔 수 | 특징 |
|---|---|---|
| Trino 483 | **2** | 두 참조가 각각 스캔 + 집계 |
| StarRocks 4.0.14 (기본, `cbo_cte_reuse_rate=1.15`) | **2** | 비용 모델이 인라인을 선택 |
| StarRocks 4.0.14 (`SET cbo_cte_reuse_rate = 0` → 강제 재사용) | **1** | **`MultiCastDataSinks`** 로 한 번 계산해 두 소비자에게 분배 |

참조 3회짜리 CTE 로 바꿔도 StarRocks 기본 설정은 여전히 인라인(스캔 3회)을 골랐다.

### 판정

**StarRocks 만 가능한 기능.** 다만 **SF 0.01 에서는 비용 모델이 한 번도 재사용을 고르지 않았다** —
데이터가 작아 재계산이 항상 싸다. 강제했을 때만 확인된다.
Trino 에는 CTE 구체화 관련 세션 속성이 아예 없다(재귀 CTE 깊이 제한만 존재).

---

## E. 윈도우 함수 최적화

### E-1. 순위 필터 (`row_number() <= 3`)

```sql
SELECT count(*) FROM (
  SELECT l_orderkey, row_number() OVER (PARTITION BY l_orderkey ORDER BY l_extendedprice DESC) rn
  FROM lineitem) t
WHERE rn <= 3;
```

| 엔진 | 플랜 |
|---|---|
| Trino 483 | `TopNRanking[partitionBy, orderBy, limit=3]` — **윈도우 연산자가 사라짐** |
| StarRocks 4.0.14 | `PARTITION-TOP-N(limit 3)` → 셔플 → `SORT` → `ANALYTIC` → `SELECT predicates: row_number() <= 3` |

둘 다 셔플 전에 파티션별로 미리 잘라낸다. 차이는 **StarRocks 가 그 뒤에도 정렬과 윈도우 계산을 그대로 수행**한다는 점이다.

### E-2. 윈도우 + 바깥 `LIMIT` (정렬 없음)

```sql
SELECT l_orderkey, row_number() OVER (ORDER BY l_extendedprice DESC) r FROM lineitem LIMIT 5;
```

| 엔진 | 플랜 |
|---|---|
| Trino 483 | `TopNRanking[orderBy, limit=5]` — 전역 정렬 없음 |
| StarRocks 4.0.14 | `SORT`(60175행 전량, limit 없음) → `ANALYTIC limit: 5` |

### E-3. 윈도우 + `ORDER BY 순위컬럼 LIMIT` — **E-2 와 반대로 뒤집힌다**

```sql
SELECT * FROM (
  SELECT l_orderkey, l_extendedprice, row_number() OVER (ORDER BY l_extendedprice DESC) rk
  FROM lineitem) t
ORDER BY rk LIMIT 5;
```

| 엔진 | 플랜 |
|---|---|
| Trino 483 | `TopN(5)` → `Window`(전량) → `TableScan` — **윈도우 아래로 못 내림** |
| StarRocks 4.0.14 | `TOP-N(5)` → `ANALYTIC` → **`TOP-N(5)`** → `IcebergScanNode` — 윈도우 아래에 삽입 |

StarRocks 의 `PushDownLimitRankingWindowRule` 은 클래스 주석이 밝히듯 **`ORDER BY rk LIMIT n` 모양**을 노린다.
E-2 의 맨 `LIMIT` 모양은 대상이 아니다. Trino 는 정확히 반대다.

### E-4. 인접 윈도우 병합

```sql
SELECT count(*) FROM (
  SELECT row_number() OVER (PARTITION BY l_orderkey ORDER BY l_extendedprice) r,
         rank()       OVER (PARTITION BY l_orderkey ORDER BY l_extendedprice) k
  FROM lineitem) t
WHERE r+k < 5;
```

| 엔진 | 윈도우 연산자 수 |
|---|---|
| Trino 483 | **1** (`Window[partitionBy=[l_orderkey], orderBy=[l_extendedprice ASC]]` 하나에 두 함수) |
| StarRocks 4.0.14 | **2** (`3:ANALYTIC row_number()` + `4:ANALYTIC rank()`, 정렬은 `2:SORT` 하나 공유) |

### 판정

**E-1 동등(구조는 Trino 가 단순), E-2 Trino 우위, E-3 StarRocks 우위, E-4 Trino 우위.**
실행 시간 미측정이므로 "플랜 구조상 유리"까지만 말한다.

---

## 정리

| probe | 판정 |
|---|---|
| A 상관 서브쿼리 15종 | 12 동일 / 1 공통 실패 / **2 정반대** |
| B 의미론 정합성 | 동등 |
| C 디코릴레이션 플랜 모양 | 의미 동일, 표현 다름(StarRocks 는 anti/semi 전용 연산자) |
| D CTE 재사용 | **StarRocks 만 가능** — 단 기본 비용 모델은 SF0.01 에서 한 번도 선택 안 함 |
| E 윈도우 4종 | E-2/E-4 Trino 우위, E-3 StarRocks 우위, E-1 동등 |

### 이 probe 로 판별하지 못한 것

- **실행 시간** — 전 항목 미측정. `perf` 프로파일 필요 (`plan/02` 6-2절)
- **CTE 재사용의 비용 모델 판단** — SF 0.01 에서는 항상 인라인이 이긴다. 재사용이 자동으로 선택되는 규모를 확인하려면 더 큰 데이터가 필요하다
- **다중 노드** — `MultiCastDataSinks` 의 실제 이득은 셔플 비용에 달렸는데 BE 1대에서는 셔플 비용이 0으로 계산된다(A-2-03 5-1)
- **StarRocks `ScalarApply2AnalyticRule`(상관 스칼라 → 윈도우 재작성)** — 소스에는 있으나 B-3 을 포함해 시도한 어떤 쿼리에서도 발동시키지 못했다. 발동 조건 미확인
- **재귀 CTE** — 양쪽 지원 범위를 확인하지 않았다
