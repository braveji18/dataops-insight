# syntax=docker/dockerfile:1
#
# Hive Metastore + S3A 지원.
#
# 순정 apache/hive 이미지에는 hadoop-aws / aws-java-sdk-bundle 이 없다.
# HMS 는 CREATE SCHEMA 시 s3a:// 경로에 디렉토리를 만들려 하므로, jar 가 없으면
# ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem 으로 죽는다.
# 이 스택에서 가장 자주 깨지는 지점이라 별도 이미지로 굽고 버전을 고정한다.
#
# hadoop-aws 버전은 base 이미지가 번들한 Hadoop 버전과 반드시 일치해야 한다.
# 확인법: docker run --rm --entrypoint sh <hive-image> -c 'ls /opt/hadoop*/share 2>/dev/null; ls /opt/hive/lib | grep hadoop-common'

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
USER root
COPY --from=jars /jars/hadoop-aws-*.jar /jars/aws-java-sdk-bundle-*.jar /jars/postgresql-*.jar /opt/hive/lib/
RUN chmod 0644 /opt/hive/lib/hadoop-aws-*.jar /opt/hive/lib/aws-java-sdk-bundle-*.jar /opt/hive/lib/postgresql-*.jar
USER hive
