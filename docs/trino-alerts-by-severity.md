# Trino 482 운영 알람 등급별 비교표

Trino 운영 가이드 11종을 교차 조사한 결과를 바탕으로, 알람을 P1(Critical) / P2(High) / P3(Warning)으로 분류한 문서입니다.

- 임계값 표기: **(⑪)** = PrestoDB 운영 가이드에 명시된 값, **(제안)** = 출처 가이드에 수치가 없어 제안한 시작값
- Trino 공식 문서를 포함해 대부분의 가이드는 메트릭 목록만 제공하고 임계값은 제공하지 않습니다.
- 메트릭 이름은 Trino 내장 OpenMetrics(`/metrics`) 이름 규칙 기준 추정치입니다. 배포 전 `curl -H 'X-Trino-User: monitor' http://<coordinator>:8080/metrics`로 실제 이름을 확인하세요.
- Prometheus 룰 구현은 같은 폴더의 `alert.rules.yml`을 참고하세요.

## 근거 가이드

| 번호 | 가이드 | 성격 |
|---|---|---|
| ① | Trino 공식 – Monitoring with JMX | 핵심 MBean 목록 (공식 기준) |
| ② | Trino 공식 – OpenMetrics | `/metrics` 수집 방법, 노출 범위 설정 |
| ③ | Datadog Trino integration | 69개 `trino.*` 메트릭 |
| ④ | Alibaba Cloud EMR – Trino metrics | 가장 넓은 메트릭 카탈로그 (TaskExecutor, Hive metastore 등) |
| ⑤ | Yandex Managed Service for Trino | 최소 핵심 세트 7종 |
| ⑥ | Starburst Enterprise – CloudWatch | 노드 OS 메트릭, GC (old-gen GC는 정상 시 0) |
| ⑦ | Acceldata Pulse | Coordinator/Worker 엔드포인트 체크 |
| ⑧ | REST API 기반 모니터링 가이드 | `/v1/info/state`, `/v1/status` 헬스체크 |
| ⑨ | AWS EMR – Trino scaling challenges | S3 503, small file, 과도 스캔 |
| ⑩ | Stackable Trino Operator | ServiceMonitor 기반 수집 |
| ⑪ | PrestoDB 운영 가이드 (참고) | 임계값 포함 알람 10종 (Presto 계열) |

## 등급 정의

| 등급 | 의미 | 대응 목표 | 알림 채널 (예) |
|---|---|---|---|
| **P1 Critical** | 서비스 중단 또는 임박 | 즉시 (on-call 호출) | PagerDuty / 전화 |
| **P2 High** | 성능 저하, 일부 쿼리 실패 | 30분~1시간 내 | Slack 긴급 채널 |
| **P3 Warning** | 추세 이상, 용량·튜닝 신호 | 업무 시간 내 | Slack 일반 / 티켓 |

## P1 – Critical

| 알람 | 메트릭 / 조건 | 임계값 · 지속 | 근거 |
|---|---|---|---|
| Coordinator 다운 | `up{role="coordinator"}`, `/v1/info/state` ≠ ACTIVE | `== 0`, 1분 (⑪) | ⑦⑧⑪ |
| Worker 대량 이탈 | `HeartbeatFailureDetector_ActiveCount` | 기대 노드 수 × 0.8 미만, 5분 (제안) | ①⑤⑧⑪ |
| 클러스터 메모리 고갈 | `ClusterMemoryPool_general` Free ÷ Total | < 10%, 10분 (제안) | ①③④⑤ |
| Coordinator heap 위험 | `HeapMemoryUsage.used` ÷ `max` | > 90%, 2분 (⑪) | ①④⑥⑦⑪ |

## P2 – High

| 알람 | 메트릭 / 조건 | 임계값 · 지속 | 근거 |
|---|---|---|---|
| OOM 쿼리 kill | `ClusterMemoryManager_QueriesKilledDueToOutOfMemory` | 10분 증가분 > 0 (제안) | ①④⑦ |
| 내부·외부 실패 급증 | `InternalFailures` + `ExternalFailures` | rate > 0 즉시 (⑪) 또는 실패율 > 5%, 10분 (제안) | ①③④⑤⑪ |
| 쿼리 큐 적체 | `QueuedQueries`, `WaitingForResourcesMaxAgeInSeconds` | > 20건, 5분 (⑪) / 최대 대기 > 300초 (제안) | ①④⑤⑧⑪ |
| GC 과다 | GC CollectionTime 증가율 | > 20% (⑪), old-gen GC > 0이면 조사 (⑥) | ④⑥⑪ |
| Worker heap 압박 | Worker `HeapMemoryUsage` 사용률 | > 85%, 15분 (제안) | ④⑦ |
| Spill 급증 | spilled bytes rate | > 약 5MB/s, 2분 (⑪) | ⑪ |
| Hive metastore 이상 | `ThriftHiveMetastore` GetTable 실패·지연 | 실패 > 0 또는 지연 baseline × 2 (제안) | ④⑪ |

## P3 – Warning

| 알람 | 메트릭 / 조건 | 임계값 · 지속 | 근거 |
|---|---|---|---|
| 리소스 부족 실패 | `InsufficientResourcesFailures` | rate > 0 (⑪) | ③④⑤⑪ |
| 지연 악화 | `ExecutionTime` P95 | > 60초, 5분 (⑪) / 지난주 동시간 × 2 (제안) | ①③④⑤⑪ |
| Worker 1대 이탈 | `up{role="worker"}` | `== 0`, 5분 (제안, ⑪은 1분) | ⑦⑧⑪ |
| Split 대기 증가 | `TaskExecutor` WaitingSplits / BlockedSplits / SplitQueuedTime | baseline × 2, 15분 (제안) | ③④⑪ |
| 메모리 누수 쿼리 | `ClusterMemoryManager_NumberOfLeakedQueries` | > 0 (제안) | ④ |
| 메모리 블록 노드 | `ClusterMemoryPool` BlockedNodes | > 0, 5분 (제안) | ③④ |
| S3 throttling | 로그 `503 Please reduce your request rate` | 발생 시 (제안, 로그 기반) | ⑨ |
| 디스크 사용률 | 노드 디스크 (spill/로그 경로) | > 80% (제안) | ⑥ |
| 예기치 않은 재시작 | JVM Uptime 리셋, `/v1/info` uptime | 리셋 감지 (제안) | ④⑧ |

## 운영 메모

- **UserError 실패는 알람에서 제외**: 문법 오류 등 사용자 실수라 노이즈가 큽니다. 대시보드로만 관찰합니다.
- **baseline 기반 P3 알람**: 처음 2~4주는 알림 없이 기록만 하고, 이후 임계값을 확정합니다.
- **추가 노출 설정 필요**: TaskExecutor, Hive metastore, leaked queries, GC, spill 메트릭은 기본 노출 범위에 없을 수 있으므로 `openmetrics.jmx-object-names`에 추가합니다. 예:

  ```properties
  openmetrics.jmx-object-names=trino.execution.executor:name=TaskExecutor|trino.plugin.hive.metastore.thrift:*|trino.spiller:*|java.lang:type=GarbageCollector,*|java.lang:type=Memory|java.lang:type=Runtime
  ```

- **Trino 482 관련**: 장기 운영 클러스터의 집계 쿼리 메모리 누적이 개선되었으므로 업그레이드 전후 heap baseline을 비교하고, Hive metastore 장애 시 back-off 재시도로 지연이 늘 수 있음을 감안합니다.

## 출처

- [Trino – Monitoring with JMX](https://trino.io/docs/current/admin/jmx.html)
- [Trino – OpenMetrics](https://trino.io/docs/current/admin/openmetrics.html)
- [Trino – Release 482](https://trino.io/docs/current/release/release-482.html)
- [Datadog – Trino integration](https://docs.datadoghq.com/integrations/trino/)
- [Alibaba Cloud EMR – Trino metrics](https://help.aliyun.com/zh/emr/emr-on-ecs/user-guide/trino-metrics)
- [Yandex Managed Trino – Metrics](https://docs.yandex.cloud/int/en/managed-trino/metrics.md)
- [Starburst – CloudWatch](https://docs.starburst.io/latest/aws/cloudwatch.html)
- [Acceldata Pulse – Trino alerts](https://docs.acceldata.io/pulse/user-guide/monitor-trino-with-pulse-alerts)
- [Monitoring Starburst/Trino with REST APIs](https://tshasankda.substack.com/p/monitoring-starburst-enterprisetrino)
- [AWS EMR – Common Trino scaling challenges](https://docs.aws.amazon.com/emr/latest/ReleaseGuide/emr-trino-common-issues.html)
- [Stackable – Trino monitoring](https://docs.stackable.tech/home/26.3/trino/usage-guide/monitoring/)
- [PrestoDB – Monitoring Presto at Petabyte Scale](https://prestodb.io/blog/2026/08/27/monitoring-presto-at-petabyte-scale-the-complete-guide-to-observability-prometheus-grafana-alerting/)
