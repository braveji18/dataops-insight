# broadcast 허용 게이트: Trino는 빌드측 바이트, StarRocks는 양측 비교 + 행 수

> 비교 축: A-2 옵티마이저 / 조인 분배 방식 (`plan/01-비교항목-정리.md`)
> 본문: `docs/A-2-02-조인-분배-방식.md`
> 일자: 2026-08-31

### 주장

두 엔진 모두 broadcast/shuffle을 비용으로 고르지만, **broadcast를 후보로 허용할지 판단하는 게이트가 다르다.**

1. Trino의 게이트는 **빌드측만** 본다 — 빌드측 출력 크기(투영된 컬럼 기준) 또는 소스 테이블 크기가 `join_max_broadcast_table_size`(기본 100MB) 이하면 허용. 프로브측 크기는 게이트에 관여하지 않는다.
2. StarRocks의 게이트는 **양측 비교와 BE 수까지** 본다 — `left < right × beNum × broadcast_right_table_scale_factor(10)` **그리고** `right 행 수 > broadcast_row_limit(1500만)` 일 때만 거부한다. 즉 오른쪽이 훨씬 작으면 **행 수 제한이 적용되지 않는다**.

### 판별 쿼리

```sql
-- 빌드측이 아주 작은 조인 (supplier 81행). 게이트 차이가 드러나는 조건.
SELECT count(*) FROM lineitem l, supplier s WHERE l.l_suppkey = s.s_suppkey

-- 빌드측이 중간 크기인 조인 (orders 15000행)
SELECT count(*) FROM lineitem l, orders o WHERE l.l_orderkey = o.o_orderkey
```

각 엔진의 게이트 임계값만 바꿔가며 같은 쿼리의 분배 방식을 관찰했다. 임계값 하나로 결과가 바뀌면 원인이 게이트임이 확정된다.

### 결과

**기본 설정 — 같은 쿼리, 같은 데이터에서 결론이 갈린다**

| 쿼리 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| `lineitem ⋈ supplier` (빌드 81행) | REPLICATED | BROADCAST |
| `lineitem ⋈ orders` (빌드 15000행) | **REPLICATED** | **PARTITIONED** |

`orders` 조인에서 Trino는 broadcast를, StarRocks는 shuffle을 골랐다. 이것은 게이트 차이가 아니다 — StarRocks에서 `[broadcast]` 힌트를 주면 broadcast 플랜이 나오므로 **후보로는 허용돼 있었고, 비용 모델이 shuffle을 골랐다.**

**Trino — 게이트는 빌드측 출력 크기(투영 컬럼만)**

`lineitem ⋈ supplier` 에서 `join_max_broadcast_table_size` 만 바꿨다.

| 임계값 | 결과 |
|---|---|
| 100B | PARTITIONED |
| 500B | PARTITIONED |
| **1kB** | **REPLICATED** |
| 10kB | REPLICATED |

경계가 500B~1kB 사이다. supplier 81행 × bigint 8바이트 = **648바이트** — 조인 키 `s_suppkey` 하나만 투영한 크기와 정확히 일치한다. 게이트가 테이블 전체가 아니라 **빌드측 출력 크기**를 본다는 뜻이다(`canReplicate` 의 첫 항).

`lineitem ⋈ orders` 는 같은 1kB 에서 PARTITIONED 로 바뀌었다 — orders 15000행 × 8바이트 = 12만 바이트로 1kB 를 넘기 때문이다.

**StarRocks — 행 수 제한은 조건부다**

`lineitem ⋈ supplier` 에서 `broadcast_row_limit` 만 바꿨다.

| 설정 | 결과 | 해석 |
|---|---|---|
| 기본(15000000) | BROADCAST | |
| **1** | **BROADCAST** | 81 > 1 인데도 유지 — `left < right × beNum × 10` 이 거짓이라 AND 가 성립하지 않는다 |
| 0 | PARTITIONED | `<= 0` 이면 broadcast 전면 비활성 |

행 수 제한을 1로 낮춰도 broadcast가 유지된다. **"오른쪽이 훨씬 작으면 행 수 제한을 무시한다"는 탈출구가 실제로 동작한다.** 0으로 두면 그제서야 꺼진다.

### 판정

**동등하지 않다 — 게이트의 축이 다르다.** 우열이 아니다.

- Trino: **바이트 기준, 빌드측 단독 판단.** 프로브측이 아무리 커도 게이트 결과는 같다
- StarRocks: **행 수 기준, 양측 상대 크기 + BE 수 반영.** 클러스터 규모가 커지면 `beNum` 이 커져 broadcast가 더 관대해진다

기본 설정에서 결론이 갈린 `lineitem ⋈ orders` 는 게이트가 아니라 **비용 모델**의 차이다. 어느 쪽 추정이 맞는지는 이 실험으로 판정할 수 없다.

**한정** — BE 1대 / worker 1대 환경이다. StarRocks 게이트에는 `beNum` 이 곱해지므로 **다중 BE 환경에서는 결과가 달라질 수 있다.** 이 랩으로는 검증 불가다. 실행 시간 비교도 하지 않았다(SF 0.01, `perf` 필요).

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대,
명시한 세션 변수 외 기본값, 시드 시 양쪽 ANALYZE 수행됨.
