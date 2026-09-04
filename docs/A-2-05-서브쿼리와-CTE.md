# A-2 옵티마이저 (5) — 서브쿼리 · CTE · 윈도우

> 비교 축: `plan/01-비교항목-정리.md` A-2 "**서브쿼리 언네스팅, CTE 재사용, 윈도우 함수 최적화**"
> 기준 버전: **Trino 483** (`works/trino`, tag 483) / **StarRocks 4.0.14** (`works/starrocks`, tag 4.0.14)
> 런타임 증거: `docs/evidence/A-2/20260904-subquery-cte-window-probes.md` (probe 5군, 상관 서브쿼리 15종 포함)
> 선행 문서: `docs/A-2-04-푸시다운-범위.md` (CTE 전용 푸시다운 규칙의 존재를 여기서 처음 언급했다)
> 일자: 2026-09-04

---

## 1. 비교 관점

이 문서는 세 가지를 한 자리에서 다룬다. 서로 다른 주제 같지만 **하나의 질문으로 묶인다 — 옵티마이저가 "같은 계산을 반복하지 않게" 만드는 수단이 무엇인가.**

| 주제 | 반복되는 것 | 없애는 수단 |
|---|---|---|
| 상관 서브쿼리 | 바깥 행마다 안쪽 쿼리를 한 번씩 | 디코릴레이션(조인으로 재작성) |
| CTE | 참조 횟수만큼 같은 서브플랜 | 한 번 계산 후 재사용 |
| 윈도우 함수 | 필요 없는 행까지 정렬·계산 | 순위 필터를 TopN 으로 강등 |

결론부터:

- **상관 서브쿼리** — 두 엔진 모두 디코릴레이션에 실패하면 **쿼리를 거부한다.** 15종 중 12종이 같고, 1종은 둘 다 실패하며, **2종은 정반대**다. 우열 없음
- **CTE 재사용** — **StarRocks 만 가능**하다. Trino 는 `WITH` 참조마다 다시 계획한다. 이 축의 유일한 기능 격차다
- **윈도우** — 최적화 대상 모양이 서로 어긋난다. 같은 의미의 쿼리를 어떻게 쓰느냐에 따라 유리한 엔진이 바뀐다

---

## 2. Trino 구현

### 2-1. 서브쿼리는 두 종류의 노드가 된다

플래닝 단계에서 서브쿼리는 `ApplyNode` 또는 `CorrelatedJoinNode` 로 남는다. 만드는 곳은 `works/trino/core/trino-main/src/main/java/io/trino/sql/planner/SubqueryPlanner.java` (895줄)다.

이 노드들은 **실행 가능한 연산자가 아니다.** 최적화 과정에서 전부 조인으로 바뀌어야 하고, 남아 있으면 쿼리가 실패한다 — `optimizations/CheckSubqueryNodesAreRewritten.java`:

```java
searchFrom(plan).where(ApplyNode.class::isInstance)
        .findFirst()
        .ifPresent(node -> { ... throw error(...); });
...
throw semanticException(NOT_SUPPORTED, originSubquery, "Given correlated subquery is not supported");
```

**Trino 에는 "재작성 못 하면 행마다 돌린다"는 대안 경로가 없다.**

### 2-2. 디코릴레이션은 파이프라인의 네 단계

`PlanOptimizers.java:519-579` 가 순서를 고정한다.

| 라인 | 단계 | 하는 일 |
|---|---|---|
| `:529` | (컬럼 프루닝 패스 안) | `TransformExistsApplyToCorrelatedJoin` — EXISTS 를 상관 조인으로 |
| `:531` | — | `TransformQuantifiedComparisonApplyToCorrelatedJoin` — `> ALL` 류 |
| `:532-552` | **DecorrelateSubqueries** | 비상관 서브쿼리 처리 + `DecorrelateUnnest` 3종 + `TransformCorrelated*Aggregation` **6종** |
| `:553-565` | **RewriteCorrelatedSubqueries** | `TransformCorrelatedInPredicateToJoin`, `TransformCorrelatedScalarSubquery`, `TransformCorrelatedJoinToJoin` |
| `:566-578` | **FinalizeCorrelatedSubqueries** | 잔여 정리 (`TransformCorrelatedSingleRowSubqueryToProject` 등) |
| `:579` | — | `CheckSubqueryNodesAreRewritten` — 남았으면 실패 |

규칙 수는 `Transform(Correlated|Uncorrelated|Exists|Filtering|Quantified)*` **14개** + `Decorrelate*` **4개**다.

`TransformCorrelated*Aggregation` 이 6개인 것은 **집계의 모양마다 규칙을 따로 뒀기 때문**이다 — Global / Distinct / Grouped × WithProjection / WithoutProjection.

### 2-3. 재작성 가능 여부를 판정하는 곳

실제 판단은 `optimizations/PlanNodeDecorrelator.java` (643줄)에 있다. 서브쿼리 트리를 내려가며 **처리할 수 있는 노드 종류가 6개**로 정해져 있다.

| 라인 | 노드 |
|---|---|
| `:126` | GroupReference |
| `:132` | Filter |
| `:183` | Limit |
| `:283` | TopN |
| `:388` | Aggregation |
| `:444` | Project |

Join, Union, Window 등이 상관 서브쿼리 안에 들어 있으면 여기서 막힌다.

**`LIMIT` 처리의 제약이 실측에서 그대로 드러난다** (`:183-202`, `:218-227`):

```java
if (node.getCount() == 1) {
    return rewriteLimitWithRowCountOne(childDecorrelationResult, node.getId());
}
...
private Optional<DecorrelationResult> rewriteLimitWithRowCountOne(...)
{
    ...
    if (constantSymbols.isEmpty() || !constantSymbols.containsAll(decorrelatedChildNode.getOutputSymbols())) {
        return Optional.empty();     // ← 상수가 아닌 컬럼을 내보내면 포기
    }
```

소스에 TODO 주석까지 달려 있다(`:205-219`) — *"The current decorrelation method for Limit (1) cannot deal with subqueries outputting other symbols than constants."*

반면 `visitTopN` (`:283-`)은 순위 윈도우로 바꿔 처리한다. **그래서 `ORDER BY … LIMIT 1` 은 되고 맨 `LIMIT 1` 은 안 된다**(4-1의 q10 / q11).

### 2-4. 패턴이 좁아서 못 하는 경우

`iterative/rule/TransformCorrelatedGlobalAggregationWithoutProjection.java:125-131`:

```java
private static final Pattern<CorrelatedJoinNode> PATTERN = correlatedJoin()
        .with(nonEmpty(Patterns.CorrelatedJoin.correlation()))
        .with(filter().equalTo(TRUE)) // todo non-trivial join filter: adding filter/project on top of aggregation
        .with(subquery().matching(aggregation()
                .with(empty(groupingColumns()))
                .with(source().capturedAs(SOURCE))
                .capturedAs(AGGREGATION)));
```

서브쿼리로 받을 수 있는 것은 `aggregation` 또는 (`WithProjection` 변형에서) `project(aggregation)` 뿐이다. **`filter(aggregation)` — 즉 `HAVING` 이 붙은 집계 — 는 패턴에 없다.** 소스의 `todo` 주석이 정확히 이 한계를 가리킨다. 4-1의 q12가 여기서 실패한다.

### 2-5. CTE — 참조마다 다시 계획한다

`sql/planner/RelationPlanner.java:303-315`:

```java
Query namedQuery = analysis.getNamedQuery(node);
...
if (namedQuery != null) {
    RelationPlan subPlan;
    if (analysis.isExpandableQuery(namedQuery)) {      // 재귀 CTE
        subPlan = new QueryPlanner(...).planExpand(namedQuery);
    }
    else {
        subPlan = process(namedQuery, null);           // ← 참조마다 AST 로부터 재계획
    }
```

`WITH` 는 **이름 붙은 서브쿼리**일 뿐이고, 참조 횟수만큼 서브플랜이 복제된다. Trino 에는 CTE 전용 플랜 노드가 없고, 구체화 여부를 제어하는 설정도 없다 — `FeaturesConfig` 에 CTE 관련 항목은 재귀 깊이 제한(`:426`) 하나뿐이다.

### 2-6. 윈도우 — 규칙 16개, 핵심은 "윈도우를 없애기"

`iterative/rule/` 에 윈도우/순위 관련 규칙이 **16개** 있다. 성격별로:

| 갈래 | 대표 |
|---|---|
| 윈도우 자체를 제거 | `ReplaceWindowWithRowNumber`, `RemoveRedundantWindow` |
| 순위 필터/LIMIT 를 흡수 | `PushdownFilterIntoWindow`, `PushdownLimitIntoWindow`, `PushdownFilterIntoRowNumber`, `PushdownLimitIntoRowNumber` |
| 인접 윈도우 병합 | `GatherAndMergeWindows` (`:64-65` — `MergeAdjacentWindowsOverProjects`, `SwapAdjacentWindowsBySpecifications`) |
| 컬럼 프루닝 | `PruneWindowColumns`, `PruneTopNRankingColumns`, `PruneOrderByInWindowAggregation` |
| dereference 푸시다운 | `PushDownDereferencesThroughWindow`, `…ThroughTopNRanking`, `…ThroughRowNumber` |

여기에 `optimizations/WindowFilterPushDown.java` 가 별도로 있다.

목표가 분명하다 — **`row_number()`/`rank()` 에 상한이 걸리면 윈도우 연산자를 `TopNRanking` 으로 강등하고 정렬을 없앤다.** 4-3에서 실제로 그렇게 나온다.

---

## 3. StarRocks 구현

### 3-1. 서브쿼리는 `LogicalApplyOperator`, 남으면 예외

StarRocks 도 서브쿼리를 `Apply` 오퍼레이터로 만든다. 재작성 단계가 끝난 뒤에도 남아 있으면 예외를 던진다 — `rule/transformation/ApplyExceptionRule.java`:

```java
public ApplyExceptionRule() {
    super(RuleType.TF_APPLY_EXCEPTION,
            Pattern.create(OperatorType.LOGICAL_APPLY, OperatorType.PATTERN_LEAF, OperatorType.PATTERN_LEAF));
}

@Override
public List<OptExpression> transform(OptExpression input, OptimizerContext context) {
    throw UnsupportedException.unsupportedException("Not support the subquery!");
}
```

**Trino 의 `CheckSubqueryNodesAreRewritten` 과 정확히 같은 역할이다.** 실패 정책이 같다.

### 3-2. 디코릴레이션은 다섯 단계

`QueryOptimizer.java:542-547`:

```java
scheduler.rewriteIterative(tree, rootTaskContext, RuleSet.PUSH_DOWN_SUBQUERY_RULES);
scheduler.rewriteIterative(tree, rootTaskContext, RuleSet.SUBQUERY_EXTRACT_CORRELATION_PREDICATE_RULES);
scheduler.rewriteIterative(tree, rootTaskContext, RuleSet.SUBQUERY_REWRITE_TO_WINDOW_RULES);
scheduler.rewriteOnce(tree, rootTaskContext, new ExtractRangePredicateFromScalarApplyRule());
scheduler.rewriteIterative(tree, rootTaskContext, RuleSet.SUBQUERY_REWRITE_TO_JOIN_RULES);
scheduler.rewriteOnce(tree, rootTaskContext, new ApplyExceptionRule());
```

규칙 집합의 내용(`rule/RuleSet.java:289-316`):

| 집합 | 규칙 |
|---|---|
| `PUSH_DOWN_SUBQUERY_RULES` | `MergeApplyWithTableFunction`, `PushDownApplyLeftProjectRule`, `PushDownApplyLeftRule` |
| `SUBQUERY_EXTRACT_CORRELATION_PREDICATE_RULES` | `PushDownApplyProjectRule`, `PushDownApplyFilterRule`, `PushDownApplyAggFilterRule`, `PushDownApplyAggProjectFilterRule` |
| `SUBQUERY_REWRITE_TO_WINDOW_RULES` | `ScalarApply2AnalyticRule` |
| `SUBQUERY_REWRITE_TO_JOIN_RULES` | `QuantifiedApply2JoinRule`, `ExistentialApply2JoinRule`, `ScalarApply2JoinRule`, `ExistentialApply2OuterJoinRule`, `QuantifiedApply2OuterJoinRule` |

Apply 관련 규칙은 전부 **15개**다(Trino 의 14+4 와 대등한 규모).

**구조가 다른 지점이 하나 있다.** StarRocks 에는 `SUBQUERY_REWRITE_TO_WINDOW_RULES` 라는 단계가 따로 있고, 거기 든 `ScalarApply2AnalyticRule` 은 상관 스칼라 서브쿼리를 **조인이 아니라 윈도우 함수로** 재작성한다(`:143-151`, 대상 함수는 `count/sum/avg/min/max`). Trino 에는 대응 규칙이 없다.

다만 **이 랩에서는 발동시키지 못했다** — 자기상관 집계 비교(4-2 B-3)를 포함해 시도한 모든 쿼리에서 StarRocks 도 조인을 골랐다. 발동 조건은 미확인이다.

### 3-3. CTE 는 1급 오퍼레이터다

여기가 Trino 와 갈리는 지점이다. StarRocks 는 CTE 를 **플랜 오퍼레이터 3종**으로 표현한다.

```
operator/logical/LogicalCTEAnchorOperator.java
operator/logical/LogicalCTEProduceOperator.java
operator/logical/LogicalCTEConsumeOperator.java
```

- **Produce** — CTE 본문을 계산하는 곳
- **Consume** — CTE 를 참조하는 곳(여러 개)
- **Anchor** — Produce 와 그것을 쓰는 본체를 묶는 노드

즉 **플랜이 트리가 아니라 DAG 가 될 수 있다.** 실행 계층의 짝이 `MultiCastDataSinks` 로, 한 번 계산한 결과를 여러 소비자에게 뿌린다(4-4 실측).

전용 규칙은 `rule/transformation/` 에 **15개** 있다 — 수집(`CollectCTEProduceRule`/`CollectCTEConsumeRule`), 인라인(`InlineOneCTEConsumeRule`), 푸시다운 4종(A-2-04 3-2에서 본 것들), 재작성 활용(`RewriteGroupingSetsByCTERule`, `MultiDistinctByCTERewriter`) 등.

### 3-4. 재사용할지 인라인할지 — 두 층으로 정한다

**(가) 규칙 층의 조기 결정** — `CTEContext.java:157-188`:

```java
public boolean needInline(int cteId) {
    if (!consumeNums.containsKey(cteId)) return true;            // 소비자가 전부 잘림
    if (forceCTEList.contains(cteId)) return false;
    if (!enableCTE || consumeNums.getOrDefault(cteId, 0) <= 1) return true;   // 참조 1회 → 인라인
    if (inlineCTERatio < 0) return true;                          // 강제 인라인
    if (inlineCTERatio == 0) return false;                        // 강제 재사용
    if (produces.size() > maxCTELimit) {                          // CTE 가 너무 많으면
        return consumeNums.get(cteId) < MIN_EVERY_CTE_REFS;
    }
    return false;
}
```

`QueryOptimizer.java:533-536` 이 `hasInlineCTE()` 가 거짓이 될 때까지 인라인을 반복한다.

**(나) Cascades 비용 층의 최종 결정** — 살아남은 CTE 는 Memo 안에서 두 구현이 **경쟁**한다. `rule/RuleSet.java:211-215` 의 `ALL_IMPLEMENT_RULES`:

```java
new CTEAnchorImplementationRule(),
new CTEAnchorToNoCTEImplementationRule(),      // 재사용 안 함
new CTEConsumerReuseImplementationRule(),      // 재사용
new CTEConsumeInlineImplementationRule(),      // 인라인
new CTEProduceImplementationRule()
```

비용은 `cost/CostModel.java:541-547`:

```java
public CostEstimate visitPhysicalCTEAnchor(PhysicalCTEAnchorOperator node, ExpressionContext context) {
    Statistics cteStatistics = context.getChildStatistics(0);
    double ratio = ConnectContext.get().getSessionVariable().getCboCTERuseRatio();
    double produceSize = cteStatistics.getOutputSize(context.getChildOutputColumns(0));
    return CostEstimate.of(produceSize * node.getConsumeNum() * 0.5, produceSize * (1 + ratio), 0);
}
```

`PhysicalNoCTEOperator`(인라인 쪽)의 비용은 **0** 이다(`:555-558`). 즉 **재사용에는 메모리 비용 `produceSize × (1 + ratio)` 라는 페널티가 붙고**, 인라인 쪽은 복제된 하위 트리의 스캔 비용을 그대로 문다. 둘을 저울질한다.

**손잡이** (`qe/SessionVariable.java:1451-1460`):

| 변수 | 기본값 | 뜻 |
|---|---|---|
| `cbo_cte_reuse` | `true` | 켜짐 (파이프라인 엔진일 때만 유효, `:4595-4598`) |
| `cbo_cte_reuse_rate` | `1.15` | `< 0` 강제 인라인 / `= 0` 강제 재사용 / `> 0` 비용×비율 |
| `cbo_cte_max_limit` | `10` | CTE 개수 상한 (`INVISIBLE`) |

### 3-5. 윈도우 — 규칙 15개, 핵심은 "윈도우 앞을 자르기"

`rule/transformation/` 의 윈도우/순위 관련 규칙이 **15개**다. Trino 의 16개와 수는 비슷하지만 **목표가 다르다.**

| 갈래 | 대표 |
|---|---|
| 윈도우 **앞에** TopN 삽입 | `PushDownLimitRankingWindowRule`, `PushDownTopNToPreAggRule` |
| 술어를 윈도우 아래로 | `PushDownPredicateRankingWindowRule`, `PushDownPredicateWindowRule` |
| TopN 을 조인/유니온 아래로 | `PushDownTopNBelowOuterJoinRule`, `PushDownTopNBelowUnionRule` |
| TopN 분할·재배치 | `SplitTopNRule`, `SplitTopNAggregateRule`, `DeferProjectAfterTopNRule`, `HoistHeavyCostExprsUponTopnRule` |
| 스큐 분산 | `SplitWindowSkewToUnionRule` |
| 컬럼 프루닝 | `PruneWindowColumnsRule`, `PruneTopNColumnsRule`, `PruneEmptyWindowRule` |

**"윈도우 연산자를 없앤다"는 규칙이 없다.** 윈도우는 남기고 그 앞을 자른다. 4-3의 플랜 모양이 정확히 그렇다.

`PushDownLimitRankingWindowRule` 이 노리는 모양은 클래스 주석에 그림으로 그려져 있다 — **`TopN` 위에 있고 그 아래에 `Window` 가 있는** 형태, 즉 `ORDER BY 순위컬럼 LIMIT n` 이다. 맨 `LIMIT` 은 대상이 아니다.

---

## 4. 실측

전체 절차·조건은 `docs/evidence/A-2/20260904-subquery-cte-window-probes.md`.

### 4-1. 상관 서브쿼리 15종 — 12 동일, 1 공통 실패, 2 정반대

| # | 모양 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|---|
| q01–q09, q13–q15 | 스칼라/EXISTS/NOT EXISTS/IN/NOT IN/중첩/OR/윈도우 필터 | ✅ | ✅ |
| **q10** | 상관 + `LIMIT 1` | ❌ | ❌ |
| **q11** | 상관 + `ORDER BY … LIMIT 1` | ✅ | ❌ |
| **q12** | 상관 EXISTS 안에 집계 + `HAVING` | ❌ | ✅ |

거부 메시지는 각각 `Given correlated subquery is not supported` / `Not support the subquery!` 다.

세 결과가 모두 **2절·3절의 코드로 설명된다.**

- q10 — Trino 는 `rewriteLimitWithRowCountOne` 의 상수 제약(2-3)에 걸린다. StarRocks 도 실패
- q11 — Trino 는 `visitTopN` 경로로 넘어가 `TopNRanking[partitionBy=[l_orderkey], orderBy=[l_linenumber], limit=1]` + `InnerJoin` 을 만든다
- q12 — Trino 는 `filter(aggregation)` 를 받는 패턴이 없다(2-4). StarRocks 는 `LEFT SEMI JOIN` 으로 처리하고 8282 를 돌려준다

### 4-2. 의미론은 동등하다

| 검사 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 스칼라 서브쿼리가 여러 행 | 실행 중 오류 (`Scalar sub-query has returned multiple rows`) | 실행 중 오류 (`correlate scalar subquery result must 1 row`) |
| 대응 행 없는 상관 `count` = 0 판정 | 15000 (정답) | 15000 (정답) |
| 자기상관 집계 비교 | 27987 | 27987 |

**둘 다 계획은 성공시키고 실행 중에 카디널리티를 검사한다.** Trino 는 코디네이터에서, StarRocks 는 BE 에서 난다.

디코릴레이션 결과의 **표현**은 다르다.

| 쿼리 | Trino | StarRocks |
|---|---|---|
| 상관 EXISTS | `InnerJoin` + 서브쿼리측 집계 | **`LEFT SEMI JOIN`** |
| 상관 NOT EXISTS | `LeftJoin` + 서브쿼리측 집계 | **`LEFT ANTI JOIN`** |
| 상관 NOT IN | `LeftJoin[filter = (o_orderkey IS NULL OR … OR l_orderkey IS NULL) AND …]` | **`NULL AWARE LEFT ANTI JOIN`** |

**StarRocks 는 semi/anti 전용 조인 연산자를 갖고 있고 Trino 는 없다.** Trino 는 outer join + 필터 조합으로 같은 의미를 만든다. 어느 쪽이 빠른지는 측정하지 않았다.

또 하나. 자기상관 집계에서 Trino 플랜에 `CrossJoin` 위의 `COALESCE(avg, avg_20)` 가 나오는데, `avg_20` 은 `Aggregate[] over Values[]` — **"입력이 비었을 때 집계가 반환하는 값"을 플랜에 명시적으로 넣은 것**이다. `count` 의 0 을 맞추려면 필요한 구조다. StarRocks 는 이 케이스를 단일 `INNER JOIN` 으로 처리했고, 결과는 같았다.

### 4-3. 윈도우 — 최적화 대상 모양이 어긋난다

| 쿼리 모양 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| `row_number() <= 3` 필터 | `TopNRanking(limit 3)` — **윈도우 사라짐** | `PARTITION-TOP-N(3)` → 셔플 → `SORT` → `ANALYTIC` → `SELECT` |
| `row_number() OVER(ORDER BY x)` + 바깥 `LIMIT 5` | `TopNRanking(limit 5)` — 전역 정렬 없음 | **`SORT`(60175행 전량)** → `ANALYTIC limit: 5` |
| `… ORDER BY rk LIMIT 5` | `TopN(5)` → **`Window`(전량)** → 스캔 | `TOP-N(5)` → `ANALYTIC` → **`TOP-N(5)`** → 스캔 |
| 같은 `PARTITION BY`/`ORDER BY` 윈도우 함수 2개 | **`Window` 노드 1개** | `ANALYTIC` 노드 **2개** (정렬은 1개 공유) |

두 번째와 세 번째가 **정확히 뒤집혀 있다.** Trino 는 맨 `LIMIT` 모양을, StarRocks 는 `ORDER BY 순위컬럼 LIMIT` 모양을 최적화한다. 3-5에서 읽은 `PushDownLimitRankingWindowRule` 의 대상 패턴 그대로다.

### 4-4. CTE 재사용 — StarRocks 만 가능하다

```sql
WITH t AS (SELECT l_orderkey, sum(l_extendedprice) s FROM lineitem GROUP BY l_orderkey)
SELECT count(*) FROM t a JOIN t b ON a.l_orderkey = b.l_orderkey WHERE a.s > b.s;
```

| 엔진 / 설정 | lineitem 스캔 수 |
|---|---|
| Trino 483 | 2 |
| StarRocks 4.0.14 (기본) | 2 |
| StarRocks 4.0.14 (`SET cbo_cte_reuse_rate = 0`) | **1** + `MultiCastDataSinks` |

**기본 설정의 StarRocks 도 인라인을 골랐다.** SF 0.01 에서는 lineitem 재계산이 재사용보다 싸기 때문이다(3-4의 메모리 페널티). 참조 3회로 늘려도 마찬가지였다.

**즉 이 랩에서 확인된 것은 "능력이 있다"까지다.** 비용 모델이 자동으로 재사용을 고르는 규모는 확인하지 못했다.

---

## 5. 설계 차이와 그 원인

### 5-1. 요약

| | Trino | StarRocks |
|---|---|---|
| 서브쿼리 중간 노드 | `ApplyNode` / `CorrelatedJoinNode` | `LogicalApplyOperator` |
| 재작성 실패 시 | `CheckSubqueryNodesAreRewritten` → 쿼리 거부 | `ApplyExceptionRule` → 쿼리 거부 |
| 디코릴레이션 규칙 수 | 14 (`Transform*`) + 4 (`Decorrelate*`) | 15 (`*Apply*`) |
| 단계 수 | 파이프라인 4단계(이름 붙은 `IterativeOptimizer`) | 규칙 집합 5회 호출 |
| 판정 지점 | `PlanNodeDecorrelator` — 처리 가능 노드 6종 | 각 `Apply2*Rule` 의 패턴 |
| 조인 연산자 | semi/anti 전용 없음 — outer join + 필터 | `LEFT SEMI` / `LEFT ANTI` / `NULL AWARE LEFT ANTI` |
| 스칼라 → 윈도우 재작성 | 없음 | `ScalarApply2AnalyticRule` (**발동 미확인**) |
| **CTE** | **없음** — `WITH` 는 참조마다 재계획 | Anchor/Produce/Consume 오퍼레이터 + `MultiCastDataSinks` |
| CTE 재사용 판단 | — | 규칙 층(`CTEContext.needInline`) + **Cascades 비용 층**(구현 규칙 경쟁) |
| 윈도우 최적화 방향 | **윈도우를 제거**(`TopNRanking` 강등) | **윈도우 앞을 자름**(TopN 삽입) |
| 인접 윈도우 병합 | `GatherAndMergeWindows` | 대응 규칙 없음 |

### 5-2. 실패 정책이 같다는 것이 중요하다

두 엔진 다 **디코릴레이션에 실패하면 쿼리를 실행하지 않는다.** 이것은 설계 선택이다 — 다른 DB 처럼 "행마다 서브쿼리 실행"으로 물러설 수도 있지만, 분산 실행 엔진에서 그 경로는 성능이 예측 불가능해진다.

운영 관점의 귀결은 분명하다. **상관 서브쿼리를 쓰는 쿼리는 두 엔진 사이에서 이식할 때 "느려지는" 게 아니라 "안 돌 수" 있다.** 4-1의 q11·q12가 그 예다. 마이그레이션 시 성능 벤치마크보다 **먼저 계획 성공 여부를 전수 확인**해야 한다.

### 5-3. CTE 재사용이 한쪽에만 있는 이유

이 격차는 A-2-01·A-2-04에서 반복해 본 구도의 연장이다.

Trino 의 플랜은 **트리**다. 하나의 서브플랜 결과를 여러 부모가 나눠 쓰려면 실행 계층에 "한 번 계산해 여러 소비자에게 분배하는 교환"이 있어야 하고, 그것은 중간 결과를 어딘가에 담아둔다는 뜻이다. Trino 는 그 자리를 비워 뒀다 — **중간 결과를 물질화하지 않는다**는 것이 이 엔진의 일관된 성격이고, FTE(`plan/01` B-4)에서만 예외적으로 스풀링을 도입한다.

StarRocks 는 자체 스토리지와 BE 를 갖고 있어 중간 결과를 담아둘 자리가 이미 있다. `MultiCastDataSinks` 는 그 위에 얹힌 것이다.

**따라서 이것은 "Trino 가 빠뜨린 기능"이라기보다 실행 모델의 귀결로 읽는 편이 정확하다.** 다만 결과는 결과다 — 같은 CTE 를 여러 번 참조하는 ETL 성 쿼리에서 Trino 는 매번 다시 계산한다.

**Trino 에서의 대체 수단**은 두 가지다.

- CTE 를 임시 테이블로 물질화(`CREATE TABLE … AS`)한 뒤 참조 — 수동이고 트랜잭션 경계가 생긴다
- 커넥터의 MV(Iceberg/Hive 한정) — A-2-06의 주제

### 5-4. 윈도우 최적화 방향이 다른 이유

Trino 는 `TopNRanking` 이라는 **전용 물리 연산자**를 갖고 있다. `row_number() ≤ n` 을 만나면 윈도우를 통째로 그것으로 바꾼다 — 정렬도 윈도우 계산도 사라진다.

StarRocks 는 `PARTITION-TOP-N` 을 **윈도우 앞의 프리필터**로 쓴다. 윈도우 연산자는 그대로 남아 정렬과 계산을 수행한다. 대신 입력이 이미 잘려 있다.

어느 쪽이 실제로 빠른지는 **측정하지 않았다.** 다만 플랜 구조상 Trino 쪽이 하는 일이 적다.

한편 3-5에서 본 것처럼 **StarRocks 의 규칙 15개는 TopN 을 조인·유니온 아래로 내리고 스큐를 분산시키는 데 더 많이 배정돼 있다.** 방향이 다를 뿐 투자량은 비슷하다.

실무적으로 중요한 것은 4-3의 **뒤집힘**이다.

| 쿼리를 이렇게 쓰면 | 유리한 쪽 |
|---|---|
| `… ) t LIMIT n` | Trino |
| `… ) t ORDER BY rk LIMIT n` | StarRocks |

**같은 의미의 쿼리를 어떻게 쓰느냐가 엔진별로 다른 플랜을 만든다.** 둘 다 쓰는 환경이라면 이 차이를 알고 써야 한다.

---

## 6. 결론

**서브쿼리는 대등하고, CTE 는 StarRocks 우위, 윈도우는 무승부다.**

- **서브쿼리** — 15종 중 12종 동일, 1종 공통 실패, **2종이 정반대**. 규칙 수(18 vs 15)도 대등하다. **어느 쪽도 완전하지 않고, 못 하는 모양이 서로 다르다**는 것이 이 축의 결론이다. 의미론(카디널리티 검사, 빈 그룹 집계)은 세 검사 모두 일치했다
- **CTE** — **이 문서에서 유일한 명확한 기능 격차다.** StarRocks 는 CTE 를 오퍼레이터로 남기고 Cascades 비용으로 재사용 여부를 정한다. Trino 는 참조마다 재계획한다. 다만 이 랩(SF 0.01)에서는 StarRocks 의 비용 모델도 자동으로는 재사용을 고르지 않았다 — **능력의 존재까지만 확인됐다**
- **윈도우** — 최적화하는 쿼리 모양이 어긋나 있어 서로 하나씩 이긴다. Trino 는 윈도우를 없애는 쪽, StarRocks 는 윈도우 앞을 자르는 쪽이다

**운영·마이그레이션 관점**

| 상황 | 해야 할 일 |
|---|---|
| 상관 서브쿼리를 쓰는 쿼리를 이식 | 성능 비교 전에 **계획 성공 여부부터 전수 확인**. 실패는 오류로 드러난다 |
| 상관 + `LIMIT 1` 이 필요 | 양쪽 다 실패한다. `ORDER BY … LIMIT 1` 로 바꾸면 Trino 는 통과한다 |
| 같은 CTE 를 3회 이상 참조하는 ETL | StarRocks 는 `cbo_cte_reuse_rate` 를 낮춰 재사용을 유도할 수 있다. Trino 는 임시 테이블 외에 수단이 없다 |
| 순위 상위 n 건 추출 | Trino 는 `LIMIT n`, StarRocks 는 `ORDER BY rk LIMIT n` 이 각각 유리한 모양이다 |

### 아직 답하지 않은 것

- **실행 시간** — 전 항목 미측정. semi/anti 전용 연산자, `TopNRanking` vs `PARTITION-TOP-N`, CTE 재사용의 실이득이 모두 여기 걸려 있다(`perf` 프로파일 필요, `plan/02` 6-2절)
- **CTE 재사용이 자동 선택되는 규모** — SF 0.01 에서는 항상 인라인이 이긴다. 더 큰 데이터가 필요하다
- **`MultiCastDataSinks` 의 다중 노드 동작** — BE 1대에서는 셔플 비용이 0으로 계산되므로(A-2-03 5-1) 이득 구조를 볼 수 없다
- **`ScalarApply2AnalyticRule` 의 발동 조건** — 소스에는 있으나 이 랩에서 발동시키지 못했다
- **재귀 CTE** — 양쪽 지원 범위를 확인하지 않았다
- **서브쿼리 지원 매트릭스의 완전성** — 15종은 대표 모양일 뿐이다. 실제 마이그레이션에서는 대상 쿼리를 직접 돌려봐야 한다
- **MV 를 통한 재사용** — CTE 가 아니라 "미리 계산해 둔 것으로 바꾸는" 경로는 **A-2-06**
