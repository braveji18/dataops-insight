# 비용 모델 판별 3종 — 셔플 네트워크 비용 0, 다중 절 상관 가정, 통계 가용성

> 비교 축: A-2 옵티마이저 / 비용 모델 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-2-03-비용-모델.md`
> **이 실험은 앞선 증거 `20260831-join-reorder-algorithm-threshold.md` 의 원인 귀속을 정정한다** (probe 3)
> 일자: 2026-09-03

---

## probe 1 — StarRocks는 BE 1대에서 셔플의 네트워크 비용을 0으로 계산한다

### 주장

`docs/A-2-02` 4-1에서 `lineitem ⋈ orders` 에 Trino는 REPLICATED, StarRocks는 PARTITIONED를 골랐다. 원인은 게이트가 아니라 비용 모델인데, 구체적으로는 **`CostModel.java:418-429` 의 `ignoreNetworkCost` 경로**다. `enable_local_shuffle_agg` && `enable_pipeline_engine` && BE+CN 합이 1 — 세 조건이 모두 참이면 SHUFFLE 교환의 네트워크 비용이 0이 된다. 이 랩은 BE 1대라 세 조건이 모두 참이다.

### 판별 쿼리

세션 변수 하나로 조건 중 하나를 깬다. 이것만으로 분배 방식이 뒤집히면 원인이 확정된다.

```sql
-- 판별 대상
SELECT count(*) FROM lineitem l, orders o WHERE l.l_orderkey = o.o_orderkey
-- 대조군 (빌드측이 아주 작아 비용이 팽팽하지 않다 → 바뀌면 안 된다)
SELECT count(*) FROM lineitem l, supplier s WHERE l.l_suppkey = s.s_suppkey
```

```sql
SET enable_local_shuffle_agg = false;
```

### 결과

| 쿼리 | StarRocks 기본 | `enable_local_shuffle_agg=false` |
|---|---|---|
| `lineitem ⋈ orders` (빌드 15000행) | **PARTITIONED** | **BROADCAST** ← 뒤집힘 |
| `lineitem ⋈ supplier` (빌드 100행, 대조군) | BROADCAST | BROADCAST (변화 없음) |

세션 변수 하나로 뒤집혔고, 대조군은 움직이지 않았다. 즉 이 변수가 무차별적으로 broadcast를 만드는 것이 아니라 **비용이 팽팽한 경우에만 결론을 바꾼다.**

### 판정

**주장 확정.** A-2-02 4-1에서 두 엔진의 결론이 갈린 원인은 **단일 BE 구성에서 StarRocks가 셔플의 네트워크 비용을 0으로 계산하기 때문**이다. Trino는 같은 조건에서 태스크 수가 1이라 복제 배수가 1이 되고, 셔플은 프로브측까지 재분배 비용을 물어 복제가 싸게 나온다.

**한정** — 이것은 **랩 구성이 만든 결과이지 StarRocks의 일반적 성향이 아니다.** BE가 2대 이상이면 `isSingleBackendAndComputeNode()` 가 거짓이 되어 이 경로를 타지 않는다. 다중 BE 재현은 이 랩으로 불가.

---

## probe 2 — 다중 등가절의 상관 가정이 조인 순서까지 바꾼다

### 주장

`docs/A-2-03` 2-6 / 3-7: 두 엔진 모두 조인 등가절이 여러 개일 때 선택도를 감쇠시키는데, 감쇠 방식과 기본값이 다르다. Trino는 `join_multi_clause_independence_factor`(기본 0.25)로 지수 감쇠, StarRocks는 driving predicate + `0.9^(n-1)`(기본) 또는 ORCA식 sqrt 감쇠(대안).

### 판별 쿼리

TPC-H Q5 형태(6테이블). 최상위 조인이 등가절 **2개**(`l_orderkey=o_orderkey`, `s_nationkey=c_nationkey`)를 갖는다.

```sql
SELECT n.n_name, sum(l.l_extendedprice*(1-l.l_discount)) AS revenue
FROM customer c, orders o, lineitem l, supplier s, nation n, region r
WHERE c.c_custkey=o.o_custkey AND l.l_orderkey=o.o_orderkey
  AND l.l_suppkey=s.s_suppkey AND c.c_nationkey=s.s_nationkey
  AND s.s_nationkey=n.n_nationkey AND n.n_regionkey=r.r_regionkey
  AND r.r_name='ASIA'
GROUP BY n.n_name
```

이 조건에서 **두 엔진의 조인 트리가 동일하게 나왔다** — `(lineitem ⋈ (supplier ⋈ (nation ⋈ region))) ⋈ (orders ⋈ customer)`. 트리가 같으므로 **노드별 추정값을 직접 대조할 수 있다.**

최상위 조인의 실제 행 수는 `count(*)` 로 따로 측정했다: **647**.

### 결과

**노드별 추정 — 최상위 조인 하나만 갈린다**

| 조인 노드 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| nation ⋈ region (ASIA) | 5 | 5 |
| supplier ⋈ (…) | 20 | 20 |
| lineitem ⋈ (…) | 12035 | 12035 |
| orders ⋈ customer | 15000 | 15111 |
| **최상위 (등가절 2개)** | **5448** | **10896** |

중간 노드는 전부 일치하고 **등가절이 2개인 최상위 조인에서만 정확히 2배 벌어진다.** 원인이 통계나 스캔 추정이 아니라 **다중 절 처리**임이 확정된다.

**손잡이를 돌린 결과 (실제 = 647)**

| 엔진 / 설정 | 추정 | 실제 대비 |
|---|---|---|
| Trino `factor=0` (완전 상관) | 12182 | 18.8× |
| StarRocks 기본 (`cbo_use_correlated_join_estimate=true`) | 10896 | 16.8× |
| **Trino 기본 (`factor=0.25`)** | **5448** | 8.4× |
| Trino `factor=0.5` | 2436 | 3.8× |
| StarRocks `cbo_use_correlated_join_estimate=false` (ORCA식) | 484 | 0.75× |
| **Trino `factor=1` (완전 독립)** | **609** | **0.94×** |

**추정을 바꾸면 조인 순서도 바뀐다.** Trino `factor=1` 에서는 최상위 조인의 등가절 조합 자체가 달라졌고(`l_orderkey=o_orderkey AND l_suppkey=s_suppkey`), StarRocks `correlated=false` 에서는 트리가 right-deep(`lineitem ⋈ (orders ⋈ (customer ⋈ (supplier ⋈ (nation ⋈ region))))`)으로 바뀌었다.

### 판정

**동등하지 않다 — 기본값의 상관 가정 강도가 다르고, 둘 다 이 쿼리에서는 크게 빗나간다.**

- Q5의 두 등가절(`l_orderkey=o_orderkey`, `s_nationkey=c_nationkey`)은 **실제로 독립적**이다. 그래서 완전 독립 가정이 정답에 가깝다
- 양쪽 기본값은 모두 강한 상관을 가정해 **한 자릿수~두 자릿수 배로 과대추정**한다. StarRocks 기본이 가장 멀고(16.8×), Trino 기본이 2배 가깝다(8.4×)
- **어느 쪽 기본값이 낫다고 일반화할 수 없다.** FK 체인처럼 등가절이 실제로 상관된 스키마에서는 반대가 된다. 여기서 확인된 것은 *기본값의 방향과 그 결과의 크기*이지 우열이 아니다
- 조절 가능성은 다르다. Trino는 `join_multi_clause_independence_factor` 가 **연속값 세션 프로퍼티**이고, StarRocks는 두 알고리즘 중 택일하는 **INVISIBLE 불리언**이다

---

## probe 3 — ★ 정정: 조인 트리 모양을 가른 것은 임계값이 아니라 통계 가용성이었다

### 주장 (검증 대상)

`docs/evidence/A-2/20260831-join-reorder-algorithm-threshold.md` 는 같은 Q5 쿼리에서 **StarRocks 기본이 left-deep**, `cbo_max_reorder_node_use_exhaustive=10` 으로 올리면 bushy 라고 기록했고, 원인을 **임계값 디스패치**로 귀속했다.

### 판별

**같은 랩, 같은 쿼리, 기본 설정에서 StarRocks가 bushy 플랜을 냈다** — 앞선 기록과 다르다. 그래서 두 변수(통계 가용성 × 임계값)를 교차시켰다.

`ReorderJoinRule.java:250-253` 은 통계가 없는 컬럼이 하나라도 있으면 DP·greedy를 건너뛰고 left-deep만 후보로 남긴다(A-2-01 3-3). 이것을 직접 만든다:

```sql
DROP STATS iceberg.bench.nation;      -- 이후 ANALYZE TABLE 로 복구
```

### 결과

| 통계 상태 | 임계값 4 (기본) | 임계값 10 |
|---|---|---|
| **FULL (전 컬럼)** | **bushy** `(lineitem ⋈ (supplier ⋈ (nation ⋈ region))) ⋈ (orders ⋈ customer)` | bushy (같은 트리, 최상위 build/probe만 교체) |
| **nation 통계 없음** | **left-deep** `((((lineitem ⋈ orders) ⋈ customer) ⋈ supplier) ⋈ nation) ⋈ region` | bushy |

**통계를 지우자 8월 31일 기록과 정확히 같은 left-deep 트리가 재현됐고, 복구하자 bushy로 돌아왔다.**

### 판정

**앞선 증거의 관찰은 사실이지만 원인 귀속이 틀렸다.**

- 8월 31일 실행 당시 StarRocks 쪽 컬럼 통계가 완전하지 않았다. 그래서 DP·greedy가 비활성화되고 left-deep만 남았다
- 임계값을 10으로 올렸을 때 bushy가 나온 것도 같은 이유로 설명된다 — 임계값을 넘기면 **memo 전수 탐색 경로**로 가고, 그 경로는 `hasUnknownColumnsStats` 를 보지 않는다
- 즉 **임계값이 경로를 가르는 것은 맞지만**(소스 근거는 유효하다), 관찰된 left-deep은 임계값 때문이 아니라 **통계 때문**이었다
- **통계가 완전하면 기본 임계값(4)에서도 StarRocks는 bushy 플랜을 만든다.** `JoinReorderDP` 가 후보에 들어가고 비용이 그것을 고르기 때문이다(`ReorderJoinRule.java:247-268`)

따라서 `docs/A-2-01` 5절 표의 "**트리 모양: 휴리스틱 경로에서는 사실상 left-deep 편향**" 은 **틀렸다.** 편향은 알고리즘 디스패치가 아니라 통계 가용성에서 온다.

**한정** — 8월 31일 실행의 통계 상태를 직접 확인한 것은 아니다(그 상태는 남아 있지 않다). 확정된 것은 "통계를 지우면 그 트리가 정확히 재현되고, 통계가 완전하면 재현되지 않는다"이며, 이것이 임계값 가설보다 관찰을 잘 설명한다.

---

## 부수 관찰 — Trino의 "통계 없으면 리오더 포기"는 Iceberg에서 관찰되지 않는다

`docs/A-2-01` 3-3은 Trino가 비용을 알 수 없으면 리오더를 포기하고 작성된 순서를 유지한다고 했다. 대칭 실험을 했다.

```sql
ALTER TABLE iceberg.bench.nation EXECUTE drop_extended_stats;   -- NDV 제거
```

결과: **Trino는 리오더를 포기하지 않았다.** 플랜 모양은 바뀌었지만(nation·region이 트리 위쪽으로 밀림) 여전히 작성된 순서와 다르게 재배치했다. `ANALYZE` 로 복구하니 원래 플랜으로 정확히 되돌아왔다.

이유는 3-3의 조건이 **비용 전체가 미상**이 되는 경우인데, Iceberg는 매니페스트에 행 수가 항상 있어 `drop_extended_stats` 로 NDV만 지워도 행 수 추정이 살아 있기 때문이다. **A-2-01 3-3의 코드 경로 자체는 유효하지만, 이 커넥터에서는 도달하기 어렵다.** 도달 조건을 만들려면 행 수조차 없는 커넥터가 필요하다(A-5 소재).

---

## 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.18 WSL2, 8 CPU, RAM 7.6GB + swap 2GB), Trino worker 1대 / StarRocks BE 1대,
`bin/status.sh` exit 0 (green, 양쪽 `bench.lineitem` = 60175 일치),
명시한 세션 변수 외 기본값. 시드 시 양쪽 모두 ANALYZE 수행됨(probe 3의 삭제·복구는 실험 중 일시적).

**실행 시간은 측정하지 않았다.** SF 0.01 이고 이 호스트는 `perf` 프로파일을 돌릴 수 없다(`plan/02` 3절).
