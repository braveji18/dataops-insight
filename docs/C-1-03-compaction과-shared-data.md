# C-1 StarRocks 전용 (3) — compaction 과 shared-data

> 비교 축: `plan/01-비교항목-정리.md` C-1 "Compaction, shared-nothing vs shared-data(`be/src/storage/lake/*`)"
> 기준 버전: **Trino 483** / **StarRocks 4.0.14**
> 런타임 증거: 4절 (태블릿 구성 확인). 랩은 `shared_nothing` 이라 shared-data 는 코드 비교까지만
> 선행 문서: `docs/C-1-01-테이블-모델.md`, `docs/C-1-02-스토리지-포맷과-인덱스.md`, `docs/A-5-04-쓰기와-테이블-포맷-트랜잭션.md`
> 일자: 2026-09-04

---

## 1. 비교 관점

작은 파일이 쌓이면 조회가 느려진다. **모든 레이크하우스 엔진이 이 문제를 안고 있고**, 답이 갈린다.

- **Trino** — `ALTER TABLE ... EXECUTE optimize` 를 **사람이 실행한다**(`A-5-04` 2-2)
- **StarRocks** — BE 가 **자동으로 돌린다**

그리고 그 위에 두 번째 질문이 있다 — **데이터가 어디 사는가.** StarRocks 는 `shared_nothing`(로컬 디스크)과 `shared_data`(객체 스토리지) 두 모드를 갖는다. 후자는 **Trino 와 같은 배치 형태**다.

이 문서의 초점은 그래서 이렇다: **자동 compaction 이 무엇을 사고 무엇을 파는가**, 그리고 **shared-data 가 두 제품을 얼마나 가깝게 만드는가.**

---

## 2. StarRocks 구현

### 2-1. compaction 이 세 종류다

`be/src/storage/` 의 파일 구성이 그대로 드러낸다.

| 종류 | 대상 | 확인 주기 | 병합 대상 개수 |
|---|---|---|---|
| **Cumulative** | 최근 rowset 끼리 | **1초** | 5 ~ 500 |
| **Base** | 누적본과 기존 대형 rowset | **60초** | 5 ~ 100 |
| **Update** | `PRIMARY KEY` 모델 전용 | **10초** | 태블릿당 최소 120초 간격 |

```cpp
CONF_mInt32(base_compaction_check_interval_seconds, "60");
CONF_mInt64(min_base_compaction_num_singleton_deltas, "5");
CONF_mInt64(max_base_compaction_num_singleton_deltas, "100");
```
— `be/src/common/config.h:349-351`

```cpp
CONF_mInt32(cumulative_compaction_check_interval_seconds, "1");
CONF_mInt64(min_cumulative_compaction_num_singleton_deltas, "5");
CONF_mInt64(max_cumulative_compaction_num_singleton_deltas, "500");
```
— `config.h:359-361`

```cpp
CONF_mInt32(update_compaction_check_interval_seconds, "10");
CONF_mInt32(update_compaction_num_threads_per_disk, "1");
CONF_mInt32(update_compaction_per_tablet_min_interval_seconds, "120"); // 2min
```
— `config.h:375-377`

**2단 구조(cumulative + base)는 LSM 트리의 층 구조와 같은 발상**이다. 작은 것끼리 자주 합치고, 큰 것은 드물게 합친다. 매번 전체를 다시 쓰면 I/O 가 폭발하기 때문이다.

**`update_compaction` 이 따로 있는 이유**는 `C-1-01` 2-2 에서 본 `PRIMARY KEY` 의 삭제 벡터와 지속 인덱스 때문이다. 일반 병합과 달리 **인덱스를 함께 갱신**해야 한다(`local_primary_key_compaction_conflict_resolver.cpp` 가 그 충돌을 다룬다).

### 2-2. 자동이라는 것의 대가

```cpp
CONF_Int32(base_compaction_num_threads_per_disk, "1");
CONF_Int32(cumulative_compaction_num_threads_per_disk, "1");
CONF_mInt64(max_compaction_candidate_num, "40960");
```
— `config.h:354, 364, 370`

**디스크당 스레드 1개씩**으로 묶여 있다. 무한정 돌지 않게 하려는 제한이다.

그리고 이 작업은 **쿼리와 같은 프로세스에서 돈다.** `B-1-01` 3-1 에서 본 `MemTracker::Type` 에 `COMPACTION`, `COMPACTION_TASK`, `COMPACTION_STATE` 가 있는 이유가 여기 있다 — **compaction 이 쿼리와 메모리·CPU·디스크 I/O 를 다툰다.**

`B-1-01` 5-3 에서 "StarRocks 의 용량 계획은 쿼리만 봐서는 안 된다"고 적은 근거가 이것이다.

### 2-3. shared-data — 배치 형태를 바꾸는 스위치

```java
     * shared_data: means run on cloud-native
     * shared_nothing: means run on local
...
    public static String run_mode = "shared_nothing";
```
— `fe/fe-core/.../common/Config.java:2989-2994`

**기본값은 `shared_nothing`** 이다. `shared_data` 로 바꾸면 데이터가 객체 스토리지에 살고 BE 는 캐시를 가진 계산 노드가 된다.

전용 구현이 `be/src/storage/lake/` 에 **103개 파일**로 따로 있다. 같은 이름의 파일이 양쪽에 있다는 점이 구조를 말해 준다.

| 개념 | shared-nothing | shared-data |
|---|---|---|
| compaction | `storage/base_compaction.cpp` 등 | `storage/lake/compaction_scheduler.cpp`, `compaction_policy.cpp` |
| 쓰기 | `storage/delta_writer` | `storage/lake/delta_writer.cpp`, `async_delta_writer.cpp` |
| PK 인덱스 | `storage/persistent_index.cpp` | `storage/lake/lake_persistent_index.cpp`, `lake_local_persistent_index.cpp` |
| 부분 갱신 | `storage/rowset_column_update_state` | `storage/lake/column_mode_partial_update_handler.cpp` |

**즉 저장 계층 전체가 두 벌 있다.** 기능은 대응되지만 구현이 갈라져 있고, 이는 **유지보수 비용이자 두 모드의 기능 격차가 생길 수 있는 지점**이다.

저장 위치는 SQL 객체로 관리된다 — `StorageVolume`(`fe/fe-core/.../storagevolume/StorageVolume.java`), `CREATE STORAGE VOLUME` 문장(`A-1-01` 5-1 의 문장 목록에 있다).

---

## 3. Trino 쪽

### 3-1. compaction 은 사람이 실행한다

`A-5-04` 2-2 에서 본 프로시저 목록이다.

```
OPTIMIZE  OPTIMIZE_MANIFESTS  DROP_EXTENDED_STATS  ROLLBACK_TO_SNAPSHOT
EXPIRE_SNAPSHOTS  REMOVE_ORPHAN_FILES  ADD_FILES  ADD_FILES_FROM_TABLE
```
— `plugin/trino-iceberg/.../procedure/IcebergTableProcedureId.java`

`ALTER TABLE t EXECUTE optimize` 로 부르고, **아무도 부르지 않으면 아무 일도 일어나지 않는다.**

**이것은 결함이 아니라 필연이다.** Trino 워커는 상태가 없고 쿼리가 없을 때는 놀고 있다. "언제 어떤 테이블을 정리할지"를 판단할 주체가 없다 — 어느 코디네이터가, 어떤 카탈로그의, 어떤 테이블을 자기 책임으로 여겨야 하는가?

실무에서는 **외부 스케줄러**(Airflow 등)가 주기적으로 `EXECUTE optimize` 를 돌리는 형태가 된다.

### 3-2. shared-data 에 대응하는 것

Trino 는 **처음부터 shared-data 다.** 데이터는 객체 스토리지에 있고 워커는 계산만 한다. 별도 모드가 없다.

`B-3-01` 에서 본 파일 캐시가 StarRocks shared-data 의 로컬 캐시에 대응한다.

---

## 4. 실측

### 4-1. 태블릿 구성 확인

`C-1-02` 4-1 에서 만든 테이블(파티션 2 × 버킷 3)의 태블릿을 셌다.

```
SHOW TABLET FROM t_idx  →  6개
```

**파티션 × 버킷 = 태블릿**이 확인된다. compaction 은 이 태블릿 단위로 돈다.

### 4-2. 삭제도 적재 트랜잭션이다

`information_schema.loads` 를 보면 `DELETE` 가 적재 작업으로 기록된다.

| JOB_ID | LABEL | STATE | TYPE |
|---|---|---|---|
| 29702 | `delete_01a06ca0-...` | FINISHED | INSERT |
| 29701 | `delete_01a06ca0-...` | FINISHED | INSERT |
| 29700 | `insert_01a06c9f-...` | FINISHED | INSERT |

**`DELETE` 의 TYPE 이 `INSERT` 다.** 즉 삭제도 "삭제 표시를 적재하는" 트랜잭션이고, 실제 정리는 compaction 이 나중에 한다. `C-1-04` 에서 이어 다룬다.

### 4-3. 재지 못한 것

**compaction 이 실제로 도는 것을 관찰하지 못했다.** 삽입량이 적어(수십 행) 임계값(rowset 5개 이상)에 닿지 않는다. `SHOW PROC '/compactions'` 도 비어 있었다.

**shared-data 모드는 시험하지 못했다.** 랩이 `shared_nothing` 이고, 모드 전환은 클러스터를 새로 구성해야 한다.

---

## 5. 설계 차이와 그 원인

### 5-1. 요약

| 관점 | Trino 483 + Iceberg | StarRocks 4.0.14 |
|---|---|---|
| 파일 정리 | **사람/스케줄러가 실행** (`EXECUTE optimize`) | **BE 가 자동** |
| 종류 | 1종(+ 매니페스트·스냅샷·고아 파일 별도 프로시저) | **3종** (cumulative / base / update) |
| 주기 | 없음 | 1초 / 60초 / 10초 확인 |
| 자원 | 쿼리와 같은 클러스터(쿼리로 실행) | **쿼리와 같은 프로세스**(상시) |
| 데이터 위치 | **객체 스토리지 고정** | `shared_nothing`(기본) / `shared_data` 선택 |
| 저장 계층 구현 | 커넥터 하나 | **두 벌** (`storage/` + `storage/lake/` 103파일) |

### 5-2. 자동이 항상 나은가

**아니다. 예측 가능성과 맞바꾼 것이다.**

StarRocks 의 자동 compaction 은 **운영자가 신경 쓰지 않아도 조회 성능이 유지된다**는 큰 장점이 있다. `A-5-04` 6절에서 "StarRocks 만으로 Iceberg 를 운영하지 말라"고 한 이유가 정확히 이것의 부재였다.

그러나 대가가 있다.

- **언제 돌지 모른다.** 적재가 몰린 직후 compaction 이 함께 돌면 그 시간대 쿼리가 느려진다
- **쿼리와 자원을 다툰다**(`B-1-01` 5-3). 디스크당 스레드 1개로 묶어 두었지만 I/O 는 공유한다
- **끌 수 없다.** 정확히는 설정으로 조일 수 있으나, 끄면 파일이 무한히 쌓인다

Trino 쪽은 반대다 — **정리 시점을 완전히 통제할 수 있고**(새벽에 몰아서), 대신 **아무도 하지 않으면 아무 일도 일어나지 않는다.**

### 5-3. shared-data 는 두 제품을 가깝게 만든다

`shared_data` 모드의 StarRocks 는 배치 형태가 Trino 와 거의 같다 — 데이터는 객체 스토리지, 계산 노드는 캐시를 가진 상태 없는(에 가까운) 노드.

**그러면 `C-1-02` 5-2 에서 본 Tablet 의 이점은 어떻게 되는가?** 코드가 답한다 — `lake_local_persistent_index.cpp`, `lake_tablet_manager` 같은 파일이 있는 것으로 보아 **태블릿 개념은 유지하고 저장 위치만 옮긴다.** 즉 콜로케이트 조인 같은 이점은 남기려는 설계다.

**다만 검증하지 못했다.** 랩이 `shared_nothing` 이고, 이 모드에서 콜로케이트 조인이나 캐시 배정이 어떻게 되는지 확인할 수 없었다.

### 5-4. 저장 계층이 두 벌이라는 사실

`storage/` 와 `storage/lake/` 에 같은 개념의 파일이 나란히 있다는 것은 **두 모드가 코드를 크게 공유하지 않는다**는 뜻이다.

이는 **두 모드의 기능이 어긋날 수 있는 지점**이다. 예를 들어 `cloud_native_index_compaction_task.cpp` 는 lake 쪽에만 있다 — shared-data 전용 최적화이거나, 아직 shared-nothing 에 없는 것이거나 둘 중 하나다. **이 저장소의 얕은 클론으로는 판단할 수 없다.**

`A-5-03` 5-4 에서 본 "FE 매핑표와 BE 리더 지원 범위의 불일치"와 성격이 같다 — **같은 개념의 코드가 두 곳에 있으면 어긋난다.**

---

## 6. 결론

**비교가 아니라 부재다. 그리고 그 부재가 `A-5-04` 의 결론을 뒤집지는 않는다.**

- **compaction**: StarRocks 는 BE 가 자동으로, 3종으로 나눠 돌린다. Trino 는 사람이 `EXECUTE optimize` 를 부른다
- **대가**: StarRocks 는 예측 가능성을 잃고 쿼리와 자원을 다툰다. Trino 는 아무도 안 하면 아무 일도 안 일어난다
- **shared-data**: StarRocks 에 Trino 와 같은 배치 형태를 선택할 수 있는 모드가 있다. **기본은 `shared_nothing`** 이고, 저장 계층 구현이 **두 벌**이다
- **삭제도 적재 트랜잭션이다**(실측). 실제 정리는 compaction 이 나중에 한다

**실무 결론**

1. **StarRocks 의 자동 compaction 은 큰 운영 이점이지만 자원 계획에 포함해야 한다.** 적재가 몰리는 시간대에 쿼리가 느려지면 이것을 먼저 의심하라
2. **Trino + Iceberg 를 쓴다면 `EXECUTE optimize` 를 도는 스케줄을 반드시 만들어라.** 이것이 `A-5-04` 6절 결론의 실행 항목이다
3. **`shared_data` 모드는 별도 검토 대상이다.** 저장 계층 구현이 따로 있으므로 shared-nothing 의 경험과 동작이 다를 수 있다
4. **`PRIMARY KEY` 모델은 compaction 부담이 더 크다.** 전용 `update_compaction` 이 따로 도는 것이 그 증거다(`C-1-01` 의 쓰기 비용과 이어진다)

### 아직 답하지 않은 것

- **compaction 이 도는 것을 관찰하지 못했다.** 삽입량이 임계값(rowset 5개)에 못 미쳤다. 대량 적재를 반복해야 한다
- **compaction 이 쿼리에 미치는 실제 영향** — 5-2 의 우려를 측정하지 못했다. 적재와 조회를 동시에 걸어야 한다
- **shared-data 모드 전부** — 랩이 `shared_nothing` 이다. 모드 전환은 클러스터 재구성이 필요하다
- **두 저장 계층의 기능 격차** — 5-4 의 우려를 확인하지 못했다
- **Trino `EXECUTE optimize` 의 비용** — `A-5-04` 에서 실행은 확인했으나 대용량에서의 소요 시간·자원은 재지 않았다
- **compaction 이 인덱스를 어떻게 다루는가** — `C-1-02` 의 비트맵·n-gram 인덱스가 병합 시 재생성되는지 확인하지 않았다
