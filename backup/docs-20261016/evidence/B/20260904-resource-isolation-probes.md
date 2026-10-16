# 리소스 격리: 강제 지점이 다르다 — BE 스캔 안 vs 코디네이터 1초 폴링

> 비교 축: B-2 리소스 격리 (`plan/01-비교항목-정리.md`)
> 본문: `docs/B-2-01-리소스-격리.md`
> 일자: 2026-09-04

### 주장

`plan/01` 은 이 축을 **"Resource Groups(큐잉 수준) vs Resource Group(BE cgroup 실격리)"** 로 적었다. 두 가지를 확인한다.

1. StarRocks 가 정말 **cgroup** 으로 격리하는가
2. "큐잉 수준 vs 실격리" 라는 방향은 맞는가 — **실행 중인 쿼리를 실제로 멈추는가**

### 판별 1 — StarRocks 는 cgroup 을 쓰지 않는다

BE 소스 전체에서 `cgroup` 을 언급하는 파일은 **4개뿐**이고 전부 *읽기* 용도다.

```
be/src/runtime/exec_env.cpp
be/src/util/cpu_info.h
be/src/util/cpu_info.cpp
be/src/util/mem_info.cpp
```

유일한 실사용도 자기 컨테이너의 CPU 구성을 알아내는 데 쓴다.

```cpp
// Disable bind cpus when cgroup has cpu quota but no cpuset.
                              (!CpuInfo::is_cgroup_with_cpu_quota() || CpuInfo::is_cgroup_with_cpuset());
```
— `be/src/runtime/exec_env.cpp:450-452`

실제 격리는 **자체 스케줄러**다. `be/src/exec/workgroup/` 의 `PipelineExecutorSet` 이 그룹마다 **드라이버·스캔·커넥터스캔 실행기 묶음을 따로 두고 CPU 를 지정해 붙인다.**

```cpp
PipelineExecutorSet(const PipelineExecutorSetConfig& conf, std::string name, CpuUtil::CpuIds cpuids,
                    std::vector<CpuUtil::CpuIds> borrowed_cpuids);
```
— `be/src/exec/workgroup/pipeline_executor_set.h:50-51`

`borrowed_cpuids` 는 **그룹 간 CPU 빌려주기**다. cgroup 에는 없는 개념이다. 가중치는 vruntime 으로 돈다(`work_group.h:66` — `runtime_ns() { return _vruntime_ns * cpu_weight(); }`).

**따라서 `plan/01` 의 "BE cgroup 실격리" 는 틀렸다.** cgroup 이 아니라 **CPU 친화도 바인딩 + 가중 vruntime + 전용 코어 + 코어 대여**다.

### 판별 2 — 실행 중인 쿼리를 멈추는가

**StarRocks — 즉시 멈춘다.**

```sql
CREATE RESOURCE GROUP rg_probe TO (user='root')
WITH ('cpu_weight'='4','mem_limit'='0.2','concurrency_limit'='2','big_query_scan_rows_limit'='1000');
```

| 쿼리 | 결과 |
|---|---|
| `SELECT count(n_name) FROM nation` (25행) | **25** |
| `SELECT sum(l_quantity) FROM lineitem` (60,175행) | ✗ `exceed big query scan_rows limit: current is 60175 but limit is 1000: BE:10001` |

**BE 가 스캔하면서 행을 세다가 중단시켰다.** 오류 출처가 `BE:10001` 인 것이 근거다.

`count(*)` 로는 판별되지 않는다 — 메타데이터 최적화로 행을 읽지 않기 때문이다(`A-2-04` 3-7).

**Trino — 짧은 쿼리는 빠져나간다.**

`lineitem` 의 실제 물리 입력은 **1.34MB** 다. 그보다 훨씬 작은 한도를 걸었다.

| `query_max_scan_physical_bytes` | 결과 |
|---|---|
| 1GB | 1536127.0 |
| 100kB | **1536127.0** (통과) |
| 10kB | **1536127.0** (통과) |
| 1kB | **1536127.0** (통과) |

**1kB 한도에서도 1.34MB 를 읽고 성공했다.**

원인은 강제 방식이다. 한도 검사가 코디네이터의 **주기 루프**에서 돈다.

```java
try {
    enforceScanLimits();
}
...
}, 1, 1, TimeUnit.SECONDS);
```
— `core/trino-main/.../execution/QueryManager.java:127-140`

**1초마다 한 번 훑는다.** 1초 안에 끝나는 쿼리는 검사받지 않는다.

```java
limitOpt.ifPresent(limit -> {
    DataSize scan = query.getBasicQueryInfo().getQueryStats().getPhysicalInputDataSize();
    if (scan.compareTo(limit) > 0) {
        query.fail(new ExceededScanLimitException(limit));
    }
});
```
— `QueryManager.java:419-424`

이미 읽은 양을 사후에 보고 실패시키는 구조다 — **읽는 것을 막지 않는다.**

### 판별 3 — 리소스 그룹 한도의 성격

Trino 의 리소스 그룹 한도는 **다음 쿼리를 시작할지**만 정한다.

```java
if ((cpuUsageMillis >= hardCpuLimitMillis) || (memoryUsageBytes > softMemoryLimitBytes) || (physicalInputDataUsageBytes >= hardPhysicalDataScanLimitBytes)) {
    return false;
}

int hardConcurrencyLimit = this.hardConcurrencyLimit;
if (cpuUsageMillis >= softCpuLimitMillis) {
    // TODO: Consider whether CPU limit math should be performed on softConcurrency or hardConcurrency
    // Linear penalty between soft and hard limit
    double penalty = (cpuUsageMillis - softCpuLimitMillis) / (double) (hardCpuLimitMillis - softCpuLimitMillis);
    hardConcurrencyLimit = (int) Math.floor(hardConcurrencyLimit * (1 - penalty));
```
— `core/trino-main/.../execution/resourcegroups/InternalResourceGroup.java:1079-1088`

메서드 이름이 `canRunMore()` 다. **CPU 를 많이 쓴 그룹은 동시 실행 수가 선형으로 깎이고, 이미 도는 쿼리는 느려지지 않는다.**

### 판정

**`plan/01` 의 방향은 맞고 기법 귀속은 틀렸다.**

| | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 격리 기법 | **입장 통제** — `canRunMore()` 로 시작 여부 결정 | **자체 스케줄러** — CPU 친화도 바인딩 + 가중 vruntime + 코어 대여 (**cgroup 아님**) |
| 실행 중 강제 | 코디네이터 **1초 폴링** 후 실패 처리 | **BE 스캔 안에서 즉시 중단** |
| 짧은 쿼리 | **한도를 빠져나간다** (실측) | 빠져나가지 못한다 (실측) |
| 실행 중 쿼리 감속 | 없음 | 있음(가중 스케줄링) |

**"큐잉 수준 vs 실격리"라는 요약은 유효하다.** 다만 StarRocks 쪽 기법을 cgroup 이라고 적으면 안 된다.

**한정** — BE 1대 / worker 1대다. **경합이 없으므로 "가중치대로 CPU 가 나뉘는가"는 판별하지 못했다.** 확인한 것은 *한도가 실행 중에 강제되는가* 뿐이다. Trino 의 리소스 그룹은 랩에 구성돼 있지 않아 그룹 단위 큐잉 자체를 실측하지 못했다.

### 조건

profile=functional, TPC-H SF0.01, Iceberg(HMS 4.0.1 native + MinIO), Trino 483 / StarRocks 4.0.14,
host=linux/amd64 (Linux 6.8, 8 CPU, RAM 15.6GB), Trino worker 1대 / StarRocks BE 1대.
