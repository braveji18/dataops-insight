# StarRocks: 모든 catalog의 테이블을 읽기만 가능한 사용자 추가 방법

StarRocks 3.0 이상(RBAC 기반)에서는 **읽기 전용 role을 만들어 권한을 준 뒤, 그 role을 사용자에게 부여**하면 됩니다.

핵심은 테이블 단위 SELECT 권한이 **catalog마다 따로** 적용된다는 점입니다. 이 GRANT 문은 실행 전에 먼저 `SET CATALOG`를 해야 하므로, catalog마다 한 번씩 반복해서 실행해야 합니다.

---

## 1. Role 생성 및 catalog 사용 권한

```sql
CREATE ROLE read_only;

-- 모든 catalog(내부 + 외부)에 대한 USAGE 권한
GRANT USAGE ON ALL CATALOGS TO ROLE read_only;
```

## 2. 내부 catalog(default_catalog) 읽기 권한

```sql
SET CATALOG default_catalog;

GRANT SELECT ON ALL TABLES IN ALL DATABASES TO ROLE read_only;
GRANT SELECT ON ALL VIEWS IN ALL DATABASES TO ROLE read_only;
GRANT SELECT ON ALL MATERIALIZED VIEWS IN ALL DATABASES TO ROLE read_only;

-- (선택) 쿼리에서 UDF를 쓴다면
GRANT USAGE ON ALL FUNCTIONS IN ALL DATABASES TO ROLE read_only;
```

## 3. 외부 catalog마다 반복

```sql
SHOW CATALOGS;   -- 외부 catalog 목록 확인

SET CATALOG hive_catalog;
GRANT SELECT ON ALL TABLES IN ALL DATABASES TO ROLE read_only;

SET CATALOG iceberg_catalog;
GRANT SELECT ON ALL TABLES IN ALL DATABASES TO ROLE read_only;
-- ... 나머지 catalog도 같은 방식
```

외부 catalog의 view에는 SELECT를 줄 수 있는 범위가 좁습니다. 외부 catalog에서는 Hive 테이블 view에만 SELECT 권한을 줄 수 있습니다(v3.1부터). Hive catalog라면 아래 문장을 추가할 수 있습니다.

```sql
SET CATALOG hive_catalog;
GRANT SELECT ON ALL VIEWS IN ALL DATABASES TO ROLE read_only;
```

## 4. 사용자 생성 및 기본 role 지정

```sql
CREATE USER 'ro_user'@'%' IDENTIFIED BY 'StrongPassword!' DEFAULT ROLE 'read_only';

-- 이미 있는 사용자라면
GRANT read_only TO USER 'ro_user'@'%';
ALTER USER 'ro_user'@'%' DEFAULT ROLE read_only;
```

DEFAULT ROLE을 지정하지 않으면, 사용자가 접속할 때 role이 활성화되지 않아 권한이 없는 것처럼 보일 수 있습니다.

## 5. 확인

```sql
SHOW GRANTS FOR ROLE read_only;
SHOW GRANTS FOR 'ro_user'@'%';
```

`ro_user`로 접속해서 `SET CATALOG xxx; SHOW DATABASES; SELECT ...`가 되는지, `INSERT`나 `DROP`이 거부되는지 확인하면 됩니다.

---

## 주의할 점

- **새 catalog:** 나중에 외부 catalog를 새로 만들면 3번의 SELECT GRANT를 그 catalog에 대해 다시 실행해야 합니다. `USAGE ON ALL CATALOGS`가 있어도 테이블 SELECT 권한은 catalog별로 따로 줘야 합니다.
- **외부 catalog의 실제 접근 권한:** StarRocks의 권한과 별개로, 외부 저장소 쪽 권한도 맞아야 합니다. 예를 들어 Hive Metastore, S3/HDFS 접근 권한이나 Ranger 연동 설정입니다. Ranger로 권한을 관리하는 catalog라면 StarRocks GRANT 대신 Ranger 정책으로 제어됩니다.
- **버전:** 위 문법은 3.0 이상 기준입니다. 2.x에서는 권한 체계가 다릅니다.

---

## 참고 자료

- [StarRocks — GRANT](https://docs.starrocks.io/docs/sql-reference/sql-statements/account-management/GRANT/)
- [StarRocks — User privilege 관리](https://docs.starrocks.io/zh/docs/administration/user_privs/authorization/User_privilege/)
- [StarRocks — Privileges supported by StarRocks](https://docs.starrocks.io/docs/administration/user_privs/authorization/privilege_item/)
