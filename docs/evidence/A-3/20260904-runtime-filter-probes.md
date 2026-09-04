# A-3 런타임 필터 — 판별 probe 4종

> 대상 문서: `docs/A-3-04-런타임-필터.md`
> 형식: `.claude/skills/lakehouse-lab/references/protocol.md` 4절
> 일자: 2026-09-04

**공통 조건**: profile=functional, TPC-H SF0.01, Trino 483 (worker 1) / StarRocks 4.0.14 (BE 1),
host=linux/x86_64, hive=4, 세션 변수 기본값. 실행 시간은 재지 않았다.

**공통 판별 쿼리**

```sql
SELECT count(*) FROM lineitem JOIN orders ON l_orderkey = o_orderkey
WHERE o_orderdate < DATE '1993-01-01';
```

조인의 빌드측(orders)에 조건이 걸려 2,283건으로 줄어든다. 그 값 집합을 프로브측(lineitem, 60,175건) 스캔에 넘길 수 있는 전형적인 형태다.

---

## probe 1 — 기본 설정에서 양쪽 다 런타임 필터를 만드는가

### 결과

| 엔진 | 생성 여부 | 어디에 보이는가 |
|---|---|---|
| Trino 483 | ✅ | **기본 `EXPLAIN`** — `ScanFilter[lineitem, dynamicFilters = {l_orderkey = #df_343}]` |
| StarRocks 4.0.14 | ✅ | **`EXPLAIN VERBOSE` 에서만** — `build runtime filters: - filter_id = 0, build_expr = (17: o_orderkey)` |

### 판정

**양쪽 다 만든다. 관측 경로가 다르다** — StarRocks 는 기본 `EXPLAIN` 에 표시하지 않는다.

---

## probe 2 — StarRocks 는 로컬/원격 필터를 구분하는가

### 판별

같은 쿼리를 broadcast 조인(기본)과 shuffle 조인(`[shuffle]` 힌트)으로 각각 실행한다.

### 결과

| 조인 분배 | 런타임 필터 |
|---|---|
| `INNER JOIN (BROADCAST)` | `- filter_id = 0, build_expr = (17: o_orderkey), **remote = false**` |
| `INNER JOIN (PARTITIONED)` | `- filter_id = 0, build_expr = (17: o_orderkey), **remote = true**` |

### 판정

**조인 분배 방식에 따라 필터의 전파 범위가 달라진다.** broadcast 는 빌드측이 이미 모든 노드에 있으므로 로컬 필터로 충분하고, shuffle 은 다른 노드로 보내야 한다(`remote = true`).

Trino 의 `EXPLAIN` 에는 이 구분이 표시되지 않는다.

---

## probe 3 — 빌드측이 작을 때의 임계값

### 주장

StarRocks 는 빌드측이 너무 작으면 런타임 필터를 만들지 않는다(`global_runtime_filter_build_min_size` 기본 128KB).

### 판별

```sql
SET global_runtime_filter_build_min_size = 1;
SET global_runtime_filter_probe_min_size = 1;
EXPLAIN VERBOSE <같은 쿼리>;
```

### 결과

| 설정 | 런타임 필터 |
|---|---|
| 기본값 | 생성됨 |
| 최소 크기 = 1 | 생성됨 (변화 없음) |

### 판정

**이 쿼리에서는 임계값이 발화 지점이 아니다.** 빌드측 2,283건 × 12바이트 ≈ 27KB 로 기본 임계값(128KB)보다 작은데도 필터가 생성됐다.

**즉 `global_runtime_filter_build_min_size` 는 이 경로에서 적용되지 않거나, 다른 조건이 먼저 통과시킨다.** 코드 독해만으로 임계값의 적용 지점을 단정하면 안 된다는 사례다. **적용 조건은 미확인으로 남긴다.**

---

## probe 4 — 필터가 실제로 데이터를 걸렀는지

### 판별

`EXPLAIN ANALYZE` 로 스캔 단계의 출력 행 수를 본다.

### 결과

**판별 실패.**

- 데이터가 6만 건이라 필터 유무로 읽는 양이 유의미하게 달라지지 않는다
- Trino 는 스캔 출력 행 수를 보여주지만 필터 적용 전후를 나눠 세지 않는다
- StarRocks 프로파일에도 이 쿼리 규모에서는 필터 적용 카운터가 의미 있는 값을 내지 않았다

### 판정

**필터의 효과는 이 랩에서 측정할 수 없다.** 더 큰 데이터와 `perf` 프로파일이 필요하다.

---

## 정리

| probe | 판정 |
|---|---|
| 1 생성 여부 | 양쪽 다 생성. **관측 경로가 다름**(Trino 기본 EXPLAIN / SR VERBOSE) |
| 2 로컬·원격 구분 | **StarRocks 만 플랜에 표시** |
| 3 빌드측 최소 크기 임계 | **발화하지 않음 — 적용 조건 미확인** |
| 4 실제 필터 효과 | **판별 실패** (데이터 규모) |

### 이 probe 로 판별하지 못한 것

- **필터의 실제 효과** — 읽는 양이 얼마나 줄어드는지. 데이터 규모와 `perf` 프로파일 필요(`plan/02` 6-2절)
- **다중 노드에서의 원격 필터 전파** — BE/worker 1대라 `remote = true` 가 실제로 네트워크를 타지 않는다
- **StarRocks 임계값의 실제 적용 지점** — probe 3 참조
- **대기 시간(타임아웃) 동작** — 빌드가 늦을 때 프로브가 기다리는 동작(`global_runtime_filter_wait_timeout`, Trino `dynamic_filtering_wait_timeout`)은 재현할 수 없었다
- **행 단위 필터(Trino `enable_dynamic_row_filtering`)의 효과** — 별도 측정 필요
