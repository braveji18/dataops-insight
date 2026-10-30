# LocalCrab Docker 실행 가이드

LocalCrab을 Docker Compose로 실행하는 방법입니다. 구성 파일은 저장소 루트의
[`docker-compose.yml`](../docker-compose.yml), [`Dockerfile`](../Dockerfile),
[`apps/web/Dockerfile`](../apps/web/Dockerfile)입니다.

## 구성

| 서비스 | 이미지 | 포트 | 역할 |
| --- | --- | --- | --- |
| `api` | `localcrab:latest` | 8000 | FastAPI 서버 (`uvicorn server.api:app`). `opencrab`·`crabharness` CLI도 포함 |
| `web` | `opencrab-web` | 3000 | Next.js 대시보드 (그래프 뷰) |

모든 데이터는 로컬 저장소(SQLite 그래프, Chroma 벡터, JSON 문서, SQLite 레지스트리)에
저장되며 외부 DB(Neo4j, MongoDB, PostgreSQL)는 필요하지 않습니다.

| 볼륨 | 마운트 위치 | 내용 |
| --- | --- | --- |
| `opencrab_data` | `/data` | `graph.db`, `chroma/`, `docs/`, `opencrab.db` |
| `chroma_cache` | `/root/.cache/chroma` | Chroma 기본 임베딩 모델 캐시 (최초 ingest 시 다운로드) |

## 실행

```bash
docker compose up -d --build     # 빌드 후 백그라운드 실행
docker compose ps                # 상태 확인
docker compose logs -f api       # API 로그
docker compose down              # 중지 (데이터 유지)
docker compose down -v           # 중지 + 볼륨 삭제 (데이터 초기화)
```

정상 기동 확인:

```bash
curl -s localhost:8000/api/status
# {"ok":true,"service":"opencrab-api","tier":"pro","storage_mode":"local","stores":{...}}
```

웹 대시보드는 http://localhost:3000 에서 열고, API 키 입력란에 `OPENCRAB_API_KEY` 값을 넣습니다.

docker images 파일로 저장
```
docker save -o  localcrab.tar  localcrab:latest
docker save -o  localcrab_v0.3.tar  localcrab:v0.3
docker save -o localcrab-lab.tar  localcrab-lab:latest 
docker save -o opencrab-web.tar   opencrab-web:latest
```

## 환경 변수

`docker compose` 실행 시 셸 환경 변수 또는 루트의 `.env` 파일로 덮어쓸 수 있습니다.

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `OPENCRAB_API_KEY` | `localcrab-dev-key` | `/api/*` 인증용 Bearer 토큰 |
| `OPENCRAB_TIER` | `pro` | `free` / `pro` / `api`. `free`는 사용자당 소스 1개로 제한 |
| `LOG_LEVEL` | `INFO` | API 로그 레벨 |

예:

```bash
OPENCRAB_API_KEY=my-secret docker compose up -d
```

웹이 호출하는 API 주소(`NEXT_PUBLIC_API_URL`, 기본 `http://localhost:8000`)는 **빌드 시점**에
고정됩니다. 다른 호스트에서 접속하려면 `docker-compose.yml`의 `web.build.args`와
`api.environment.OPENCRAB_CORS_ORIGINS`를 수정한 뒤 `docker compose up -d --build`로 다시 빌드합니다.

## REST API 사용 예

```bash
KEY=localcrab-dev-key

# 텍스트 ingest
curl -s -X POST localhost:8000/api/ingest \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"text":"System error rates increased after the deploy.","source_id":"demo-1"}'

# 하이브리드 검색
curl -s -X POST localhost:8000/api/query \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"question":"error rates"}'

# 문법(grammar) 조회
curl -s localhost:8000/api/manifest -H "Authorization: Bearer $KEY"
```

`/api/status`를 제외한 모든 `/api/*` 엔드포인트는 Bearer 토큰이 필요합니다.

그 외 엔드포인트: `POST /api/nodes`, `POST /api/edges`, `POST /api/impact`, `GET /api/usage`, `GET|POST /mcp`.

## CLI 사용

`api` 컨테이너 안에서 `opencrab` / `crabharness` CLI를 그대로 쓸 수 있으며, 같은 `/data` 볼륨을 공유합니다.

```bash
docker compose exec api opencrab status
docker compose exec api opencrab manifest
docker compose exec api opencrab query "system performance and error rates"
docker compose exec api python scripts/seed_ontology.py   # 예제 데이터 시드

docker compose exec api crabharness catalog
```

호스트 파일을 ingest하려면 디렉토리를 마운트해서 일회성 컨테이너로 실행합니다.

```bash
docker compose run --rm -v "$PWD/notes:/input:ro" api opencrab ingest /input -r
```

## 논문 정리 노트 가져오기

[`scripts/import_paper_notes.py`](../scripts/import_paper_notes.py)는 논문 정리 마크다운
(예: [`docs/RF튜닝_고차원선형모형자동화.md`](./RF튜닝_고차원선형모형자동화.md))을 읽고,
링크된 논문을 내려받아 OpenCrab에 등록합니다.

```bash
docker compose run --rm -T \
  -v "$PWD/scripts:/app/scripts:ro" -v "$PWD/docs:/app/docs:ro" \
  api python scripts/import_paper_notes.py "docs/RF튜닝_고차원선형모형자동화.md"
```

| 옵션 | 설명 |
| --- | --- |
| `--dry-run` | 파싱·다운로드만 하고 OpenCrab에는 쓰지 않음 |
| `--no-download` | 논문을 내려받지 않고 노트의 요약과 메타데이터만 등록 |
| `--download-dir` | PDF/HTML 저장 위치 (기본 `$LOCAL_DATA_DIR/papers`, 컨테이너에서는 `/data/papers`) |
| `--chunk-size`, `--chunk-overlap`, `--max-chunks` | 본문 벡터 청크 설정 (기본 1500 / 200 / 논문당 120) |
| `--delay` | 다운로드 간격 초 (기본 3, arXiv 권장값) |

노트 형식: `## Part ...` 섹션 안의 표 첫 열이 `[제목](URL)`이고, 나머지 열이
`저자 · 연도 · 게재 | 분류 | 핵심 내용`입니다. Part 본문 문장 속 링크도 논문으로 등록되며
(분류 `기준 논문`), `## Sources` 섹션은 무시합니다.

처리 내용:

- arXiv 링크(ADS의 arXiv 서지코드 포함)는 arXiv API로 제목·저자·초록을 가져오고 PDF를 받습니다.
  DOI 링크는 Crossref에서 메타데이터를 가져옵니다.
- PDF 본문은 `pypdf`로 추출해 청크 단위로 벡터 저장소에 넣습니다. 각 청크의
  `metadata.node_id`는 해당 논문 노드이므로 검색 결과가 그래프로 이어집니다.
- 그래프 구조:
  `노트 Document --contains--> 요약 TextUnit <--contains-- 논문 Document`,
  `요약 TextUnit --describes--> 분류 Topic --part_of--> Part Topic`
- 노드 ID가 고정(arXiv ID 또는 URL 해시)이라 다시 실행해도 중복되지 않고 덮어씁니다.
  이미 받은 파일은 다시 내려받지 않습니다.

일부 출판사(ESAIM, INFORMS, OUP 등)는 자동 다운로드를 403으로 막습니다. 이 경우 노트의 요약과
메타데이터만 등록되고, 스크립트가 출력한 경로(예: `/data/papers/paper-xxxx.pdf`)에 PDF를 직접
넣은 뒤 다시 실행하면 본문이 추가됩니다.

```bash
docker compose cp ./bertsimas-king.pdf api:/data/papers/paper-2dad6d6d6291d107.pdf
```

### 등록 확인

아래 예상값은 `docs/RF튜닝_고차원선형모형자동화.md`(논문 15편, 이 중 3편 다운로드 실패)를
가져온 경우입니다.

**1. 그래프 노드·엣지 개수**

```bash
docker compose exec -T api python - <<'EOF'
import sqlite3
c = sqlite3.connect('/data/graph.db')
print(c.execute("select space_id, node_type, count(*) from graph_nodes group by 1,2").fetchall())
print(c.execute("select relation, count(*) from graph_edges group by 1").fetchall())
EOF
```

예상값: `Document` 16(노트 1 + 논문 15), `TextUnit` 15(논문별 요약), `Topic` 13(Part 2 + 분류 11) /
`contains` 30, `describes` 15, `part_of` 11.

**2. 논문별 등록·다운로드 상태**

```bash
docker compose exec -T api python - <<'EOF'
import sqlite3
c = sqlite3.connect('/data/graph.db')
for r in c.execute("""select node_id, json_extract(properties,'$.title'),
                             json_extract(properties,'$.download_status')
                      from graph_nodes where json_extract(properties,'$.kind')='paper'
                      order by 2"""):
    print(r)
EOF
docker compose exec api ls /data/papers
```

`cached`/`downloaded`는 PDF 본문까지 등록된 논문, `failed (HTTP 403)`은 요약·메타데이터만 등록된
논문입니다(위의 수동 PDF 추가 방법 참고).

**3. 논문별 벡터 청크 수**

```bash
docker compose exec -T api python - <<'EOF'
import logging; logging.disable(logging.WARNING)
from collections import Counter
from opencrab.mcp.tools import _get_context
meta = _get_context()['chroma']._collection.get(include=["metadatas"])["metadatas"]
cnt = Counter(m.get("node_id") for m in meta if m.get("note"))
for k, v in sorted(cnt.items()): print(f"{v:4d}  {k}")
print("total:", sum(cnt.values()))
EOF
```

`paper-arxiv-*` 노드는 본문 청크 수(최대 `--max-chunks`), `*-summary`와 다운로드 실패 논문은 1개,
노트(`note-*`)는 노트 본문 청크 수가 나옵니다. 예시 노트의 합계는 670입니다.

**4. 검색으로 확인**

```bash
docker compose exec api opencrab query "number of trees in random forest"
docker compose exec api opencrab query "sure independence screening"

curl -s -X POST localhost:8000/api/query \
  -H 'Authorization: Bearer localcrab-dev-key' -H 'Content-Type: application/json' \
  -d '{"question":"number of trees in random forest tuning","limit":5}'
```

결과의 `node`/`node_id`로 어디에 걸렸는지 알 수 있습니다: `paper-arxiv-…`는 논문 본문,
`…-summary`는 노트의 요약, `note-…`는 노트 자체입니다. 예를 들어 첫 질의는 기준 논문
(`paper-arxiv-1804.03515`)과 트리 수 논문(`paper-arxiv-1705.05654`)이 상위에 나와야 합니다.
본문 없이 요약만 등록된 논문은 순위가 낮게 나올 수 있습니다.

MCP로 연결했다면 Claude Code에서 "OpenCrab에서 L0 best subset selection 관련 논문 찾아줘"처럼
물어 `ontology_query` 도구로 확인할 수도 있습니다. 웹 대시보드의 그래프 뷰로는 확인할 수 없습니다
(아래 "알려진 문제" 참고).

### REST API로 논문 조회

가져온 논문은 REST API로 검색·분석할 수 있습니다. 아래 예는 결과를 보기 좋게 줄이기 위해 `jq`를
사용합니다(없으면 `| jq ...` 부분을 빼고 원본 JSON을 보면 됩니다).

```bash
KEY=localcrab-dev-key
q() {  # 사용법: q '<JSON 요청 본문>'
  curl -s -X POST localhost:8000/api/query \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$1"
}
```

**질문으로 논문 찾기**: 한국어 질문도 동작합니다.

```bash
q '{"question":"트리 수는 튜닝하지 말 것","limit":5}' \
  | jq -r '.results[] | "\(.source)\t\(.score|.*1000|round/1000)\t\(.node_id)"'
# hybrid  0.74   paper-arxiv-1804.03515
# vector  0.507  note-81aa83ae2396055b
# vector  0.462  paper-arxiv-1705.05654-summary
```

요청 필드:

| 필드 | 설명 |
| --- | --- |
| `question` | 검색 질문 (필수) |
| `limit` | 결과 수, 1–25 (기본 10) |
| `spaces` | 벡터 검색을 특정 공간으로 제한. 논문 본문은 `["resource"]`, 노트 요약은 `["evidence"]` |
| `graph_depth` | 그래프 확장 깊이, 1–4 (기본 1) |

응답의 `results[]`:

| 필드 | 설명 |
| --- | --- |
| `source` | `vector`(벡터 검색), `graph`(그래프 확장으로 추가된 이웃), `hybrid`(둘 다) |
| `node_id` | 걸린 노드: `paper-arxiv-…`는 논문 본문, `…-summary`는 노트 요약, `note-…`는 노트 자체 |
| `text` | 걸린 청크의 본문 |
| `graph_context` | `graph` 결과일 때 어느 노드(`anchor_id`)에서 어떤 관계로 이어졌는지 |

**논문 본문만 검색 (`spaces`)**

```bash
q '{"question":"automated feature engineering for linear models","spaces":["resource"],"limit":5}' \
  | jq -r '.results[] | "\(.source)\t\(.node_id)\t\(.text[:60]|gsub("\n";" "))"'
```

`spaces`는 벡터 검색에만 적용됩니다. 그래프 확장으로 붙는 이웃(`source: graph`)은 다른 공간일 수
있습니다. 예를 들어 `["evidence"]`로 검색해도 요약의 이웃인 논문 노드가 함께 나옵니다.

**노트의 요약만 검색**

```bash
q '{"question":"best subset selection l0","spaces":["evidence"],"limit":5}' \
  | jq -r '.results[] | "\(.source)\t\(.node_id)\t\(.text[:80]|gsub("\n";" "))"'
```

**논문의 연결 관계 보기 (`/api/impact`)**: 논문 노드에서 그래프를 따라 이어진 노드를 보여줍니다.

```bash
curl -s -X POST localhost:8000/api/impact \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"node_id":"paper-arxiv-1804.03515","depth":2}' \
  | jq -r '.affected_nodes[] | "\(.labels[0])\t\(.properties.title // .properties.name)"'
# TextUnit  Hyperparameters and Tuning Strategies for Random Forest — 요약
# Topic     기준 논문
# Document  관련 논문 정리: RF 튜닝 & 고차원 선형 모형 자동화
```

`node_id`는 위 "등록 확인" 2번에서 확인한 논문 ID를 씁니다(arXiv 논문은 `paper-arxiv-<arXiv ID>`).

**전체 사용량**

```bash
curl -s localhost:8000/api/usage -H "Authorization: Bearer $KEY" | jq .system
# {"nodes": 44, "vectors": 671, "queries": ...}
```

`nodes`, `vectors`는 데이터 전체의 합계입니다. 논문 외 데이터가 있으면 그만큼 더 큽니다.

## MCP 서버로 연결 (Claude Code)

MCP로 연결하는 방법은 두 가지입니다.

| 방식 | 엔드포인트 | 도구 | 특징 |
| --- | --- | --- | --- |
| stdio | `opencrab serve` (일회성 컨테이너) | 30개 전체 | 모든 도구 사용 가능. 호출마다 컨테이너 기동 |
| HTTP | `http://localhost:8000/mcp` (실행 중인 `api`) | 7개 | 추가 컨테이너 없음. Bearer 토큰 필요. 원격 접속 가능 |

### stdio 방식

MCP 서버는 stdio로 동작하므로 `-T`(TTY 없음) 옵션으로 일회성 컨테이너를 띄웁니다.

```bash
claude mcp add opencrab -- \
  docker compose -f /절대/경로/OpenCrab/docker-compose.yml run --rm -T api opencrab serve
```

수동 설정:

```json
{
  "mcpServers": {
    "opencrab": {
      "command": "docker",
      "args": ["compose", "-f", "/절대/경로/OpenCrab/docker-compose.yml",
               "run", "--rm", "-T", "api", "opencrab", "serve"]
    }
  }
}
```

MCP 컨테이너도 `opencrab_data` 볼륨을 쓰므로 API·웹에서 보이는 데이터와 동일합니다.

### HTTP 방식 (REST 엔드포인트 `/mcp`)

실행 중인 `api` 서버의 `/mcp`는 MCP Streamable HTTP(프로토콜 `2025-03-26`) 엔드포인트입니다.
Claude Code에는 다음처럼 등록합니다.

```bash
claude mcp add --transport http opencrab-http http://localhost:8000/mcp \
  --header "Authorization: Bearer localcrab-dev-key"
```

수동 설정:

```json
{
  "mcpServers": {
    "opencrab-http": {
      "type": "http",
      "url": "http://localhost:8000/mcp",
      "headers": { "Authorization": "Bearer localcrab-dev-key" }
    }
  }
}
```

제공 도구: `ontology_query`, `ontology_impact`, `ontology_manifest`, `ontology_ingest`,
`ontology_add_node`, `ontology_add_edge`, `ontology_lever_simulate`. 논문 조회에는
`ontology_query`와 `ontology_impact`를 씁니다. 쓰기 도구는 아래 "알려진 문제"를 참고하세요.

#### curl로 직접 호출하기

`/mcp`는 JSON-RPC 2.0 요청을 `POST`로 받습니다. 도구 결과는 `result.content[0].text`에
JSON 문자열로 들어 있으므로 `jq`의 `fromjson`으로 풀어서 봅니다.

```bash
KEY=localcrab-dev-key
mcp() {  # 사용법: mcp '<JSON-RPC 요청>'
  curl -s -X POST localhost:8000/mcp \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$1"
}

# 서버 정보 (인증 불필요)
curl -s localhost:8000/mcp
# {"name":"opencrab","version":"0.1.0","protocol":"2025-03-26","endpoint":"/mcp","tools":7}

# 초기화 · 도구 목록
mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[].name'
```

**논문 검색 (`ontology_query`)**: 인자는 REST `/api/query`와 같습니다(`question`, `limit`,
`spaces`, `graph_depth`).

```bash
mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
       "name":"ontology_query",
       "arguments":{"question":"트리 수는 튜닝하지 말 것","limit":3}}}' \
  | jq -r '.result.content[0].text | fromjson | .results[]
           | "\(.source)\t\(.score|.*1000|round/1000)\t\(.node_id)"'
# hybrid  0.74   paper-arxiv-1804.03515
# vector  0.657  note-81aa83ae2396055b
# vector  0.464  paper-arxiv-1705.05654-summary
```

노트의 요약만 검색:

```bash
mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
       "name":"ontology_query",
       "arguments":{"question":"best subset selection l0","spaces":["evidence"],"limit":3}}}' \
  | jq -r '.result.content[0].text | fromjson | .results[]
           | "\(.source)\t\(.node_id)\t\(.text[:60]|gsub("\n";" "))"'
```

**논문의 연결 관계 (`ontology_impact`)**

```bash
mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{
       "name":"ontology_impact",
       "arguments":{"node_id":"paper-arxiv-1803.01454"}}}' \
  | jq -r '.result.content[0].text | fromjson | .affected_nodes[]
           | "\(.labels[0])\t\(.properties.title // .properties.name)"'
# TextUnit  Fast Best Subset Selection (L0Learn) — 요약
# Topic     희소 선택 알고리즘
# Document  관련 논문 정리: RF 튜닝 & 고차원 선형 모형 자동화
```

**문법 조회 (`ontology_manifest`)**

```bash
mcp '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ontology_manifest","arguments":{}}}' \
  | jq '.result.content[0].text | fromjson | .spaces | keys'
```

에러는 JSON-RPC `error` 필드로 옵니다(예: 알 수 없는 메서드는 `-32601`, 도구 실행 실패는 `-32603`).
토큰이 없거나 틀리면 HTTP 401과 `{"detail":"Invalid API token."}`가 반환됩니다.

Claude Code에 등록한 뒤에는 "OpenCrab에서 L0 best subset selection 관련 논문 찾아줘",
"paper-arxiv-1803.01454 논문과 연결된 노드 보여줘"처럼 물으면 위 도구들이 호출됩니다.

### MCP로 논문을 확인하고 데이터 분석하기

Claude Code가 OpenCrab MCP에서 논문을 찾아 근거로 삼고, 그 방법대로 임의의 데이터를 분석하게 하는
흐름입니다. 아래 예는 HTTP 방식(`opencrab-http`)으로 등록한 경우이며, stdio 방식으로 등록했다면
도구 이름의 `opencrab-http`를 `opencrab`으로 바꾸면 됩니다.

#### 1. 연결 확인

```bash
claude mcp list
# opencrab-http: http://localhost:8000/mcp (HTTP) - ✔ Connected
```

Claude Code 대화 중에는 `/mcp` 명령으로 연결 상태와 도구 목록을 볼 수 있습니다.

#### 2. 논문 확인

Claude Code 대화창에서 그대로 묻습니다.

```text
OpenCrab에 등록된 논문 목록을 Part별로 정리해줘.
OpenCrab에서 랜덤 포레스트 트리 수 튜닝에 관한 논문을 찾아서 제목, node_id, 핵심 주장을 알려줘.
paper-arxiv-1803.01454 논문과 연결된 분류·노트를 ontology_impact로 보여줘.
```

터미널에서 한 번에 실행하려면 `claude -p`(비대화형)를 쓰고, 사용할 MCP 도구를 `--allowedTools`로 허용합니다.

```bash
claude -p "OpenCrab(opencrab-http MCP)에 등록된 논문 중 랜덤 포레스트 트리 수 튜닝에 관한 논문을 찾아서 제목, node_id, 핵심 주장을 3줄 이내로 알려줘." \
  --allowedTools "mcp__opencrab-http__ontology_query"
```

출력 예:

```text
"To tune or not to tune the number of trees in random forest?" (Probst & Boulesteix, 2018, JMLR)
- node_id: paper-arxiv-1705.05654
- 핵심 주장: 오분류율은 트리 수에 비단조적일 수 있으나 Brier score·log loss·MSE는 아님.
  트리 수는 튜닝하지 말고 계산 가능한 큰 값으로 고정할 것을 권고.
```

#### 3. 분석 환경과 임의 데이터 준비

분석 코드는 호스트가 아니라 분석용 컨테이너 `lab`(numpy, pandas, scipy, scikit-learn)에서 실행합니다.
`lab`은 `analysis` 프로필이라 `docker compose up`으로는 뜨지 않고, 필요할 때 `run`으로 실행합니다.

| 호스트 경로 | 컨테이너 경로 | 용도 |
| --- | --- | --- |
| `./data` | `/work/data` | 분석 데이터 (읽기·쓰기) |
| `./analysis` | `/work/analysis` | Claude가 만든 분석 코드·보고서 |
| `./scripts` | `/work/scripts` | 데이터 생성 스크립트 (읽기 전용) |

```bash
docker compose --profile analysis build lab

# 임의 데이터 생성 (scripts/make_sample_data.py)
docker compose run --rm lab python scripts/make_sample_data.py highdim   # p≫n 회귀 (300행 × 2000변수)
docker compose run --rm lab python scripts/make_sample_data.py rf        # 이진 분류 (1000행 × 30변수)
```

| 데이터 | 노트의 해당 Part | 내용 |
| --- | --- | --- |
| `data/highdim.csv` | Part 2. 고차원 변수 선택·변환 | 상관된 변수 블록 + 제곱·로그·상호작용 항이 섞인 희소 신호 |
| `data/rf.csv` | Part 1. RF 하이퍼파라미터·튜닝 | 비선형·상호작용이 있는 이진 분류 (타깃 `y`는 0/1) |

생성 공식(정답)은 `data/_answers/`에 따로 저장됩니다. 분석이 끝난 뒤 결과를 채점할 때만 보고,
분석 중에는 Claude가 읽지 못하게 합니다(아래 `--disallowedTools` 참고). 자신의 데이터를 쓰려면
CSV를 `data/`에 넣고 프롬프트의 파일 이름과 타깃 컬럼만 바꾸면 됩니다.

`lab`은 기본적으로 UID/GID 1000으로 실행됩니다. 호스트 사용자가 다르면 `LAB_UID=$(id -u) LAB_GID=$(id -g)`를
함께 지정하세요.

#### 4. 논문 근거로 분석 실행

대화창에서 요청하는 예:

```text
data/highdim.csv(타깃 y)를 분석해줘. 먼저 OpenCrab MCP에서 p≫n 회귀의 변수 선택 방법과
권장 파이프라인을 찾아 근거 논문 node_id와 함께 정리하고, 그 파이프라인을 analysis/ 아래에
구현해서 'docker compose run --rm lab python ...'로 실행한 뒤 결과를 보고해줘.
data/_answers 폴더는 열지 마.
```

터미널에서 비대화형으로 실행하는 예(고차원 회귀):

```bash
claude -p "data/highdim.csv(타깃 컬럼 y)를 분석해줘.
1) 먼저 opencrab-http MCP의 ontology_query로 OpenCrab에 등록된 논문에서 p≫n 회귀의 변수 스크리닝·변환·선택 방법과 권장 파이프라인을 찾아, 근거가 된 논문 node_id와 함께 정리해.
2) 그 파이프라인(스크리닝 → 비선형 변환 후보 생성 → 희소 선택 → 선택 편향을 막는 nested CV 평가)을 analysis/highdim_pipeline.py로 구현하고 'docker compose run --rm lab python analysis/highdim_pipeline.py'로 실행해. 사용 가능한 패키지는 numpy, pandas, scipy, scikit-learn뿐이야.
3) 최종 선택된 변수·변환, CV 성능, 각 단계의 논문 근거(node_id)를 analysis/highdim_report.md에 한국어로 정리해.
data/_answers 폴더는 열지 마." \
  --allowedTools "mcp__opencrab-http__ontology_query" "mcp__opencrab-http__ontology_impact" \
                 "Read" "Write" "Edit" "Bash(docker compose run --rm lab:*)" \
  --disallowedTools "Read(data/_answers/**)" "Bash(cat:*)"
```

랜덤 포레스트 튜닝 예:

```bash
claude -p "data/rf.csv(타깃 y, 0/1)로 랜덤 포레스트 분류 모델을 만들어줘.
1) opencrab-http MCP의 ontology_query로 등록된 논문에서 RF 하이퍼파라미터(mtry, 노드 최소 크기, 샘플링 비율, 트리 수)의 튜닝 권고를 찾아 node_id와 함께 정리해.
2) 그 권고대로 튜닝할 파라미터와 고정할 파라미터를 정하고, 기본값 대비 튜닝 결과를 nested CV(평가지표: log loss, AUC)로 비교하는 analysis/rf_tuning.py를 만들어 'docker compose run --rm lab python analysis/rf_tuning.py'로 실행해. 사용 가능한 패키지는 numpy, pandas, scipy, scikit-learn뿐이야.
3) 결과와 논문 근거를 analysis/rf_report.md에 한국어로 정리해.
data/_answers 폴더는 열지 마." \
  --allowedTools "mcp__opencrab-http__ontology_query" "mcp__opencrab-http__ontology_impact" \
                 "Read" "Write" "Edit" "Bash(docker compose run --rm lab:*)" \
  --disallowedTools "Read(data/_answers/**)" "Bash(cat:*)"
```

옵션 설명:

| 옵션 | 이유 |
| --- | --- |
| `mcp__opencrab-http__ontology_query`, `…ontology_impact` | 논문 검색·연결 관계 조회 허용 |
| `Read`, `Write`, `Edit` | 데이터 확인, 분석 코드·보고서 작성 |
| `Bash(docker compose run --rm lab:*)` | 분석 코드는 `lab` 컨테이너에서만 실행 |
| `--disallowedTools "Read(data/_answers/**)" "Bash(cat:*)"` | 정답 파일을 읽지 못하게 막음 |

#### 5. 결과 확인과 채점

```bash
ls analysis/                          # *_pipeline.py / *_tuning.py, *_report.md
less analysis/highdim_report.md       # 선택된 변수·변환, CV 성능, 논문 근거(node_id)
cat data/_answers/highdim.truth.json  # 생성 공식과 비교
```

보고서의 node_id(예: `paper-1da5d2d6e08e02f4` SIS, `paper-arxiv-1803.01454` L0Learn)가 실제 등록된
논문인지는 위 "REST API로 논문 조회"의 `/api/impact`나 "등록 확인" 2번으로 확인할 수 있습니다.

실행 예(위 고차원 회귀 명령, 약 15분 소요). Claude는 다음 순서로 진행했습니다.

1. MCP로 노트의 "권장 파이프라인"(`note-81aa83ae2396055b`)과 단계별 논문을 찾았습니다.
   - 스크리닝: SIS `paper-1da5d2d6e08e02f4`
   - 변환 생성: autofeat `paper-arxiv-1901.07329`, SISSO `paper-arxiv-1710.03319`
   - 희소 선택: L0Learn `paper-arxiv-1803.01454`
   - 평가: nested CV `paper-arxiv-2107.05847`
2. 그 순서대로 `analysis/highdim_pipeline.py`를 구현해 실행했습니다.

| 항목 | 결과 |
| --- | --- |
| nested CV R² | 0.821 ± 0.013 (원변수 lasso 0.428, ridge 0.180) |
| 재현성 높은 선택 항 | `x0450²`, `x0000`, `x0120` (15개 fold 중 14~15회) |
| 정답(`data/_answers/highdim.truth.json`)과 비교 | 진짜 신호 6개 중 3개 발견. `log(1+x0777²)`와 상호작용 `x1300*x1301`은 놓침 |

놓친 두 항은 한 변수씩 보는 스크리닝으로는 잡기 어려운 형태입니다. 이런 경우 SIS 논문이 제안하는
ISIS(반복 스크리닝)나 상호작용 후보 생성을 추가하도록 후속 요청하면 됩니다. 예:
"잔차 기반 반복 스크리닝(ISIS)과 상위 변수 쌍의 상호작용 후보를 추가해서 다시 실행해줘".

`claude -p` 실행 중 `API Error: Connection closed mid-response`가 나오면 일시적인 연결 문제이므로
같은 명령을 다시 실행하면 됩니다.

## 데이터 백업 / 복원

```bash
# 백업
docker run --rm -v opencrab_opencrab_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/opencrab_data.tgz -C /data .

# 복원
docker run --rm -v opencrab_opencrab_data:/data -v "$PWD":/backup alpine \
  tar xzf /backup/opencrab_data.tgz -C /data
```

볼륨 이름은 Compose 프로젝트명(기본: 디렉토리명 `opencrab`) 접두사가 붙습니다.
`docker volume ls`로 확인하세요.

## 참고

- **알려진 문제:** `GET /api/nodes`, `GET /api/edges`는 현재 500 에러를 반환합니다. API 코드가
  Neo4j Cypher(`run_query`)를 호출하지만 로컬 그래프 저장소(`LocalGraphStore`)에는 해당 메서드가
  없기 때문입니다. 따라서 웹 대시보드의 그래프 뷰에는 노드가 표시되지 않습니다. 그래프 내용은
  CLI(`opencrab query`)나 MCP 도구로 확인하세요.
- **알려진 문제 (HTTP `/mcp` 쓰기 도구):** `/mcp`의 `ontology_add_node`, `ontology_add_edge`,
  `ontology_ingest`는 저장소 메서드의 인자 순서·이름이 맞지 않아 올바르게 동작하지 않습니다.
  노드·엣지·텍스트 등록은 stdio MCP, CLI, 또는 `scripts/import_paper_notes.py`를 사용하세요.

- `.env.example`의 `STORAGE_MODE=docker`는 현재 코드에서 사용되지 않습니다. 항상 로컬 저장소로 동작합니다.
- 최초 ingest/query 시 Chroma가 임베딩 모델을 내려받으므로 네트워크가 필요하며, 이후에는 `chroma_cache` 볼륨에서 재사용됩니다.
- 코드를 수정한 뒤에는 `docker compose up -d --build`로 이미지를 다시 빌드해야 반영됩니다.
