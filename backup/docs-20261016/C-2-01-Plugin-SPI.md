# C-2 Trino 전용 (1) — Plugin SPI

> 비교 축: `plan/01-비교항목-정리.md` C-2 "커넥터/함수/타입/이벤트리스너/접근제어/리소스그룹 SPI 전반"
> 기준 버전: **Trino 483** / **StarRocks 4.0.14**
> 런타임 증거: **없음** — 플러그인을 새로 만들어 보는 것은 이 저장소의 범위를 넘는다
> 선행 문서: `docs/A-5-01-커넥터-인터페이스와-추가-난이도.md`, `docs/A-1-03-함수-등록과-확장.md`, `docs/B-5-01-보안과-권한-모델.md`, `docs/B-6-01-관측성.md`
> 일자: 2026-09-04

---

## 1. 비교 관점

이 문서는 **앞선 여러 문서에서 각자 마주친 같은 사실을 한자리에 모은다.**

| 문서 | 그 문서가 본 SPI |
|---|---|
| `A-1-03` | `getFunctions()` — 함수 |
| `A-5-01`·`A-5-02` | `getConnectorFactories()` — 커넥터 |
| `A-4-02` | `getExchangeManagerFactories()` — 셔플 저장소 |
| `B-2-01` | `getResourceGroupConfigurationManagerFactories()` — 리소스 그룹 |
| `B-5-01` | `getSystemAccessControlFactories()` 외 인증 4종 |
| `B-6-01` | `getEventListenerFactories()` — 관측 |

**여섯 문서가 각기 다른 주제를 다루면서 전부 같은 인터페이스 하나를 만났다.** 그 인터페이스를 정면으로 보는 것이 이 문서다.

질문은 하나다 — **StarRocks 에 대응물이 있는가.**

---

## 2. Trino 구현

### 2-1. 확장점이 16개다

`Plugin` 인터페이스의 메서드 전부다.

```
getCatalogStoreFactories        getConnectorFactories
getBlockEncodings               getTypes
getParametricTypes              getLanguageFunctionEngines
getSystemAccessControlFactories getGroupProviderFactories
getPasswordAuthenticatorFactories  getHeaderAuthenticatorFactories
getCertificateAuthenticatorFactories  getEventListenerFactories
getResourceGroupConfigurationManagerFactories
getSessionPropertyConfigurationManagerFactories
getExchangeManagerFactories     getSpoolingManagerFactories
```

전부 `default` 구현이 빈 목록이다 — **필요한 것만 구현한다.**

성격별로 묶으면 이렇다.

| 갈래 | 확장점 |
|---|---|
| **데이터** | 커넥터, 카탈로그 저장소 |
| **표현** | 타입, 파라미터 타입, 블록 인코딩 |
| **계산** | 함수, 언어 함수 엔진 |
| **보안** | 접근제어, 그룹 제공자, 인증 3종(암호/헤더/인증서) |
| **운영** | 이벤트 리스너, 리소스 그룹, 세션 프로퍼티 관리자 |
| **실행 기반** | **교환 관리자**, 스풀링 관리자 |

**마지막 갈래가 특히 눈에 띈다.** `getExchangeManagerFactories()` 는 **셔플 데이터를 어디에 둘지**를 플러그인이 정한다는 뜻이다(`A-4-02` 3-1). 엔진의 실행 기반까지 교체 가능한 지점으로 열어 둔 것이다.

### 2-2. SPI 가 별도 모듈이고 규모가 크다

| | 값 |
|---|---|
| `core/trino-spi` 파일 수 | **558** |
| 줄 수 | **73,858** |
| 하위 패키지 | 20개 (`block`, `catalog`, `connector`, `eventlistener`, `exchange`, `expression`, `function`, `memory`, `metrics`, `predicate`, `procedure`, `resourcegroups`, `security`, `session`, `spool`, `statistics`, `transaction`, `type`, `variant`, `classloader`) |

**엔진 본체와 분리된 모듈이라는 사실이 계약의 성립 조건이다.** 플러그인은 `trino-spi` 에만 의존하고 `trino-main` 을 보지 않는다. 그래서 엔진 내부가 바뀌어도 플러그인이 깨지지 않는다.

### 2-3. 불안정한 부분을 명시한다

```java
public @interface Unstable {}
```
— `core/trino-spi/.../Unstable.java:36`

**26개 파일에서 쓰인다.** "이 부분은 릴리스 간 바뀔 수 있다"를 애노테이션으로 표시한다.

**계약을 지키겠다는 약속과 지키지 못할 부분을 함께 밝히는 방식**이다. 이것 자체가 SPI 를 공개 API 로 다룬다는 증거다.

### 2-4. 클래스로더가 격리한다

`spi/classloader/` 패키지가 있다. 플러그인마다 별도 클래스로더를 쓰므로 **플러그인끼리 라이브러리 버전이 충돌하지 않는다.** 61개 플러그인이 각자 다른 SDK 버전을 쓸 수 있는 이유다.

---

## 3. StarRocks 쪽

### 3-1. 플러그인 메커니즘은 있다 — 범위가 다르다

`fe/fe-core/.../plugin/` 에 `PluginMgr`, `PluginLoader`, `DynamicPluginLoader`, `PluginClassLoader`, `PluginZip` 이 있다. **동적 로딩과 클래스로더 격리까지 갖췄다.**

그러나 확장 가능한 종류가 셋뿐이다.

```java
    public enum PluginType {
        AUDIT,
        IMPORT,
        STORAGE;
```
— `fe/fe-core/.../plugin/PluginInfo.java:64-67`

실제 구현체는 `AuditPlugin` 하나다(`B-6-01` 3-1). `IMPORT`, `STORAGE` 는 열거형에 이름만 있다.

**즉 StarRocks 의 플러그인은 "감사 로그를 어디로 보낼까"를 위한 장치**이고, 커넥터·함수·타입·접근제어는 여기 들어가지 않는다.

### 3-2. 나머지 확장점의 대응 상황

| Trino 확장점 | StarRocks |
|---|---|
| 커넥터 | **없음** — `ConnectorType` 열거형에 박혀 있다(`A-5-01` 3-2) |
| 타입 | **없음** — `PrimitiveType` 열거형 + BE C++ 짝(`A-1-02` 3-1) |
| 함수 | **없음** — `functions.py` 코드 생성(`A-1-03` 3-2). UDF 는 별개 경로 |
| 접근제어 | **있음** — `ExternalAccessController` + Ranger(`B-5-01` 3-2) |
| 인증 | 부분 — LDAP/JWT/OAuth2 가 내장. 확장 인터페이스는 있으나 SPI 모듈은 아니다 |
| 이벤트 리스너 | **있음** — `AuditPlugin` |
| 리소스 그룹 | **없음** — SQL 객체로 관리(`B-2-01` 3-1) |
| 교환 관리자 | **없음** |
| 세션 프로퍼티 관리자 | **없음** |

**16개 중 셋만 대응된다**(접근제어, 이벤트, 인증 일부).

### 3-3. "없다"가 곧 열등은 아니다

공정하게 볼 지점이다. **리소스 그룹을 SQL 객체로 관리하는 것**(`B-2-01`)은 플러그인보다 운영이 편하다. 설정 파일도 플러그인 배포도 필요 없다.

마찬가지로 **함수를 코드 생성으로 관리하는 것**(`A-1-03`)은 FE 와 BE 의 계약을 단일 원본에서 만들어 어긋나지 않게 한다.

**즉 StarRocks 는 "확장 가능성"을 팔고 "일관성과 운영 편의"를 샀다.**

---

## 4. 실측

**없다.** 플러그인을 새로 만들어 보는 것은 이 저장소의 범위를 넘는다.

다만 **간접 증거는 앞선 문서들이 이미 제공했다.**

| 사실 | 어디서 확인했나 |
|---|---|
| Trino 플러그인 **61개**가 실제로 존재 | `A-5-01` 4절 |
| 그중 커넥터 **27개** + JDBC 계열 15개 | 이 문서 5-1, `A-5-02` 2-2 |
| StarRocks 커넥터는 **10종 열거형** | `A-5-01` 3-2 |
| StarRocks 는 함수 추가에 FE+BE 재빌드 필요 | `A-1-03` 5-1 |
| 양쪽 다 Ranger 연동 가능 | `B-5-01` 3-2 |

---

## 5. 설계 차이와 그 원인

### 5-1. 요약

| 관점 | Trino 483 | StarRocks 4.0.14 |
|---|---|---|
| 확장점 수 | **16** | **3**(그중 구현 1) |
| SPI 위치 | **별도 모듈** `trino-spi`(558파일 / 73,858줄) | 없음 — 엔진 코드 안 |
| 안정성 계약 | `@Unstable` 애노테이션으로 명시 | 없음 |
| 클래스로더 격리 | **있음** | 있음(플러그인 3종에 한해) |
| 실제 플러그인 | **61개** | 감사 플러그인 |
| 확장 가능한 것 | 데이터·표현·계산·보안·운영·실행 기반 | 감사(+접근제어는 별도 경로) |

### 5-2. SPI 를 별도 모듈로 둔 것의 의미

**`trino-spi` 는 Trino 의 제품 전략 자체다.**

플러그인이 엔진 본체를 보지 않으므로 **엔진 개발과 플러그인 개발이 분리된다.** 61개 플러그인 중 상당수는 그 데이터 소스를 잘 아는 사람들이 만들었지 Trino 코어 팀이 만든 것이 아니다.

`A-5-01` 이 "확장성 관점의 핵심 차이"라고 부른 것의 근거가 여기 있다 — **StarRocks 에 커넥터를 추가하려면 upstream 에 기여해야 하고, Trino 는 그럴 필요가 없다.**

### 5-3. 실행 기반까지 열어 둔 것

`getExchangeManagerFactories()` 와 `getSpoolingManagerFactories()` 는 다른 확장점과 성격이 다르다. 커넥터·함수·타입은 "데이터를 다루는 방법"이지만, **교환 관리자는 엔진이 스스로 쓰는 기반**이다.

이것을 SPI 로 뺀 덕분에 FTE 의 저장소가 로컬 디스크·S3·HDFS 로 갈라질 수 있었다(`A-4-02` 3-1). **엔진 내부까지 계약으로 만든 사례**다.

StarRocks 에 대응물이 없는 것은 자연스럽다 — 셔플이 메모리 스트리밍 전용이라 뺄 것이 없다.

### 5-4. 그래서 무엇을 팔았나

Trino 가 산 것은 **생태계**다. 판 것은 **일관성**이다.

- 커넥터마다 푸시다운 능력이 다르다(`A-5-02` 2-2 — `applyFilter` 18개, `applyJoin` 1개)
- 같은 SQL 이 카탈로그에 따라 다르게 동작한다
- 커넥터의 품질이 제각각이다(코어 팀이 다 관리하지 않는다)

StarRocks 가 산 것은 **일관성**이다. 판 것은 **생태계**다.

- 10종 소스에서 동작이 같다
- 대신 11번째 소스는 upstream 이 만들어 줘야 한다

**어느 쪽이 낫다고 말할 수 없다.** 붙일 데이터 소스가 계속 늘어나는 조직에는 Trino 가, 소스가 고정된 조직에는 StarRocks 가 맞는다.

---

## 6. 결론

**비교가 아니라 부재다 — StarRocks 에 대응하는 SPI 계층이 없다.**

- **확장점 16 대 3.** Trino 는 데이터·표현·계산·보안·운영·실행 기반을 전부 열었고, StarRocks 는 감사·적재·저장 세 종류(구현은 감사 하나)만 열었다
- **`trino-spi` 는 별도 모듈**(558파일 / 73,858줄)이고 `@Unstable` 로 계약의 예외까지 명시한다
- **StarRocks 도 플러그인 메커니즘 자체는 갖췄다** — 동적 로딩과 클래스로더 격리까지. 범위가 좁을 뿐이다
- **접근제어만은 대응된다** — 양쪽 다 Ranger 를 붙일 수 있다(`B-5-01`)

**실무 결론**

1. **커넥터를 직접 만들어야 하는 상황이라면 Trino 가 사실상 유일한 선택이다.** StarRocks 는 upstream 기여 외에 길이 없다
2. **사내 전용 함수·타입이 많다면 Trino 쪽 유지비가 낮다**(`A-1-03`)
3. **반대로 "우리는 Iceberg 와 MySQL 만 본다"면 SPI 의 이점이 전혀 없다.** 그 경우 StarRocks 의 일관성이 더 값지다
4. **SPI 의 존재가 품질을 보장하지는 않는다.** 커넥터마다 푸시다운 능력이 다르므로(`A-5-02`) 쓰려는 커넥터의 실제 구현 범위를 확인해야 한다

### 아직 답하지 않은 것

- **실측 전무.** 플러그인을 만들어 보지 않았다
- **SPI 안정성의 실제 강도** — `@Unstable` 이 26곳에 있다는 것은 알지만, 릴리스 간 실제 변경 빈도를 보지 않았다(얕은 클론이라 이력 조회가 어렵다)
- **플러그인 품질 편차** — 61개 중 어느 것이 잘 관리되는지 판단할 근거가 없다
- **StarRocks 의 `IMPORT`/`STORAGE` 플러그인 타입** — 열거형에 있으나 구현체를 찾지 못했다. 미래를 위한 자리인지 확인하지 못했다
- **커넥터 다양성 자체의 가치** — `C-2-02`
