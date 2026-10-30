# Trino 483 / 484 릴리스 노트 정리

- 원문 483: https://trino.io/docs/current/release/release-483.html
- 원문 484: https://trino.io/docs/current/release/release-484.html

---

## Trino 483 (2026-07-17)

**핵심 테마: SQL 기능 확장(PIVOT·JSON·지리공간), 새 Web UI 기본화, S3 인증 설정 방식 변경**

### General (SQL/엔진)

- `PIVOT` 절 지원 — 행 값을 열로 변환 (#29404)
- `json` 컬럼용 **JSON simplified accessor** 문법 (`j.customer.name`, `j.items[0].price.decimal(18,2)`), `SELECT j.*` 지원 (#29565)
- `OVERLAPS` 프레디킷(두 기간의 겹침 여부) (#29652)
- SQL/JSON path의 `datetime()` 메서드 (#29603)
- `title_case()` 함수 추가 (#2942)
- 지리공간 대폭 확장 (#29737)
  - `ST_Transform()` / `ST_TransformXY()` — 좌표계 변환
  - 3D 포인트: `ST_Point` 3·4인자 오버로드, `ST_Z()`, `ST_Force2D()`, `ST_Force3D()`
  - `ST_GeomFromEWKT()`
  - `ST_PointOnSurface()`, `ST_MakePolygon()`, `ST_Multi()`, `ST_LineMerge()`, `ST_Normalize()`, `ST_ReducePrecision()`, `ST_VoronoiPolygons()`, `ST_MinimumBoundingCircle()`, `ST_OrientedEnvelope()`
  - `ST_Collect()`, `ST_MakeLine()`, `ST_Polygonize()`, `geometry_collect_agg()` 집계
  - SRID·Z좌표 메타데이터 보존
- Azure exchange spooling HTTP 커넥션 풀 튜닝: `exchange.azure.max-connections`, `exchange.azure.pending-acquire-max-count`, `exchange.azure.connection-acquisition-timeout` (#30083)
- 성능
  - `CAST(...) BETWEEN 리터럴` 최적화 (#14648)
  - IF/CASE 모든 분기에 공통 등식이 있는 조인 최적화 (#30288)
  - bigint/integer/date 조인 키 동적 필터링 워커 메모리 절감 (#30321)
- 버그 수정
  - `NOT BETWEEN` + cast 결과 오류 (#30073)
  - 비결정적 표현식을 `date`로 캐스트 후 리터럴 비교 시 결과 오류 (#30286)
  - right/full outer join 결과 오류 및 `MERGE` 실패 (#30278)
  - 64개 이상 필드 row constructor 필터 실패 (#30279)
  - 행 크기 편차가 큰 결과 spooling 실패 (#30112)
  - FTE에서 소형 페이지 처리 실패 (#23531)
  - cast/날짜 함수 vs 리터럴 비교 시 옵티마이저 타임아웃 (#30347)
  - 카탈로그 로드 실패 시 `SHOW SESSION` 등 메타데이터 쿼리 실패 (#30086)
  - `theta_sketch_union()` 명시 인자 호출 실패 (#29725)

### Security

- OAuth 2.0 SSO를 특정 도메인으로 제한: `http-server.authentication.oauth2.domain-hint` (#30272)

### Web UI

- 진행률 기준 쿼리 목록 정렬 (#30350)
- ⚠️ **Breaking**: `/ui/preview`의 새 Web UI가 `/ui` 기본값으로 승격. 기존 UI는 `/ui/legacy`로 이동, 기본 비활성 (`web-ui.legacy.enabled=true`로 복구) (#22697)
- preview UI 쿼리 상태 필터 체크박스 수정 (#30078)

### JDBC driver

- 결과 읽기 중 오류 시 무한 대기 방지 (#30007)

### CLI

- `--theme` 옵션으로 컬러 테마 출력 (#6190, #30265)

### 오브젝트 스토리지 커넥터 공통 (Delta Lake / Hive / Hudi / Iceberg / Lakehouse)

- `s3.auth-type` 속성 추가 (`ANONYMOUS`로 퍼블릭 버킷 읽기) (#27512)
- ⚠️ **Breaking**: `s3.iam-role` 사용 시 `s3.auth-type=IAM_ROLE` 필수 (#27512)
- ⚠️ **Breaking**: `s3.use-web-identity-token-credentials-provider` 제거 → `s3.auth-type=WEB_IDENTITY` (#27512)
- Parquet 쓰기 메모리 절감 (#30372)
- ORC `char` 컬럼 필터 결과 오류 수정 — Hive/Iceberg/Lakehouse (#30187)

### 커넥터별

- **Delta Lake**: 실패한 쓰기 후 deletion vector 고아 파일 방지 (#30342), Trino가 쓴 DV가 다른 리더에서 거부되는 문제 수정 (#30355)
- **Druid**: `druid.execution-timeout`으로 쿼리 취소 (#27150), 복합 필터 푸시다운 확대 (#4109)
- **Hive**: TEXTFILE/CSV 읽기 성능 개선 (#30291)
- **Hudi**: `hudi.max-split-size` (#29842), 읽기 성능 개선
- **Iceberg**
  - 암호화된 Parquet 읽기 (#28204)
  - materialized view의 `$files`/`$snapshots`/`$partitions` 메타데이터 테이블 조회 (#30218)
  - REST 카탈로그 `GOOGLE` 보안에서 `gcs.json-key-file-path` 선택 사항 → ADC 사용 가능 (#29084)
  - position delete 쓰기 메모리 절감 (#30081)
  - `NOT NULL` 컬럼에 NULL이 있으면 `OPTIMIZE` 실패시켜 테이블 손상 방지 (#30062)
  - HMS `CREATE TABLE` 커밋 실패 시 메타데이터 손실 수정 (#29973)
  - JDBC 카탈로그 무관 스키마 뷰 목록 오류 (#29738)
  - REST 카탈로그 등 location 자동 생성 카탈로그에서 `CREATE TABLE` 실패 (#26742)
  - Glue가 거부하는 문자(개행 등) 포함 컬럼 코멘트 실패 (#30353)
  - REST 카탈로그 SigV4 실패 (#30163)
- **Ignite** ⚠️ **Breaking**: JVM 옵션 `--add-opens=java.base/java.util=ALL-UNNAMED` 필수 (#30255)
- **Lakehouse**: 암호화 Parquet 읽기 (#28204) 외 공통 항목
- **SQL Server**: hidden column + `LIMIT` 실패 수정 (#30084)

### SPI

- 모든 블록 타입에 raw array/offset 접근자 노출 (#30128)
- ⚠️ **Breaking**: Block의 null 표현을 boolean 배열 → 비트팩 validity bitmap으로 변경. 블록 빌더 API 없이 직접 블록을 만드는 플러그인은 수정 필요 (#30185)

---

## Trino 484 (2026-10-15)

**핵심 테마: JSON 타입 대개편, INTERVAL 정밀도 확장, 클러스터 공용 파일시스템 캐시, Docker 이미지 변경, 대량의 정확성 버그 수정(특히 비결정적 표현식)**

### General — 신기능

- **JSON 대개편** (#30341)
  - JSON value constructor, `JSON_SERIALIZE`, `json_scalar()`
  - `JSON_EXISTS` / `JSON_VALUE` / `JSON_QUERY` / `JSON_TABLE`에 `json` 입력 허용
  - JSON 타입에 datetime 값 지원, `json` → `date`/`time` 캐스트
  - `JSON_VALUE ... RETURNING` 숫자, JSON path 산술·배열 첨자
  - `JSON_OBJECT ... WITH UNIQUE KEYS`에 `FORMAT JSON` 인자 허용
- **INTERVAL 확장** (#6754): 명시적 leading-field 정밀도, 소수점 이하 최대 12자리, datetime 뺄셈 시 필드 범위·정밀도 지정
- 윈도우 프레임 `EXCLUDE` 절 (#30226)
- **노드 단위 공용 파일시스템 캐시** — `cache-manager.config-files`, 모든 카탈로그 공유 (#29184)
- `CREATE VIEW IF NOT EXISTS` (#28076)
- materialized view에 `COMMENT` (#31279)
- `query.max-output-data-size` (#30615)
- `CALL` 프로시저 메트릭 반환 (#30749)
- DB 리소스 그룹 매니저에서 `NULL` environment = 모든 환경 매칭 (#30873)
- 다른 사용자가 쿼리를 중단하면 실패 메시지에 해당 사용자 표시 (#31603)
- 레거시 복구용: `legacy_varchar_to_char_coercion` 세션 속성 (#30708), `trino.geospatial.legacy-lenient-overlay` JVM 속성 (#30584)
- `trino-server-core` 실행 시 프로세스명 `trino-server` (#30403)

### General — ⚠️ Breaking changes

- **사용자 이름 대소문자 보존**: `GRANT`/`REVOKE`/`SET AUTHORIZATION`/`CREATE SCHEMA`에서 소문자 변환 안 함. `Alice`에게 준 권한은 `Alice`에게만 적용 (role은 여전히 소문자화) (#30567)
- `retry-policy=TASK`에서 spooled exchange 데이터 유실 시 1회 재시도 후 실패 (#31336)
- JSON (#30341)
  - `JSON_ARRAY`/`JSON_OBJECT`/`PASSING`에서 숫자를 JSON 숫자로 유지
  - array/map/row → json 캐스트 시 숫자 타입·decimal 스케일 유지
  - decimal 형태 JSON 숫자 → varchar 캐스트 시 decimal 표기 유지
  - `json_parse()`·JSON 리터럴에서 객체 멤버 순서·중복 키 보존
  - 중첩 깊이 1,024 초과 금지
  - 오버플로 지수 표기 숫자·짝 없는 Unicode 서로게이트 거부
  - `json` 인자를 문자열로 변환하지 않고 직접 사용 (`FORMAT JSON` 불필요)
  - `JSON_SERIALIZE` 예약어 → 식별자로 쓰려면 따옴표 필요
  - `json(x)` 호출은 함수로 쓰려면 qualification 필요
  - SQL/JSON 출력에서 `char` 패딩 누락 수정, decimal 정밀도 손실 방지, `json_array_get()` 문자열 추출 시 잘못된 JSON 수정 (#28861)
- INTERVAL (#6754)
  - day-time 최대 ≈292,000년으로 축소 (초과 시 오버플로 에러)
  - qualifier에 없는 필드 추출 금지
  - `hour(INTERVAL '36' HOUR)` = 36처럼 전체 leading field 반환
  - 곱셈·나눗셈 결과를 필드 범위로 절삭
- `ngrams()` 결과 1,000,000개 제한 (#30806)

### General — 성능

- boolean 처리(ORC/Parquet 읽기·쓰기) 개선 (#30299)
- dictionary-encoded 데이터 필터/프로젝션 (#30877, #31200), 재분배 메모리 절감 (#31056)
- `at_timezone()` 비교/필터 (#30597, #30551), `date_trunc()` week/quarter (#30192)
- 암시적 와이드닝 캐스트가 있는 `BETWEEN`/비교 (#31400), `CAST(...) IN (리터럴들)` (#31182)
- decimal ↔ double/real 캐스트 (#31475, #31481, #31502), decimal `avg()`+`sum()` 메모리 (#30595), decimal 윈도우 `sum()` (#30630)
- uncorrelated `EXISTS` (#30224), `LIMIT` 서브쿼리 cross join (#31128), `char` vs `varchar` 범위 비교 (#31089)
- `AND` 복합 필터 읽기 데이터 감소 (#30909), `optimizer.allow-unsafe-pushdown` 관련 (#30917)
- `retry-policy=QUERY`의 `ORDER BY` (#30966), FTE 메모리 고갈 시 무메모리 태스크 스케줄링 (#30678)
- 리터럴만 다른 반복 쿼리 (#30465), 많은 조인의 플래닝 성능 — `max_reordered_joins` 최대 62 (#31261)
- 조건식(CASE/IF)에서 조건 충족 시에만 필요한 컬럼 (#31473), 중첩 문자열 연결 (#31465)
- 연산자 많은 쿼리 워커 메모리 절감 (#31301), varchar 동적 필터링 메모리 절감 (#31303)

### General — 버그 수정 (주요)

- 비결정적 표현식 결과 오류: IF/CASE 분기 내 반복 조건 (#30509), IF/CASE/NULLIF 필터 (#30993), `OR`/`IN` (#31149), `DISTINCT` 집계 (#31151), CASE 집계 (#31121), `year()`/`date_trunc()` 비교 (#31086)
- 워커 메모리 누수/OOM: 태스크 종료 시 회계 누수 (#30472), 대형 right/full outer join (#30790), `DISTINCT`+`ORDER BY` 집계 (#31039), 로컬 exchange 버퍼링 (#31533), 태스크 출력 쓰기 실패 (#31334, #31353), 와이드 row `ORDER BY ... LIMIT`/`row_number()` (#31014), 커넥터 정리 실패 (#31532)
- 결과 오류: 윈도우 `sum(bigint)` 오버플로 → 실패 (#30600), char→varchar 조인 + 동적 필터링 (#30686), decimal(≤18)→real (#30130), `IN`/`NOT IN` + NULL (#31068), single-row full outer join (#30988), `LEFT JOIN ... ON true` 집계 (#30989), `char` trim/reverse/캐스트 (#31004, #31190), `date_diff()` DST·월/분기/년 (#31543), `to_unixtime()`/`from_unixtime()` 반올림 (#31386), 1970 이전 timestamp→time (#31344), timestamp 최대/최소 근처 (#31564), 가변 오프셋 `ROWS` 프레임 (#31420), `max_by`/`min_by` with count (#31193, #31383), simple CASE NULL/NaN 피연산자 (#31065, #31081, #30992), `IS NOT DISTINCT FROM` cast vs 상수 (#31084), `IN` real NaN·시간대 (#31069, #31080), timestamp→tstz 저정밀 캐스트 (#30496), GROUP BY NULL 키 + 다중 DISTINCT (#29095), `date_add()`/interval 덧셈 범위 초과 → 실패 (#31002), `AT TIME ZONE` ±14:00 초과 → 실패 (#9288), decimal `avg()` 범위 초과 (#30991)
- 안정성: 고동시성 워커 이탈 (#30627), 많은 stage/task 시 워커 무응답 (#21512), `USE` prepared statement (#30859), 대량 `OR` 플래닝 (#30709), 워커 재시작 시 completion event 누락·코디네이터 누수 (#30755), FTE `No committed attempts found` 간헐 실패 (#30411), spooling inline segment 결과 오류 (#31527), 힙 비율 합 100% 시 시작 실패 (#31552), 쿼리 완료 직후 클라이언트 폴링 CPU 과다 (#31431)
- 기타: `try()` + `nullif()`/`BETWEEN` (#30399), `try(mod(x,0))` (#31054), `TRY(array[i].field)` (#31008), `WITH SESSION` 카탈로그 세션 속성 (#31045), SQL UDF 끝 IF/CASE (#30582), 재귀 `WITH` + 테이블 함수 (#31053), `BETWEEN SYMMETRIC` 중첩 row (#31487), `MERGE_TARGET_ROW_MULTIPLE_MATCHES` bucketed 테이블 (#30639), `system.jdbc.columns` number data_type (#31184), 비ASCII 숫자 로케일 interval 포맷 (#31433), `information_schema.tables` 중복 행 (#31488), `variant` 값 GROUP BY/DISTINCT/집계 (#31387), `convex_hull_agg()` 무효 지오메트리 (#30584)
- 카탈로그 불가 시 에러 메시지에 자격증명 노출 방지 (#31538)

### Security

- OAuth 2.0 **client credentials flow** — `WWW-Authenticate`에 token endpoint·scope 포함 (#15836)
- file-based access control의 catalog/schema/table 패턴에 `{user}` 플레이스홀더 (#31205)
- OPA에 extra credentials 전달: `opa.identity.extra-credentials-keys` (#29302)
- Ranger: Kerberos principal ≠ 매핑 사용자명 시 인가 실패 (#29342), 따옴표 필요한 컬럼명 마스크 실패 (#31119)
- 세션 속성 매니저가 사용자가 설정 불가한 속성 기본값 설정 시 실패 (#31281)

### Web UI

- 워커 상태 페이지에서 스레드 스냅샷 캡처 (#30388)
- 쿼리 상세 페이지 쿼리 텍스트 줄 번호 (#31424)
- 쿼리 목록 전체 너비 사용 (#30352)
- 수정: 진행률 정렬 (#30528), 접힌 내비게이션 텍스트 겹침 (#31232), IPv6 zone ID 워커 주소 (#30905), TASK retry 진행률 표시 (#31336)

### JDBC driver

- OAuth 2.0 client credentials: `oauth2ClientId`, `oauth2ClientSecret`, `oauth2TokenEndpoint`, `oauth2Scope` (#15836)
- interval 12자리 소수 읽기 및 필드 범위·정밀도 보고 (#6754)
- `getTime`/`getTimestamp` 타입 불일치 시 `SQLException` (#5315)
- JSON 인코딩 결과 읽기 성능 개선 (#30375)
- 비ASCII 숫자 로케일에서 interval 읽기 실패 수정 (#31433)

### Docker image ⚠️

- **Breaking**: ppc64le 이미지 제거 (#30422)
- **Breaking**: Red Hat Hardened core runtime 기반 — `grep`, `dnf`, `useradd` 등 유틸리티 없음 (#30397)
- **Breaking**: `run-trino` 스크립트 제거 — 커스텀 `node.properties`는 `node.id=${ENV:HOSTNAME}` 설정 필요 (#30397)

### CLI

- OAuth 2.0 client credentials: `--oauth2-client-id`, `--oauth2-client-secret`, `--oauth2-token-endpoint`, `--oauth2-scope` (#15836)
- JSON 인코딩 결과 읽기 성능 개선 (#30375)
- pager에서 `q` 두 번 눌러야 종료되던 문제 수정 (#30965)

### 오브젝트 스토리지 커넥터 공통 (Delta / Hive / Hudi / Iceberg / Lakehouse)

- S3
  - `s3.checksum-algorithm` — CRC32/CRC32C/SHA1/SHA256 (#31523)
  - `s3.expect-continue-enabled=false` — expect-continue 거부하는 S3 호환 스토리지 (#30534)
  - `s3.chunked-encoding-enabled=false` — chunked encoding 미지원 스토리지 (#31524)
- ⚠️ **Breaking**: `alluxio` 캐시 설정(`fs.cache.directories`, `fs.cache.max-sizes`, `fs.cache.max-disk-usage-percentages`, `fs.cache.ttl`, `fs.cache.page-size`)은 카탈로그가 아닌 클러스터 공용 cache manager에서 설정. 카탈로그는 `fs.cache.enabled`만 (#29184)
- Parquet
  - 선택적 필터 성능 — `parquet.selected-positions-pushdown-enabled` (#30303)
  - 쓰기 성능 (#30502), `row` 컬럼 읽기 메모리 절감 (#31381)
  - 저카디널리티 데이터 소형 파일 문제 (#31291), legacy list 인코딩 중첩 배열 (#27766), `DELTA_LENGTH_BYTE_ARRAY` decimal(≤18) 결과 오류 (#31554)
- ORC
  - ZLIB 쓰기 네이티브 메모리 절감 (#31582)
  - 쓰기 메모리 회계 부족 OOM (#30771)
  - 대형 varchar/varbinary 후 null만 이어지는 stripe 읽기 실패 (#10113)
- sorted 테이블 쓰기 실패 시 OOM (#31018)

### 커넥터별

**Delta Lake**
- Databricks 18 LTS 지원 (#30935)
- deletion vector 테이블 `vacuum` (#22809)
- 해시 기반 디렉터리 레이아웃: `delta.object-store-layout.enabled` / `object_store_layout_enabled` (#24199)
- `optimize` 실행 메트릭 (#28999)
- UniForm 테이블 drop 금지 (#31083)
- 성능: 데이터 파일 쓰기 (#30502), MERGE/UPDATE/DELETE·DV 읽기 (#30976), 체크포인트 코디네이터 메모리 (#31354), 태스크 재시도 쓰기 (#31408)
- 수정
  - MERGE/UPDATE/DELETE 메모리 회계 (#29956)
  - `FOR TIMESTAMP AS OF` 오래된 버전 읽기 (#31057)
  - 전체 파일 DELETE / CORT 후 삭제 행 노출 (#30343)
  - 다른 엔진이 쓴 DV 테이블 체크포인트 데이터 손실 (#31252), 다른 엔진이 복원한 테이블 체크포인트 데이터 손실 (#30985)
  - NaN/무한·JSON decimal·offset 없는 timestamp 통계 체크포인트 실패 (#24029, #28532)
  - `OPTIMIZE` 후 다른 리더에서 중복 행 (#31253), DV 파일이 유일한 소형 파일일 때 `OPTIMIZE` 누락 (#29041)
  - sub-millisecond 통계 tstz 필터 (#31231)
  - `delta.enableDeletionVectors=false` 테이블 결과 오류 (#30685, #31396)
  - `table_changes` URI 인코딩 파티션 값 (#30952)
  - `variant` 컬럼 `metadata`/`value` 순서 (#31388)
  - `$partitions` DV 파티션 통계 (#31397), 다른 엔진 row 통계 체크포인트 (#31194)

**Hive**
- `last_column_takes_rest` 테이블 속성 — TEXTFILE/RCTEXT/SEQUENCEFILE (#30938)
- ⚠️ **Breaking**: `hive.storage-format` 기본값 ORC → **PARQUET** (#30818)
- ⚠️ **Breaking**: `$file_modified_time` UTC 반환 (#31239)
- 성능: Thrift metastore 다중 기존 파티션 쓰기 (#31020), `flush_metadata_cache` 파티션 테이블 (#31486)
- 수정: Glue Avro 스키마 불일치 (#30599), 파티션 쓰기 실패 시 통계 손실·느린 롤백 (#31020), UTC-adjusted timestamp + `hive.parquet.time-zone` 필터 (#31050), Hive view `IN` in JOIN 번역 (#31298), JSON 중복 키 (#29983)

**Hudi**
- pending clustering COW 테이블 읽기 실패 (#30855)
- JVM 시간대 ≠ UTC 시 UTC-adjusted timestamp 필터 (#31050)

**Iceberg**
- 신기능
  - `ALTER MATERIALIZED VIEW ... EXECUTE` — MV에 `optimize`/`expire_snapshots` (#21797)
  - `ALTER VIEW ... REFRESH` (#30954), MV `COMMENT` (#31279)
  - `unknown` 타입 컬럼 읽기 (#31525)
  - `optimize`의 `sorted_by` 파라미터 (#31274), `sorted_by` 중첩 필드 정렬 (#19620)
  - `gc_enabled` 테이블 속성 — 스냅샷 만료/고아 파일 제거/DROP TABLE의 파일 삭제 방지 (#31218)
  - `register_table`의 `metadata_location` 파라미터 (#31164)
  - BigLake: `iceberg.rest-catalog.server-assigned-table-location-enabled` (#30438)
  - AWS KMS 설정 — 암호화 Parquet: `aws.kms.region`, `aws.kms.endpoint`, `aws.kms.iam-role`, `aws.kms.access-key`, `aws.kms.secret-key` 등 (#30371)
  - REST 카탈로그: 기본 credential chain SigV4 (#25257), `iceberg.rest-catalog.max-retries` (#31073), `iceberg.rest-catalog.metrics-reporting-enabled` (#31075), `iceberg.rest-catalog.case-insensitive-name-matching.cache-max-size` (#30856), `iceberg.rest-catalog.snapshot-loading-mode=REFS` (#30612)
  - `iceberg.domain-compaction-threshold` — 1,000개 초과 discrete 값 프레디킷 (#31175)
  - `migrate` 추가 파일 수 / `drop_extended_stats` 제거 파일 수 보고 (#30749, #30768)
  - MERGE/UPDATE/DELETE 커밋 요약을 이벤트 리스너에 전달 (#30934)
- ⚠️ **Breaking**
  - `iceberg.rest-catalog.vended-credentials-enabled=true` 시 네이티브 FS(`fs.s3.enabled` 등) 필수 (#30634)
  - `GOOGLE` 보안: `gcs.json-key-file-path` 대신 `iceberg.rest-catalog.google-json-key-file-path` / `iceberg.rest-catalog.google-json-key` (#31240)
  - `iceberg.equality-deletes-blocks-hash-enabled` 제거 (#31286)
  - `$snapshots`/`$history`/`$metadata_log_entries`의 tstz를 UTC로 반환 (#31356)
- 성능: 다수 파일 커밋 코디네이터 메모리 (#30433), JDBC 카탈로그 뷰 목록 (#29751), 많은 컬럼/파일 테이블 플래닝 메모리 (#30675), 동시 DELETE 실패 감소 (#30850), REST OAuth 토큰 요청 감소 (#30816), Parquet column index (`parquet.use-column-index`) (#11000), REST 대소문자 무시 매칭 (#29382), ORC Bloom filter 범위 프레디킷 (#31175), v3 테이블 전체 행 삭제 시 파일 제거 (#31165)
- 수정
  - 메타데이터 테이블: 많은 컬럼 `$partitions` (#30311), 예약어 컬럼명 (#30488), 드롭된 파티션 필드 (#30247), 스냅샷 없는 테이블 (#30501), bucket/truncate 파티션 진화 (#31435), `$history` 잘못된 스냅샷·시간 (#31102)
  - MV refresh: 소스 수정/`FOR VERSION AS OF` 중복 행 (#30990), 동시 refresh 중복/유실 (#31257)
  - 메모리: equality delete (#29955), DV (#30876), UPDATE/DELETE/MERGE 많은 파일 (#31258)
  - equality delete 중첩 row 키 (#31376, #25720), `bucket(decimal)` 조인 (#31457)
  - TASK retry 커밋 재시도 중복 행 (#31246)
  - HMS/Glue `CREATE TABLE` 커밋 실패 메타데이터 손실 (#31211), Glue 중복 적용 에러 (#31213), HMS locking 비활성 동시 쓰기 (#27942), Glue 테이블 로드 실패 시 스키마 목록 누락 (#30926)
  - REST: 대소문자 무시 테이블/뷰 해석 (#30747), vended credentials로 DROP (#31217), Azure vended credentials SAS 토큰 (#29526)
  - `optimize_metadata_queries` + hidden column 필터 (#31103), JDBC 카탈로그 `SHOW CREATE SCHEMA` (#29769)
  - sorted 테이블 대형 varchar `OPTIMIZE`/쓰기 (#20164, #28636), null row/map 내 variant (#30613), Trino가 쓴 variant가 DuckDB 등에서 row로 읽힘 (#31388)

**Lakehouse**
- `system.sync_partition_metadata`, `system.vacuum` 프로시저 및 `optimize`, `expire_snapshots` 테이블 프로시저 (#26753, #26754)
- Iceberg `sorted_by` optimize, Delta `object_store_layout_enabled`, AWS KMS, S3 옵션 등 Iceberg/Delta/Hive 변경 대부분 포함
- ⚠️ Hive `PARQUET` 기본값, Iceberg REST GOOGLE 속성명, equality-deletes 속성 제거, alluxio 캐시 설정 이동 동일 적용
- `extra_properties` 뷰 속성 생성 실패 수정 (#31265)

**JDBC 계열 공통 (ClickHouse, DuckDB, Ignite, MariaDB, MySQL, Oracle, PostgreSQL, Redshift, SingleStore, Snowflake, SQL Server)**
- 쓰기 실패/취소 시 원격 임시 테이블 누수 수정 (#31333)
- MariaDB/MySQL/SingleStore/Snowflake/SQL Server: `IS NOT NULL` on char/varchar 푸시다운 성능 (#31060)
- Ignite/PostgreSQL: complex join pushdown 비활성 시 `IS NOT DISTINCT FROM` 조인 실패 (#31097)

**기타 커넥터**
- **BigQuery**: `location` 스키마 속성 (#30366), 쿼터 초과 쓰기 재시도 — `bigquery.write-retry-max-attempts` 등 (#30927), 20초 읽기 타임아웃 (#30840), 연결 누수 (#30834), 대소문자 무시 매칭 + drop/rename 후 모호성 (#31332)
- **Cassandra** ⚠️ **Breaking**: 4.0 이상 필수 (#28687)
- **ClickHouse**: `clickhouse.cluster-name`으로 클러스터 모드 DDL (#17307), Distributed 테이블 insert 중복·replicated insert 실패 (#7600, #7601)
- **Druid**: `__time` ORDER BY + LIMIT 성능 (#31277)
- **Elasticsearch**: `ORDER BY ... LIMIT`·count/sum/avg/min/max 푸시다운, alias 필터/라우팅, 백킹 인덱스 권한 없는 alias, 검색 타임아웃/shard 실패, `null_value`/`ignore_above`/`ignore_malformed` 매핑, 음수 0 결과 오류 수정 (#27251), 미지원 메타데이터 컬럼 목록 실패 (#30852)
- **Faker**: `timestamp(12)` min/max 값 생성 오류 (#31037)
- **Memory**: `TABLESAMPLE` + 다중 DISTINCT 집계 (#31203)
- **MySQL**: 많은 행 테이블 컬럼 메타데이터 성능 (#31283)
- **OpenSearch**: 미지원 메타데이터 컬럼 목록 실패 (#30852)
- **Oracle**: precision 없는 `NUMBER` `query` 테이블 함수 (#30467), char→varchar 푸시다운 + legacy coercion 결과 오류 (#30683)
- **Redshift**: `redshift.unload-location` + 동적 필터링 조인 실패 (#30209)
- **SQL Server**: 무응답 서버 스레드 행 (#30786), 대소문자/후행 공백만 다른 char/varchar 비교 (#30480)
- **TPC-DS** ⚠️ **Breaking**: SF ≤3000에서 식별자 컬럼 `bigint` → `integer` (#31589)

### SPI

- 추가: blob cache manager SPI (#29184), `Map<String, Long>` 메트릭 반환 프로시저 (#30749), `ConnectorMetadata.getMaterializedViewTableHandleForExecute()` (#30868), `createView(SaveMode)` — `replace` 플래그 버전 deprecated (#28076)
- Deprecated: `TrinoPrincipal.getName()` → `getPrincipalName()` (#30567)
- `DateTimeEncoding.packTimeWithTimeZone` / `LongTimeWithTimeZone`에서 ±14:00 초과 오프셋 금지 (#9288)
- ⚠️ **Breaking**
  - `BooleanType`이 `BitArrayBlock` 사용 — boolean 블록 직접 생성/읽기 플러그인 수정 필요 (#30299)
  - `DictionaryBlock.compact()` / `compactRelatedBlocks()` 반환형 `Block` (#30536)
  - `ConnectorPageSourceProvider.getMemoryUsage()` 제거, `createPageSourceProvider()`에 `MemoryContext` 추가 (#29955)
  - `createMergeSink()`에 `MemoryContext` 추가, 오버로드 제거 (#29956)
  - `TrinoPrincipal`, `RoleGrant` JSON 직렬화 제거 (#30610)
  - `finishMerge()` → `Optional<ConnectorOutputMetadata>` (#30934)
  - `WindowFunction.processRow`에 frame exclusion 파라미터 (#30226)
  - 네이티브 `json`은 `Slice` 대신 `io.trino.json.Json` (#30341)
  - `StandardTypes.INTERVAL_DAY_TO_SECOND` / `INTERVAL_YEAR_TO_MONTH` 상수값 변경, day-time interval 마이크로초 저장 — **플러그인 재컴파일 필요** (#6754)

---

## 통합 정리 (482 → 484 업그레이드 관점)

### 1. 반드시 확인할 Breaking changes

| 영역 | 변경 | 조치 |
|---|---|---|
| S3 인증 (483) | `s3.iam-role` 사용 시 `s3.auth-type=IAM_ROLE` 필수, `s3.use-web-identity-token-credentials-provider` 제거 | 카탈로그 파일에 `s3.auth-type` 명시 |
| Web UI (483) | 새 UI가 `/ui` 기본, 구 UI는 `/ui/legacy` + 비활성 | 필요 시 `web-ui.legacy.enabled=true` |
| 파일 캐시 (484) | alluxio 캐시 설정이 카탈로그 → 클러스터 공용 cache manager로 이동 | `cache-manager.config-files` 구성, 카탈로그엔 `fs.cache.enabled`만 |
| Hive 기본 포맷 (484) | `hive.storage-format` 기본 ORC → PARQUET | ORC 유지하려면 명시 설정 |
| 사용자명 대소문자 (484) | GRANT/REVOKE 등에서 대소문자 보존·구분 | 대문자 섞인 사용자 권한 재점검 |
| Docker (484) | Hardened 베이스(유틸리티 없음), `run-trino` 제거, ppc64le 제거 | 커스텀 이미지/entrypoint, `node.id=${ENV:HOSTNAME}` 확인 |
| JSON 의미 변경 (484) | 숫자 보존, 키 순서/중복 보존, 깊이·입력 검증 강화, `JSON_SERIALIZE` 예약어 | JSON 결과를 문자열 비교하는 쿼리 검증 |
| INTERVAL (484) | 최대 범위 축소, 필드 추출/연산 의미 변경 | interval 산술 쓰는 쿼리 검증 |
| 시간대 (484) | Hive `$file_modified_time`, Iceberg `$snapshots`/`$history`/`$metadata_log_entries` → UTC | 메타데이터 테이블 기반 리포트 확인 |
| Iceberg REST (484) | vended credentials 시 네이티브 FS 필수, GOOGLE 인증 속성명 변경, equality-deletes 속성 제거 | 설정 키 교체 |
| 기타 | Ignite JVM `--add-opens` (483), Cassandra 4.0+ (484), TPC-DS 식별자 integer (484), `ngrams()` 100만 제한 (484) | 해당 시 조치 |
| SPI | Block null 비트맵 (483), BooleanType 비트팩·MemoryContext·json·interval 변경 (484) | 커스텀 플러그인 재컴파일 및 코드 수정 |

### 2. 새로 쓸 수 있는 SQL 기능

- **483**: `PIVOT`, JSON simplified accessor (`j.a.b[0].c`), `OVERLAPS`, `title_case()`, 지리공간 함수 20여 개 (좌표계 변환, 3D, 집계)
- **484**: JSON value constructor·`JSON_SERIALIZE`·`json_scalar()`, SQL/JSON 함수의 `json` 입력, INTERVAL 고정밀도, 윈도우 `EXCLUDE`, `CREATE VIEW IF NOT EXISTS`, MV `COMMENT`, Iceberg `ALTER MATERIALIZED VIEW ... EXECUTE` / `ALTER VIEW REFRESH`

### 3. 운영/인증

- OAuth2: 483 도메인 제한(SSO) → 484 client credentials flow(서버·JDBC·CLI)로 M2M 인증 가능
- 484: `query.max-output-data-size`, 프로시저 메트릭, 리소스 그룹 NULL environment, 킬한 사용자 표시, file-based ACL `{user}`, OPA extra credentials
- CLI: 483 `--theme`, 484 OAuth2 옵션 + JSON 결과 읽기 성능

### 4. 레이크하우스 커넥터 흐름

- **Iceberg**: 483 암호화 Parquet 읽기 → 484 AWS KMS 설정, REST 카탈로그 옵션 대거 추가, v3 테이블 최적화, MV refresh 정합성 수정
- **Delta Lake**: 483 deletion vector 호환성 수정 → 484 DV 테이블 vacuum·성능·체크포인트 데이터 손실 수정 다수, Databricks 18 LTS. DV 쓰는 환경이면 484가 사실상 필수
- **Hive/Hudi/Lakehouse**: Parquet·ORC 공통 성능/메모리 개선 및 다수 정확성 수정 (legacy list, DELTA_LENGTH_BYTE_ARRAY decimal, UTC-adjusted timestamp 필터)

### 5. 정확성·안정성

- 두 릴리스 모두 outer join, cast+리터럴 비교, char 처리 결과 오류 수정이 이어짐
- 484는 특히 비결정적 표현식(IF/CASE/OR/IN/DISTINCT) 결과 오류와 워커 메모리 누수/OOM 수정이 대량 포함 — 안정성 측면에서 비중이 큰 릴리스
- JDBC 계열 커넥터 전반의 임시 테이블 누수 수정 (484)

### 6. 성능 요약

- **483**: cast+BETWEEN, IF/CASE 조인 조건, 동적 필터링 메모리, Parquet 쓰기 메모리
- **484**: boolean/dictionary 인코딩 전반, decimal 캐스트·집계·윈도우, 플래닝(조인 많은 쿼리, 리터럴만 다른 쿼리), Parquet selected-positions 푸시다운·column index, Iceberg/Delta 쓰기 및 커밋 메모리
