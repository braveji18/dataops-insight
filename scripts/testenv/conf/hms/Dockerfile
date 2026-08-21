# syntax=docker/dockerfile:1
#
# Hive Metastore + S3A 지원. Hive 3 / Hive 4 공용.
#
# 순정 apache/hive 이미지에는 hadoop-aws / aws-java-sdk-bundle 이 없다.
# HMS 는 CREATE SCHEMA 시 s3a:// 경로에 디렉토리를 만들려 하므로, jar 가 없으면
# ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem 으로 죽는다.
# 이 스택에서 가장 자주 깨지는 지점이라 별도 이미지로 굽고 버전을 고정한다.
#
# hadoop-aws 버전은 base 이미지가 번들한 Hadoop 버전과 반드시 일치해야 한다.
# 버전 조합은 hive/hive3.env, hive/hive4.env 가 확인법과 함께 관리한다.
#
# 아래 ARG 에 기본값을 두지 않는 것은 의도적이다 — 값이 빠지면 빌드가 실패한다.
# 잘못된 조합이 조용히 빌드돼 런타임에 S3A 가 깨지는 것보다 낫다.

ARG CURL_IMAGE
ARG HIVE_BASE_IMAGE

FROM ${CURL_IMAGE} AS jars
ARG HADOOP_AWS_VERSION
ARG AWS_SDK_BUNDLE_VERSION
ARG POSTGRES_JDBC_VERSION
WORKDIR /jars
RUN curl -fsSLO "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
 && curl -fsSLO "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_BUNDLE_VERSION}/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar" \
 && curl -fsSLO "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar"

FROM ${HIVE_BASE_IMAGE}

# 기동 분기(schema init 멱등성, hive-site.xml 공급)에 쓴다.
# 이미지에서 읽지 않고 구워 넣는 이유: apache/hive:3.1.3 에는 HIVE_VER 환경변수가 없다.
ARG HIVE_MAJOR=4
ENV HIVE_MAJOR=${HIVE_MAJOR}

USER root
COPY --from=jars /jars/hadoop-aws-*.jar /jars/aws-java-sdk-bundle-*.jar /jars/postgresql-*.jar /opt/hive/lib/
COPY hms-entrypoint.sh /hms-entrypoint.sh
RUN chmod 0644 /opt/hive/lib/hadoop-aws-*.jar /opt/hive/lib/aws-java-sdk-bundle-*.jar /opt/hive/lib/postgresql-*.jar \
 && chmod 0755 /hms-entrypoint.sh \
 # Hive 3.1.3 은 postgresql-9.4.1208.jre7.jar 를 동봉한다. 이 드라이버는
 # SCRAM-SHA-256 을 지원하지 않아 PostgreSQL 16 기본 인증에서 실패하고,
 # 위에서 주입한 42.7.4 와 함께 클래스패스에 있으면 어느 쪽이 잡힐지도 불확실하다.
 && rm -f /opt/hive/lib/postgresql-9.*.jar
USER hive

ENTRYPOINT ["/hms-entrypoint.sh"]
