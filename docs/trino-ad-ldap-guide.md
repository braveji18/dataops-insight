# Trino와 Windows AD LDAP 연동 정리

> 기준: Trino 공식 문서(current) 및 AD 표준 동작. 482 버전 전용 문서로 개별 검증한 내용은 아니며, 도메인 이름(`corp.example.com` 등)은 모두 예시입니다.

## 목차

1. [기본 설정 (단일 도메인)](#1-기본-설정-단일-도메인)
2. [여러 도메인 / 포리스트 구성](#2-여러-도메인--포리스트-구성)
3. [같은 포리스트인지 별도 포리스트인지 구분하는 방법](#3-같은-포리스트인지-별도-포리스트인지-구분하는-방법)
4. [AD가 referral을 반환하는 이유](#4-ad가-referral을-반환하는-이유)
5. [참고 자료](#5-참고-자료)

---

## 1. 기본 설정 (단일 도메인)

AD 통합 DNS 영역(예: `corp.example.com`)으로 도메인을 구성한 경우, Trino 쪽에 DNS zone 전용 설정은 없습니다. LDAP URL과 바인드 패턴에 그 도메인 이름을 쓰는 것이 핵심입니다.

### 1.1 `etc/config.properties` (coordinator)

```properties
http-server.authentication.type=PASSWORD
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/keystore.jks
http-server.https.keystore.key=<keystore 비밀번호>
internal-communication.shared-secret=<임의의 긴 문자열>
```

PASSWORD 인증은 HTTPS가 필수입니다. 앞단 로드밸런서에서 TLS를 종료한다면 `http-server.process-forwarded=true`를 사용합니다.

### 1.2 `etc/password-authenticator.properties`

```properties
password-authenticator.name=ldap
ldap.url=ldaps://corp.example.com:636
ldap.user-bind-pattern=${USER}@corp.example.com
ldap.ssl.truststore.path=/etc/trino/ldap-truststore.jks
ldap.ssl.truststore.password=<비밀번호>
```

- **`ldap.url`**: 특정 DC 호스트명(`dc01.corp.example.com`)이나 도메인 이름(`corp.example.com`)을 넣습니다. 도메인 이름은 DNS zone의 A 레코드를 통해 여러 DC로 분산됩니다.
- **`ldap.user-bind-pattern`**: AD는 UPN 형식(`${USER}@도메인`)이 가장 간단합니다. 여러 패턴은 `:`로 구분합니다.

### 1.3 그룹으로 접근을 제한할 때 (선택)

```properties
ldap.user-base-dn=DC=corp,DC=example,DC=com
ldap.group-auth-pattern=(&(objectClass=person)(sAMAccountName=${USER})(memberOf=CN=trino-users,OU=Groups,DC=corp,DC=example,DC=com))
```

DNS zone 이름 `corp.example.com`은 base DN에서 `DC=corp,DC=example,DC=com`으로 변환됩니다.

### 1.4 주의할 점

- **인증서 SAN**: `ldaps://corp.example.com`처럼 도메인 이름으로 접속하면 DC 인증서의 SAN에 그 도메인 이름이 있어야 합니다. DC FQDN만 들어 있으면 호스트명 검증에 실패하므로, DC FQDN을 URL에 쓰거나 인증서를 재발급해야 합니다.
- **truststore**: AD CA 루트 인증서를 넣어야 합니다.
  ```bash
  keytool -import -alias ad-ca -file ad-ca.cer -keystore ldap-truststore.jks
  ```
- **SRV 레코드**: Trino는 `_ldap._tcp.corp.example.com` 같은 SRV 레코드 자동 탐색을 하지 않고, `ldap.url`에 적은 호스트명만 조회합니다.
- **DNS 조회**: Trino 서버(Linux)의 `/etc/resolv.conf`가 AD DNS 서버를 가리켜야 zone 이름이 풀립니다. `nslookup corp.example.com`으로 확인합니다.
- **평문 LDAP(389)**: 테스트용으로만 `ldap.url=ldap://...:389`와 `ldap.allow-insecure=true`를 함께 씁니다.

### 1.5 확인

coordinator를 재시작한 뒤 다음으로 확인합니다.

```bash
trino --server https://trino.example.com:8443 --user alice --password
```

---

## 2. 여러 도메인 / 포리스트 구성

- **같은 포리스트 안의 여러 도메인**: Global Catalog 하나로 묶습니다. (방법 A)
- **별도 포리스트**: 인증기 파일을 포리스트마다 따로 둡니다. (방법 B)

### 2.1 방법 A: 같은 포리스트의 여러 도메인 (Global Catalog)

GC 포트(LDAPS 3269, 평문 3268)로 접속하면 DC 한 곳에서 포리스트 전체 사용자를 조회할 수 있습니다. 이 부분은 Trino 문서가 아닌 AD 일반 동작에 따른 구성입니다.

```properties
# etc/password-authenticator.properties
password-authenticator.name=ldap
ldap.url=ldaps://corp.example.com:3269
ldap.user-bind-pattern=${USER}@corp.example.com:${USER}@asia.corp.example.com:${USER}@emea.corp.example.com
ldap.ssl.truststore.path=/etc/trino/ldap-truststore.jks
ldap.ssl.truststore.password=<비밀번호>
```

바인드 패턴은 `:`로 구분해 여러 개를 쓸 수 있고, 로그인이 성공할 때까지 순서대로 시도됩니다.

그룹으로 제한하려면 다음을 추가합니다.

```properties
ldap.user-base-dn=DC=corp,DC=example,DC=com
ldap.group-auth-pattern=(&(objectClass=person)(sAMAccountName=${USER})(memberOf=CN=trino-users,OU=Groups,DC=corp,DC=example,DC=com))
```

- **그룹 유형**: GC에서는 다른 도메인 사용자의 `memberOf`에 유니버설 그룹만 확실히 보이므로, 허용 그룹은 유니버설 그룹으로 만드는 것이 안전합니다.
- **Referral**: GC 대신 636/389 포트로 포리스트 루트를 검색하면 AD가 하위 도메인으로 referral을 돌려줍니다. `ldap.ignore-referrals`는 기본값이 false라서 Trino가 이를 따라가려 하고, 해당 도메인을 DNS로 찾지 못하면 타임아웃이 납니다. GC를 쓰거나 `ldap.ignore-referrals=true`로 끕니다.

### 2.2 방법 B: 별도 포리스트 (인증기 여러 개)

`password-authenticator.config-files`에 설정 파일을 여러 개 지정하면 여러 패스워드 인증기를 함께 쓸 수 있습니다.

```properties
# etc/config.properties
http-server.authentication.type=PASSWORD
password-authenticator.config-files=etc/ldap-corp.properties,etc/ldap-partner.properties
```

```properties
# etc/ldap-corp.properties
password-authenticator.name=ldap
ldap.url=ldaps://corp.example.com:3269
ldap.user-bind-pattern=${USER}@corp.example.com
ldap.ssl.truststore.path=/etc/trino/ldap-truststore.jks
```

```properties
# etc/ldap-partner.properties
password-authenticator.name=ldap
ldap.url=ldaps://partner.local:636
ldap.user-bind-pattern=${USER}@partner.local
ldap.ssl.truststore.path=/etc/trino/ldap-truststore.jks
```

자격 증명은 나열한 순서대로 검증되며, 처음 성공한 인증기에서 접근이 허용되고 나머지는 호출되지 않습니다. 포리스트마다 URL, base DN, 그룹 필터, 서비스 계정을 따로 둘 수 있어서, 같은 포리스트라도 도메인별 조건이 다르면 이 방법이 더 깔끔합니다.

### 2.3 공통 주의사항

- **DNS**: Trino 서버가 모든 도메인의 zone 이름을 조회할 수 있어야 합니다. 포리스트가 다르면 DNS 서버도 보통 다르므로, Trino가 쓰는 DNS 서버에 조건부 전달자(conditional forwarder)나 stub zone을 구성합니다.
- **인증서**: 각 포리스트의 CA 루트 인증서를 truststore에 모두 넣고, URL에 쓴 이름이 DC 인증서 SAN에 있어야 합니다.
- **계정명 충돌**: 서로 다른 도메인에 같은 `sAMAccountName`이 있으면 Trino에서는 같은 사용자로 취급되고, 먼저 성공한 쪽으로 로그인됩니다. 충돌 가능성이 있으면 바인드 패턴을 `${USER}`로 두고 UPN 전체(`alice@asia.corp.example.com`)로 로그인하게 합니다.
- **잠금 정책**: 패턴이나 인증기가 여러 개면 틀린 비밀번호 한 번이 도메인마다 실패로 기록될 수 있습니다.
- **디버깅**: `etc/log.properties`에 `io.trino.plugin.password=DEBUG`를 넣으면 어느 패턴이나 서버에서 실패하는지 확인할 수 있습니다.

---

## 3. 같은 포리스트인지 별도 포리스트인지 구분하는 방법

가장 확실한 기준은 **포리스트 루트 도메인이 같은지**입니다. 두 도메인에서 각각 확인한 포리스트 루트가 같으면 같은 포리스트(방법 A), 다르면 별도 포리스트(방법 B)입니다.

### 3.1 PowerShell (DC 또는 RSAT 설치된 PC)

```powershell
Get-ADForest | Select-Object Name, RootDomain, Domains, GlobalCatalogs
```

- `Domains`에 대상 도메인이 모두 나오면 같은 포리스트입니다.
- 목록에 없는 도메인은 다른 포리스트입니다.
- `GlobalCatalogs`에 나온 서버가 방법 A에서 `ldap.url`에 쓸 수 있는 GC 서버입니다.

도메인별로 확인하려면 다음을 각 도메인에 대해 실행해 `Forest` 값을 비교합니다.

```powershell
Get-ADDomain -Server asia.corp.example.com | Select-Object DNSRoot, Forest, ParentDomain
```

### 3.2 트러스트 유형으로 구분

```powershell
Get-ADTrust -Filter * | Select-Object Name, TrustType, IntraForest, ForestTransitive
```

```cmd
nltest /domain_trusts /all_trusts
```

| 표시 | 의미 |
|---|---|
| `IntraForest = True` | 같은 포리스트 |
| `ForestTransitive = True` | 별도 포리스트 (포리스트 트러스트) |
| 둘 다 False | 별도 포리스트의 외부(External) 트러스트 |

`nltest` 출력에서는 같은 포리스트의 도메인에 `(Forest: n)` 또는 `Forest Tree Root` 표시가 붙습니다.

GUI로는 "Active Directory 도메인 및 트러스트"에서 도메인 속성의 트러스트 탭을 봅니다. 유형이 "부모/자식", "트리 루트"면 같은 포리스트이고, "포리스트", "외부"면 별도 포리스트입니다.

### 3.3 Trino 서버(Linux)에서 직접 확인

AD 관리 권한이 없어도 RootDSE를 조회하면 알 수 있습니다.

```bash
ldapsearch -x -H ldap://asia.corp.example.com -b "" -s base \
  rootDomainNamingContext defaultNamingContext configurationNamingContext
```

- `rootDomainNamingContext`: 포리스트 루트 (예: `DC=corp,DC=example,DC=com`)
- `defaultNamingContext`: 해당 DC의 도메인

각 도메인의 DC에 실행해서 `rootDomainNamingContext`가 같으면 같은 포리스트입니다.

### 3.4 주의할 점

- **이름만으로 판단하면 안 됩니다.** `asia.corp.example.com`처럼 이름이 하위 도메인 형태여도 별도 포리스트일 수 있고, `corp.example.com`과 `partner.local`처럼 이름이 전혀 달라도 같은 포리스트의 다른 트리일 수 있습니다.
- **같은 포리스트인데 트리가 다른 경우**: GC는 그대로 쓸 수 있지만 `ldap.user-base-dn` 하나로 두 트리를 함께 덮기 어렵습니다. 이때는 같은 포리스트라도 방법 B처럼 인증기 파일을 나누는 편이 낫습니다.

---

## 4. AD가 referral을 반환하는 이유

검색 범위(base DN)에 **해당 DC가 직접 갖고 있지 않은 디렉터리 파티션(naming context)** 이 포함되기 때문입니다. DC는 그 데이터가 없으니 "그 부분은 저 서버에 물어보라"는 LDAP URL을 대신 돌려줍니다.

### 4.1 왜 DC가 데이터를 다 갖고 있지 않은가

AD 데이터는 파티션 단위로 나뉘어 복제되고, 일반 DC(389/636 포트)는 자기 도메인 파티션만 전체 복사본을 가집니다.

| 파티션 | 예시 DN | 복제 범위 |
|---|---|---|
| 도메인 | `DC=corp,DC=example,DC=com` | 해당 도메인의 DC |
| 구성(Configuration) | `CN=Configuration,DC=corp,...` | 포리스트 전체 DC |
| 스키마 | `CN=Schema,CN=Configuration,...` | 포리스트 전체 DC |
| DNS 애플리케이션 | `DC=DomainDnsZones,...`, `DC=ForestDnsZones,...` | DNS 역할이 있는 DC |

### 4.2 referral이 나오는 대표적인 경우

- **도메인 루트를 base DN으로 서브트리 검색할 때**: 가장 흔한 경우이며 단일 도메인 환경에서도 발생합니다. `DC=corp,DC=example,DC=com` 아래에는 논리적으로 Configuration, DomainDnsZones, ForestDnsZones, 하위 도메인이 걸려 있습니다. AD는 결과 끝에 다음과 같은 연속 참조(search result reference)를 붙입니다.
  ```
  ldap://ForestDnsZones.corp.example.com/DC=ForestDnsZones,DC=corp,DC=example,DC=com
  ldap://DomainDnsZones.corp.example.com/DC=DomainDnsZones,DC=corp,DC=example,DC=com
  ldap://corp.example.com/CN=Configuration,DC=corp,DC=example,DC=com
  ```
- **하위 도메인이 있을 때**: 부모 도메인 DC는 자식 도메인 데이터가 없으므로 `ldap://asia.corp.example.com/DC=asia,...` 같은 참조를 돌려줍니다.
- **base DN이 다른 도메인일 때**: DC가 자기 것이 아닌 도메인의 DN을 받으면, 포리스트 내 교차 참조(crossRef) 정보를 보고 올바른 도메인으로 referral을 돌려줍니다.

### 4.3 Trino에서 문제가 되는 이유

Trino(JNDI)는 기본적으로 referral을 따라가려고 합니다. 이때 URL의 호스트가 DC 이름이 아니라 `DomainDnsZones.corp.example.com` 같은 DNS 이름이라서 다음 문제가 생깁니다.

- Trino 서버가 그 이름을 조회하지 못하면 타임아웃이나 `PartialResultException`, `Unprocessed Continuation Reference` 류의 오류가 납니다.
- 조회가 되더라도 `ldaps`로 접속했다면 인증서 SAN에 그 이름이 없어 TLS 검증에 실패할 수 있습니다.
- 성공하더라도 불필요한 접속 때문에 로그인이 느려집니다.

### 4.4 해결 방법

1. **`ldap.ignore-referrals=true`**: 단일 도메인이면 이것으로 충분합니다. 사용자 계정은 도메인 파티션에 있으므로 잃는 것이 없습니다.
2. **base DN을 좁히기**: `ldap.user-base-dn`을 도메인 루트 대신 `OU=Users,DC=corp,DC=example,DC=com`처럼 OU로 지정하면 다른 파티션이 범위에 들지 않아 referral이 나오지 않습니다.
3. **Global Catalog 포트(3268/3269) 사용**: GC는 포리스트 전체의 부분 복사본을 갖고 있어 referral 없이 직접 응답합니다. 여러 도메인에 걸쳐 검색해야 하면 이 방법을 씁니다.

### 4.5 실제 referral 확인

결과 끝의 `# search reference` 줄이 referral입니다.

```bash
ldapsearch -x -H ldap://corp.example.com -D "user@corp.example.com" -W \
  -b "DC=corp,DC=example,DC=com" "(sAMAccountName=alice)" dn
```

---

## 5. 참고 자료

- [LDAP authentication — Trino documentation](https://trino.io/docs/current/security/ldap.html)
- [Authentication types — Trino documentation](https://trino.io/docs/current/security/authentication-types.html)
- [Group mapping — Trino documentation](https://trino.io/docs/current/security/group-mapping.html)
