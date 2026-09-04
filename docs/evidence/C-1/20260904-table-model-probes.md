# 테이블 모델 4종: 같은 입력에서 네 가지 다른 결과가 나온다

> 비교 축: C-1 StarRocks 전용 — 스토리지 계층 (`plan/01-비교항목-정리.md`)
> 본문: `docs/C-1-01-테이블-모델.md`
> 일자: 2026-09-04

### 주장

StarRocks 의 테이블 모델은 **저장 시점의 중복 처리 규칙**이다. Trino 에는 대응물이 없다 — Iceberg 테이블은 한 종류뿐이다.

네 모델(`DUPLICATE` / `UNIQUE` / `PRIMARY KEY` / `AGGREGATE`)에 **완전히 같은 입력**을 주면 서로 다른 결과가 나온다는 것을 확인한다. 그리고 `UNIQUE` 와 `PRIMARY KEY` 의 실질 차이가 무엇인지 가린다.

### 준비

네 테이블을 같은 스키마·같은 분산으로 만들었다.

```sql
CREATE TABLE t_dup (k INT, v INT, s VARCHAR(20)) DUPLICATE KEY(k) DISTRIBUTED BY HASH(k) BUCKETS 1;
CREATE TABLE t_uni (k INT, v INT, s VARCHAR(20)) UNIQUE    KEY(k) DISTRIBUTED BY HASH(k) BUCKETS 1;
CREATE TABLE t_pk  (k INT, v INT, s VARCHAR(20)) PRIMARY   KEY(k) DISTRIBUTED BY HASH(k) BUCKETS 1;
CREATE TABLE t_agg (k INT, v INT SUM, s VARCHAR(20) REPLACE) AGGREGATE KEY(k) DISTRIBUTED BY HASH(k) BUCKETS 1;
```

각 테이블에 같은 순서로 넣었다.

```sql
INSERT INTO <t> VALUES (1,10,'a'),(1,20,'b'),(2,5,'c');
INSERT INTO <t> VALUES (1,7,'z');
```

### 결과 1 — 같은 입력, 네 가지 결과

| 모델 | 조회 결과 |
|---|---|
| `DUPLICATE` | `(1,7,z) (1,10,a) (1,20,b) (2,5,c)` — **4행, 전부 보존** |
| `UNIQUE` | `(1,7,z) (2,5,c)` — **2행, 마지막 쓰기가 이긴다** |
| `PRIMARY KEY` | `(1,7,z) (2,5,c)` — **2행, 마지막 쓰기가 이긴다** |
| `AGGREGATE` | `(1,37,z) (2,5,c)` — **2행, `v` 는 `SUM`(10+20+7=37), `s` 는 `REPLACE`** |

**`AGGREGATE` 가 이 표에서 가장 특이하다.** 값 컬럼마다 집계 함수를 지정하고, 적재 시점에 그 함수로 합쳐 버린다. 원본 행은 남지 않는다.

### 결과 2 — `UNIQUE` 와 `PRIMARY KEY` 의 실질 차이

조회 결과가 같으므로 다른 축으로 갈라야 한다.

| 모델 | `UPDATE ... SET` | `DELETE` |
|---|---|---|
| `DUPLICATE` | ✗ `table t_dup does not support update` | ✅ |
| `UNIQUE` | ✗ `table t_uni does not support update` | ✅ |
| **`PRIMARY KEY`** | **✅** | ✅ |
| `AGGREGATE` | ✗ `table t_agg does not support update` | ✅ |

**`UPDATE` 를 지원하는 것은 `PRIMARY KEY` 뿐이다.** `DELETE` 는 네 모델 모두 된다(삭제 후 행 수: dup 3, uni 1, pk 1, agg 1).

### 결과 3 — 부분 컬럼 갱신

`PRIMARY KEY` 에서만 가능한 것을 하나 더 확인했다.

```sql
INSERT INTO t_pk VALUES (3,1,'x'),(4,2,'y');
SET partial_update_mode='column';
INSERT INTO t_pk (k,v) VALUES (3,555);      -- s 는 지정하지 않는다
```

| k | v | s |
|---|---|---|
| 1 | 7 | z |
| **3** | **555** | **x** |
| 4 | 2 | y |

**`s` 가 `'x'` 로 남았다.** 지정하지 않은 컬럼은 건드리지 않는다.

이것은 Iceberg 로 할 수 없는 일이다. Iceberg 에서 한 컬럼만 바꾸려면 **행 전체를 다시 써야** 한다(`A-5-04`).

### 결과 4 — 지속 인덱스가 기본이다

```
"enable_persistent_index" = "true"
```

`SHOW CREATE TABLE t_pk` 의 출력이다. `PRIMARY KEY` 모델은 키→행 위치 매핑을 **디스크에 유지되는 인덱스**로 관리한다(`be/src/storage/persistent_index.cpp`). 그래서 조회 때 병합할 필요 없이 곧바로 최신 행을 찾는다.

### 판정

**비교 대상이 아니다 — Trino 에 대응물이 없다.**

- Iceberg 테이블은 **한 종류**다. 중복 처리 규칙을 테이블 정의에 넣을 수 없다
- StarRocks 는 **저장 시점에 중복을 어떻게 다룰지**를 네 가지로 나눠 두었고, 그 선택이 조회 결과 자체를 바꾼다
- `PRIMARY KEY` 만이 `UPDATE` 와 **부분 컬럼 갱신**을 지원한다. `A-5-04` 에서 StarRocks 가 Iceberg 에 `UPDATE` 를 하지 못한 것과 대조하면, **"StarRocks 로 데이터를 고치려면 네이티브 테이블로 옮겨야 한다"** 는 결론이 실증된다

**한정** — BE 1대, 버킷 1개, 복제 1이다. 다중 복제·다중 버킷에서의 동작(특히 `PRIMARY KEY` 의 인덱스 분산)은 확인하지 못했다. 성능도 재지 않았다 — 어느 모델이 얼마나 빠른지는 이 실험의 범위 밖이다. `AGGREGATE` 의 다른 집계 함수(`MIN`/`MAX`/`BITMAP_UNION` 등)도 시험하지 않았다.

### 조건

profile=functional, StarRocks 4.0.14 네이티브 테이블(`native_probe` DB),
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), FE 1 + BE 1, `replication_num=1`, `BUCKETS 1`.
