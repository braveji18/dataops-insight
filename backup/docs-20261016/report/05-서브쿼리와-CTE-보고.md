# [보고] Trino vs StarRocks 비교 (5) — 복잡한 조회문을 단순한 형태로 바꾸는 능력

> 작성일: 2026-09-04 | 대상 버전: Trino 483, StarRocks 4.0.14
> 상세 기술 문서: `docs/A-2-05-서브쿼리와-CTE.md`
>
> 이 보고서의 모든 코드는 위 두 버전의 **실제 소스에서 그대로 발췌**한 것이며,
> 각 제목의 링크로 GitHub에서 원문을 바로 확인하실 수 있습니다.

---

## 한 장 요약

조회문 안에 조회문이 들어 있거나(중첩 조회), 같은 중간 결과를 여러 번 참조하거나, 순위를 매기는 조회는 **그대로 실행하면 매우 느립니다.** 엔진은 이것들을 단순한 형태로 바꿔서 실행하는데, 그 능력을 비교했습니다.

| | Trino | StarRocks |
|---|---|---|
| 중첩 조회를 못 바꾸면 | **조회를 거부**(오류) | **조회를 거부**(오류) — 동일 |
| 중첩 조회 15가지 시험 | 12가지 동일 · 1가지 공통 실패 · **2가지가 정반대** | 좌동 |
| 결과의 정확성 | 3가지 검사 전부 일치 | 3가지 검사 전부 일치 |
| **같은 중간 결과 재사용** | **불가** — 참조할 때마다 다시 계산 | **가능** — 한 번 계산해 나눠줌 |
| 순위 조회 최적화 | 순위 계산 단계를 **없앰** | 순위 계산 앞을 **미리 잘라냄** |

**결론: 중첩 조회 처리 능력은 대등하고 어느 쪽도 완전하지 않습니다. 명확히 갈리는 것은 "같은 중간 결과를 재사용할 수 있는가" 하나이며, 이것은 StarRocks만 가능합니다.**

---

## 1. 왜 이걸 봤나

이 항목은 **다른 제품에서 옮겨올 때 가장 먼저 사고가 나는 지점**입니다.

일반적으로 조회 성능을 비교할 때는 "얼마나 빠른가"를 봅니다. 그런데 중첩 조회는 다릅니다 — **느려지는 게 아니라 아예 안 돌 수 있습니다.** 두 제품 모두 처리하지 못하는 형태를 만나면 오류를 내고 멈추도록 설계돼 있습니다.

그리고 못 하는 형태가 **서로 다릅니다.** Trino에서 잘 돌던 조회가 StarRocks에서 오류가 나고, 그 반대도 있습니다. 따라서 이식할 때는 **성능 측정보다 먼저 "돌기는 하는가"를 전수 확인해야 합니다.**

또 하나, 데이터 가공 작업(ETL)에서는 같은 중간 결과를 여러 번 참조하는 조회문이 흔합니다. 그것을 재사용할 수 있는지가 처리 시간에 직결됩니다.

---

## 2. Trino의 방식 — "바꾸지 못하면 멈춘다"

### 2-1. 바꾸지 못한 중첩 조회가 남아 있으면 조회를 거부한다

Trino는 중첩 조회를 일단 임시 형태로 만들어두고, 최적화 과정에서 전부 일반적인 테이블 연결 형태로 바꿉니다. **바꾸지 못한 것이 남아 있으면 실행하지 않습니다.**

**[CheckSubqueryNodesAreRewritten.java#L54-L58](https://github.com/trinodb/trino/blob/483/core/trino-main/src/main/java/io/trino/sql/planner/optimizations/CheckSubqueryNodesAreRewritten.java#L54-L58)**

```java
    private TrinoException error(List<Symbol> correlation, Node originSubquery)
    {
        checkState(!correlation.isEmpty(), "All the non correlated subqueries should be rewritten at this point");
        throw semanticException(NOT_SUPPORTED, originSubquery, "Given correlated subquery is not supported");
    }
```

▸ **읽는 법** — 최적화가 끝난 뒤 임시 형태가 남아 있으면 `NOT_SUPPORTED` 오류를 던집니다. 사용자가 보는 메시지는 *"Given correlated subquery is not supported"* 입니다.

**"느리더라도 어떻게든 실행한다"는 대안 경로가 없습니다.** 이는 의도된 설계입니다 — 바깥 데이터 한 건마다 안쪽 조회를 한 번씩 도는 방식은 여러 서버에 나눠 처리하는 구조에서 성능을 예측할 수 없기 때문입니다.

### 2-2. 못 바꾸는 형태가 있고, 그 이유가 소스에 적혀 있다

**[PlanNodeDecorrelator.java#L205-L207](https://github.com/trinodb/trino/blob/483/core/trino-main/src/main/java/io/trino/sql/planner/optimizations/PlanNodeDecorrelator.java#L205-L207)**

```java
        // TODO Limit (1) could be decorrelated by the method rewriteLimitWithRowCountGreaterThanOne() as well.
        // The current decorrelation method for Limit (1) cannot deal with subqueries outputting other symbols
        // than constants.
```

▸ **읽는 법** — 개발진이 남긴 **미완성 표시(TODO)** 입니다. "지금 방식으로는 `LIMIT 1` 이 붙은 중첩 조회에서 **고정값이 아닌 컬럼을 꺼내오는 경우를 처리하지 못한다**"는 뜻입니다. 4-1에서 실제로 이 형태의 조회가 실패했습니다.

같은 조회에 **`ORDER BY` 를 덧붙이면 통과합니다.** 정렬 기준이 생기면 다른 처리 경로(순위 매기기로 변환)로 갈 수 있기 때문입니다. 실무적으로 중요한 우회 방법입니다.

### 2-3. 같은 중간 결과를 여러 번 참조해도 매번 다시 계산한다

`WITH 이름 AS (...)` 로 중간 결과에 이름을 붙이고 여러 번 참조하는 문법이 있습니다. Trino가 이것을 어떻게 처리하는지 보면 이렇습니다.

**[RelationPlanner.java#L307-L315](https://github.com/trinodb/trino/blob/483/core/trino-main/src/main/java/io/trino/sql/planner/RelationPlanner.java#L307-L315)**

```java
        if (namedQuery != null) {
            RelationPlan subPlan;
            if (analysis.isExpandableQuery(namedQuery)) {
                subPlan = new QueryPlanner(analysis, symbolAllocator, idAllocator, lambdaDeclarationToSymbolMap, plannerContext, outerContext, session, recursiveSubqueries)
                        .planExpand(namedQuery);
            }
            else {
                subPlan = process(namedQuery, null);
            }
```

▸ **읽는 법** — `process(namedQuery, null)` 이 핵심입니다. 이름 붙은 중간 결과를 만날 때마다 **조회문 원본에서부터 다시 처리**합니다. 저장해두고 재사용하는 경로가 없습니다. 같은 이름을 세 번 참조하면 **세 번 계산합니다.**

Trino에는 이 동작을 바꾸는 설정도 없습니다(재귀 조회의 깊이 제한 설정만 존재합니다).

### 2-4. 순위 조회에서는 순위 계산 단계를 아예 없앤다

"각 그룹에서 상위 3건" 같은 조회는 순위를 매긴 뒤 3 이하만 남깁니다. Trino는 이 조합을 발견하면 **순위 계산 단계를 통째로 다른 것으로 바꿉니다.**

**[PushdownFilterIntoWindow.java#L107-L114](https://github.com/trinodb/trino/blob/483/core/trino-main/src/main/java/io/trino/sql/planner/iterative/rule/PushdownFilterIntoWindow.java#L107-L114)**

```java
        TopNRankingNode newSource = new TopNRankingNode(
                windowNode.getId(),
                windowNode.getSource(),
                windowNode.getSpecification(),
                rankingType.get(),
                rankingSymbol,
                upperBound.getAsInt(),
                false);
```

▸ **읽는 법** — `windowNode`(순위 계산 단계)를 재료로 `TopNRankingNode`(상위 N건 추출 전용 단계)를 새로 만듭니다. **결과적으로 순위 계산 단계와 전체 정렬이 조회 계획에서 사라집니다.** 상위 3건만 필요한데 전부 정렬할 이유가 없다는 판단입니다.

---

## 3. StarRocks의 방식 — "실패 정책은 같고, 중간 결과는 재사용한다"

### 3-1. 바꾸지 못한 중첩 조회가 남으면 역시 거부한다

**[ApplyExceptionRule.java#L34-L36](https://github.com/StarRocks/starrocks/blob/4.0.14/fe/fe-core/src/main/java/com/starrocks/sql/optimizer/rule/transformation/ApplyExceptionRule.java#L34-L36)**

```java
    public List<OptExpression> transform(OptExpression input, OptimizerContext context) {
        throw UnsupportedException.unsupportedException("Not support the subquery!");
    }
```

▸ **읽는 법** — 최적화가 끝난 뒤에도 임시 형태가 남아 있으면 예외를 던집니다. 사용자가 보는 메시지는 *"Not support the subquery!"* 입니다. **Trino의 2-1과 역할이 정확히 같습니다.**

**두 제품이 같은 실패 정책을 택했다는 점이 이번 비교에서 가장 중요한 공통점입니다.**

### 3-2. 같은 중간 결과를 "재사용할지 그때그때 계산할지" 두 후보를 만든다

StarRocks는 이름 붙은 중간 결과를 조회 계획 안에 **독립된 단계로 남깁니다.** 그리고 처리 방식 두 가지를 나란히 후보로 올려둡니다.

**[RuleSet.java#L211-L215](https://github.com/StarRocks/starrocks/blob/4.0.14/fe/fe-core/src/main/java/com/starrocks/sql/optimizer/rule/RuleSet.java#L211-L215)**

```java
            new CTEAnchorImplementationRule(),
            new CTEAnchorToNoCTEImplementationRule(),
            new CTEConsumerReuseImplementationRule(),
            new CTEConsumeInlineImplementationRule(),
            new CTEProduceImplementationRule()
```

▸ **읽는 법** — 세 번째 `CTEConsumerReuseImplementationRule`(**재사용**)과 네 번째 `CTEConsumeInlineImplementationRule`(**그때그때 계산**)이 나란히 등록돼 있습니다. 둘 다 후보로 만들어진 뒤 **비용을 비교해 이기는 쪽이 선택됩니다.** Trino에는 첫 번째 선택지 자체가 없습니다.

### 3-3. 재사용 여부는 비용으로 판단한다

**[CostModel.java#L541-L547](https://github.com/StarRocks/starrocks/blob/4.0.14/fe/fe-core/src/main/java/com/starrocks/sql/optimizer/cost/CostModel.java#L541-L547)**

```java
        public CostEstimate visitPhysicalCTEAnchor(PhysicalCTEAnchorOperator node, ExpressionContext context) {
            // memory cost
            Statistics cteStatistics = context.getChildStatistics(0);
            double ratio = ConnectContext.get().getSessionVariable().getCboCTERuseRatio();
            double produceSize = cteStatistics.getOutputSize(context.getChildOutputColumns(0));
            return CostEstimate.of(produceSize * node.getConsumeNum() * 0.5, produceSize * (1 + ratio), 0);
        }
```

▸ **읽는 법** — 재사용을 택하면 **중간 결과를 어딘가에 담아둬야 하므로 메모리 비용**이 붙습니다. 그 값이 `produceSize * (1 + ratio)` 이고, 기본 `ratio` 가 1.15이므로 **중간 결과 크기의 약 2.15배**를 메모리 비용으로 계산합니다. 반대편(그때그때 다시 계산) 후보는 이 자리의 비용이 0이고, 대신 복제된 계산의 데이터 읽기 비용을 각각 뭅니다. 둘을 저울질합니다.

조절 손잡이도 있습니다.

**[SessionVariable.java#L1452-L1458](https://github.com/StarRocks/starrocks/blob/4.0.14/fe/fe-core/src/main/java/com/starrocks/qe/SessionVariable.java#L1452-L1458)**

```java
    @VarAttr(name = CBO_CTE_REUSE)
    private boolean cboCteReuse = true;

    // -1 (< 0): disable cte, force inline. 0: force cte; other (> 0): compute by costs * ratio
    @VarAttr(name = CBO_CTE_REUSE_RATE_V2, flag = VariableMgr.INVISIBLE, alias = CBO_CTE_REUSE_RATE,
            show = CBO_CTE_REUSE_RATE)
    private double cboCTERuseRatio = 1.15;
```

▸ **읽는 법** — 주석이 사용법을 그대로 밝힙니다. **음수면 재사용 끄기, 0이면 무조건 재사용, 양수면 비용 비교**입니다. 즉 비용 판단이 마음에 들지 않으면 **0으로 두어 강제할 수 있습니다.** 4-3에서 이 방법으로 재사용을 확인했습니다.

### 3-4. 순위 조회에서는 순위 계산을 남기고 그 앞을 잘라낸다

**[PushDownLimitRankingWindowRule.java#L54-L68](https://github.com/StarRocks/starrocks/blob/4.0.14/fe/fe-core/src/main/java/com/starrocks/sql/optimizer/rule/transformation/PushDownLimitRankingWindowRule.java#L54-L68)**

```java
 * Before:
 *       TopN
 *         |
 *       Project
 *         |
 *       Window
 *
 * After:
 *       TopN
 *         |
 *       Project
 *         |
 *       Window
 *         |
 *       TopN
```

▸ **읽는 법** — 개발진이 그림으로 남긴 설계 의도입니다. `Window`(순위 계산 단계)가 **그대로 남고**, 그 **아래에** `TopN`(상위 N건 추출)이 새로 삽입됩니다. 순위 계산에 들어가는 입력을 미리 줄이는 방식입니다.

**Trino의 2-4와 방향이 다릅니다** — Trino는 순위 계산 단계를 없애고, StarRocks는 남긴 채 앞을 자릅니다.

> **주의**: 이 그림의 맨 위에 `TopN` 이 있다는 점이 중요합니다. 이 규칙은 **`ORDER BY 순위컬럼 LIMIT n`** 형태를 노립니다. 그냥 `LIMIT n` 만 붙은 형태는 대상이 아닙니다(4-4에서 확인).

---

## 4. 실제로 돌려서 확인한 것

**시험 조건**: Trino 처리 서버 1대 / StarRocks 처리 서버 1대, TPC-H 표준 데이터 최소 규모(약 6만 건), 두 제품이 **같은 데이터 파일**을 봅니다. 실행 시간은 재지 않았고, **조회가 성공하는지**와 **조회 계획의 모양**만 비교했습니다.

### 4-1. 중첩 조회 15가지 — 12가지 동일, 2가지가 정반대

대표적인 중첩 조회 형태 15가지를 양쪽에 던졌습니다.

| 형태 | Trino | StarRocks |
|---|---|---|
| 중첩 조회 결과를 값으로 쓰기 / EXISTS / NOT EXISTS / IN / NOT IN / 이중 중첩 / OR 안의 중첩 / 순위 필터 등 **12가지** | ✅ | ✅ |
| 중첩 조회 + `LIMIT 1` | ❌ | ❌ |
| 중첩 조회 + `ORDER BY … LIMIT 1` | **✅** | **❌** |
| EXISTS 안에 집계 + `HAVING` | **❌** | **✅** |

**정반대인 두 가지가 이번 보고의 핵심입니다.**

- `ORDER BY … LIMIT 1` — **Trino만 통과.** 2-2에서 본 대로 정렬 기준이 있으면 순위 매기기로 바꿔 처리합니다
- EXISTS 안의 집계 + `HAVING` — **StarRocks만 통과.** Trino는 이 형태를 받는 처리 규칙이 없고, 소스에도 미완성 표시가 붙어 있습니다

거부 메시지는 각각 이렇습니다.

```
Trino     : Given correlated subquery is not supported
StarRocks : Not support the subquery!
```

### 4-2. 결과의 정확성은 세 가지 검사 모두 일치했다

바꿔 쓰는 과정에서 결과가 달라지면 안 됩니다. 위험한 세 지점을 확인했습니다.

| 검사 | Trino | StarRocks |
|---|---|---|
| 값 하나를 기대한 중첩 조회가 여러 건을 낼 때 | 실행 중 오류 | 실행 중 오류 |
| 짝이 하나도 없을 때의 건수 세기(정답 15,000) | **15,000** | **15,000** |
| 같은 테이블끼리 비교하는 중첩 조회(정답 27,987) | **27,987** | **27,987** |

**둘 다 조회 계획은 만들어지고 실행 중에 오류를 냅니다.** Trino는 총괄 서버에서, StarRocks는 데이터 처리 서버에서 오류가 발생하는 차이만 있습니다.

바꿔 쓴 결과의 **모양**은 다릅니다. StarRocks는 "한쪽에만 있는 것 찾기" 전용 연결 방식(`LEFT ANTI JOIN` 등)을 갖고 있고, Trino는 일반 연결 + 조건 검사 조합으로 같은 의미를 만듭니다. **의미는 같고 표현이 다릅니다** — 어느 쪽이 빠른지는 재지 않았습니다.

### 4-3. 같은 중간 결과 재사용 — StarRocks만 가능하다

같은 중간 결과를 두 번 참조하는 조회를 던지고, 원본 테이블을 **몇 번 읽는지** 셌습니다.

| 설정 | lineitem 읽기 횟수 |
|---|---|
| Trino 483 | **2회** |
| StarRocks 기본값 | **2회** |
| StarRocks, 재사용 강제(`cbo_cte_reuse_rate = 0`) | **1회** + 결과를 두 곳에 나눠주는 단계 |

**주목할 점이 둘입니다.**

첫째, **StarRocks도 기본 설정에서는 2회 읽었습니다.** 시험 데이터가 작아서(6만 건) 다시 계산하는 편이 싸다고 판단한 것입니다. 참조를 3회로 늘려도 마찬가지였습니다.

둘째, 강제했을 때는 **1회로 줄고 결과를 두 소비자에게 나눠주는 단계가 생겼습니다.** 기능이 실재함을 확인했습니다.

**따라서 이번에 확인된 것은 "능력이 있다"까지입니다.** 기본 설정에서 자동으로 재사용을 고르는 데이터 규모는 확인하지 못했습니다.

### 4-4. 순위 조회 — 유리한 조회문 모양이 서로 어긋난다

| 조회문 모양 | Trino | StarRocks |
|---|---|---|
| 그룹별 상위 3건 (`순위 <= 3`) | 순위 계산 **없앰** | 미리 잘라내고 순위 계산 **유지** |
| 순위 매기고 그냥 `LIMIT 5` | 상위 5건 추출로 변환 — **전체 정렬 없음** | **6만 건 전체 정렬** 후 5건 |
| 순위 매기고 `ORDER BY 순위 LIMIT 5` | **전체에 순위 계산** 후 5건 | 순위 계산 **앞에 미리 잘라냄** |
| 같은 기준의 순위 함수 2개 | 순위 계산 단계 **1개** | 순위 계산 단계 **2개** |

**두 번째와 세 번째가 정확히 뒤집혀 있습니다.** 3-4에서 본 대로 StarRocks의 규칙은 `ORDER BY 순위컬럼 LIMIT n` 형태를 노리고, Trino는 그냥 `LIMIT n` 형태를 처리합니다.

**같은 의미의 조회문을 어떻게 쓰느냐에 따라 유리한 제품이 바뀝니다.**

---

## 5. 실무에서 의미 있는 차이

### (1) 이식할 때는 성능보다 "돌기는 하는가"를 먼저 봐야 한다

| | Trino | StarRocks |
|---|---|---|
| 처리 못 하는 중첩 조회 | 오류로 거부 | 오류로 거부 |
| 못 하는 형태 | `ORDER BY` 없는 `LIMIT 1`, **EXISTS 안의 집계+HAVING** | `ORDER BY` 없는 `LIMIT 1`, **`ORDER BY … LIMIT 1`** |

**두 제품 사이에서 조회문을 옮길 때, 실패는 "느려짐"이 아니라 "오류"로 나타납니다.**

다행히 이는 **눈에 잘 띄는 실패**입니다 — 조용히 틀린 결과가 나오는 게 아니라 명확한 오류 메시지가 나옵니다. 이식 계획에는 **대상 조회문을 전수 실행해보는 단계**를 반드시 넣어야 합니다.

우회 방법도 확인됐습니다. `LIMIT 1` 이 필요한 중첩 조회는 **`ORDER BY` 를 덧붙이면 Trino에서는 통과합니다.**

### (2) 같은 중간 결과를 여러 번 쓰는 가공 작업

| | Trino | StarRocks |
|---|---|---|
| 3회 참조하는 조회 | **3번 계산** | 비용에 따라 1번 또는 3번 |
| 강제 수단 | 없음 | `cbo_cte_reuse_rate = 0` |
| 대안 | 임시 테이블을 직접 만들어 참조 | — |

**데이터 가공 작업에서 무거운 중간 결과를 여러 번 참조한다면 이 차이가 처리 시간에 직결됩니다.** Trino에서는 임시 테이블을 만들어 참조하는 수동 작업이 필요하고, 그러면 작업 단계가 늘고 정리 책임도 생깁니다.

다만 **StarRocks도 자동으로 재사용을 고르는 것은 아닙니다**(4-3). 데이터가 충분히 커야 비용 판단이 재사용 쪽으로 기웁니다.

### (3) 순위 조회는 조회문 쓰는 방식이 제품마다 다르다

| 원하는 것 | Trino에 유리한 표현 | StarRocks에 유리한 표현 |
|---|---|---|
| 순위 상위 n건 | `... ) t LIMIT n` | `... ) t ORDER BY 순위 LIMIT n` |

**두 제품을 함께 쓰는 환경이라면 이 차이를 알고 조회문을 작성해야 합니다.** 표준 SQL 관점에서는 둘 다 정당한 표현이고, 어느 쪽도 틀리지 않았습니다.

---

## 6. 아직 확인하지 못한 것 (한계의 명시)

| 항목 | 왜 못 했나 | 필요한 것 |
|---|---|---|
| **어느 쪽이 실제로 빠른가** | 조회 계획과 성공 여부만 비교했고 시간은 재지 않았습니다 | 메모리 24GB 이상 장비 + 100배 이상 데이터 |
| **중간 결과 재사용이 자동으로 선택되는 규모** | 시험 데이터가 6만 건이라 항상 "다시 계산"이 이겼습니다. 강제했을 때만 확인됐습니다 | 훨씬 큰 데이터 |
| **재사용의 실제 이득** | 서버 1대 환경에서는 서버 간 데이터 전송 비용이 0으로 계산되어 이득 구조가 드러나지 않습니다 | 서버 3대 이상 구성 |
| **중첩 조회 15가지가 전부인가** | 대표 형태만 골랐습니다. 실제 이식에서는 대상 조회문을 직접 돌려봐야 합니다 | 이식 대상 조회문 전수 시험 |
| **재귀 조회** | 확인하지 않았습니다 | 별도 시험 |
| **StarRocks의 "중첩 조회 → 순위 함수 변환" 기능** | 소스에는 존재하나 이번 시험의 어떤 조회로도 발동시키지 못했습니다. 발동 조건 미확인 | 추가 조사 |

**이번 보고는 "어떤 형태를 처리할 수 있고 어떻게 바꾸는가"이며, "어느 쪽이 더 빠른가"가 아닙니다.**

---

## 7. 참고

| 구분 | 위치 |
|---|---|
| 상세 기술 문서 | `docs/A-2-05-서브쿼리와-CTE.md` |
| 실험 기록 | `docs/evidence/A-2/20260904-subquery-cte-window-probes.md` |
| 앞선 보고서 | `docs/report/01` ~ `docs/report/04` |
| 전체 진행 현황 | `docs/00-목차.md` |

- Trino 483 소스: https://github.com/trinodb/trino/tree/483
- StarRocks 4.0.14 소스: https://github.com/StarRocks/starrocks/tree/4.0.14
