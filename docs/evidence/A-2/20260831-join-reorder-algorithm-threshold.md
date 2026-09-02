# 조인 개수 임계값이 StarRocks의 조인 순서 탐색 알고리즘을 바꾼다

> 비교 축: A-2 옵티마이저 / 조인 순서 결정 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-2-01-조인-순서-결정.md`
> 일자: 2026-08-31

> ---
> ## ⚠ 정정됨 (2026-09-03)
>
> **아래의 관찰은 사실이지만 원인 귀속이 틀렸다.** 관찰된 left-deep 플랜은 임계값
> (`cbo_max_reorder_node_use_exhaustive`) 때문이 아니라 **StarRocks 쪽 컬럼 통계가 완전하지
> 않았기 때문**이다. 통계가 완전하면 기본 임계값에서도 StarRocks는 bushy 플랜을 만들고,
> 그 트리는 Trino와 동일했다.
>
> 재실측과 2×2 교차 판별: `docs/evidence/A-2/20260903-cost-model-probes.md` probe 3.
> 본문 반영: `docs/A-2-01-조인-순서-결정.md` 4절.
>
> 이 파일은 **기록으로 남긴다** — 지우면 무엇을 왜 고쳤는지 추적할 수 없다.
> ---

### 주장

두 엔진 모두 CBO 조인 리오더를 하지만 **탐색 전략이 다르다.** Trino는 조인 개수가 한도(`max_reordered_joins`, 기본 8) 이하이면 항상 전수 열거(DP)를 돌린다. StarRocks는 inner/cross 조인 개수가 `cbo_max_reorder_node_use_exhaustive`(기본 **4**)를 넘으면 Cascades memo의 전수 탐색을 **포기하고** 휴리스틱 알고리즘(left-deep / DP / greedy) 결과를 후보로 쓴다.

따라서 **조인 5개짜리 같은 쿼리에서 Trino는 bushy 플랜을, StarRocks는 left-deep 플랜을 만든다.**

### 판별 쿼리

TPC-H Q5 형태의 6테이블(=inner 조인 5개) 쿼리. 조인이 5개라 StarRocks의 임계값 4를 **넘고**, Trino의 한도 8은 **넘지 않는다** — 두 엔진이 서로 다른 경로를 타는 구간이다.

```sql
SELECT n.n_name, sum(l.l_extendedprice*(1-l.l_discount)) AS revenue
FROM customer c, orders o, lineitem l, supplier s, nation n, region r
WHERE c.c_custkey=o.o_custkey AND l.l_orderkey=o.o_orderkey
  AND l.l_suppkey=s.s_suppkey AND c.c_nationkey=s.s_nationkey
  AND s.s_nationkey=n.n_nationkey AND n.n_regionkey=r.r_regionkey
  AND r.r_name='ASIA'
GROUP BY n.n_name
```

판별력을 확보하기 위해 **StarRocks에서 임계값만 바꿔 같은 쿼리를 다시** 돌렸다. 임계값 하나로 플랜이 바뀌면, 원인이 통계나 카디널리티가 아니라 **알고리즘 디스패치**임이 확정된다.

```sql
SET cbo_max_reorder_node_use_exhaustive = 10;   -- 5 > 4 였던 것을 5 <= 10 으로
```

### 결과

먼저 결과값은 양쪽이 완전히 일치했다(5행, revenue 소수점까지 동일). 아래는 플랜 차이다.

| 엔진 | 조인 트리 | 형태 |
|---|---|---|
| Trino 483 | `(lineitem ⋈ (supplier ⋈ (nation ⋈ region))) ⋈ (orders ⋈ customer)` | **bushy** |
| StarRocks 4.0.14 (기본, 임계값 4) | `((((lineitem ⋈ orders) ⋈ customer) ⋈ supplier) ⋈ nation) ⋈ region` | **left-deep** |
| StarRocks 4.0.14 (임계값 10) | `(lineitem ⋈ (orders ⋈ customer)) ⋈ (supplier ⋈ (nation ⋈ region))` | **bushy** |

임계값만 4 → 10으로 올리자 StarRocks의 플랜이 left-deep에서 bushy로 바뀌었다. **주장한 디스패치가 실제 원인이다.**

임계값을 올린 StarRocks 플랜은 Trino와 동일하지는 않다 — 양쪽 다 `{nation, region, supplier}` 와 `{orders, customer}` 라는 같은 클러스터를 만들지만 lineitem을 붙이는 위치가 다르다. 비용 모델이 다르므로 최적해가 갈리는 것은 자연스럽다. 여기서 확인된 것은 **탐색 공간의 모양**이지 어느 쪽 비용 추정이 더 정확한가가 아니다.

조인 분배 방식은 셋 다 전부 broadcast(Trino `REPLICATED` / StarRocks `BROADCAST`)였다. SF 0.01에서는 모든 테이블이 broadcast 임계값 아래라 **이 데이터 규모로는 분배 방식이 판별되지 않는다.**

### 판정

**동등하지 않다 — 설계가 다르다.** 우열이 아니라 트레이드오프다.

- Trino는 8개까지 항상 전수 열거한다. 더 나은 플랜을 찾을 가능성이 높지만 컴파일 시간이 조인 개수에 지수적이다(`generatePartitions` 가 powerSet 기반).
- StarRocks는 5개부터 휴리스틱으로 내려간다. 컴파일이 빠르고 조인 50개까지 처리하지만, 5~16개 구간에서는 전수 탐색이 찾을 플랜을 놓칠 수 있다.

**한정** — SF 0.01 / worker 1대 / BE 1대에서 얻은 결과다. 여기서 확인한 것은 *어떤 탐색 경로를 타는가*이며, **어느 쪽 플랜이 더 빠른가는 측정하지 않았다.** 실행 시간 비교는 `perf` 프로파일이 필요하고 이 호스트에서는 불가능하다(`plan/02` 6-2절).

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), 세션 변수는 명시한 것 외 기본값,
통계는 시드 시 양쪽 모두 ANALYZE 수행됨.
