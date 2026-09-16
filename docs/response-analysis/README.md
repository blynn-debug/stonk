# stonk_response.txt 응답 코드를 통한 실제 조회

이 파일은 문서 텍스트만이 아니라 **About와 Stats 두 HTML 응답을 이어 붙인 자료**다. `<title>` 두 개와 외부 JavaScript 20개를 확인했다. 원본 HTML → script src → StatsClient → 공개 API 및 풀 조회 순서로 데이터를 확보했다. 원본의 오래된 수치를 재현한 것이 아니라, 원본 코드가 사용하는 경로에 새로 요청한 결과다.

## 조회 경로

원본: [stonk_response.txt](../provided/stonk_response.txt). 외부 코드 출처·상태·해시는 [scripts-manifest.json](scripts-manifest.json)에 있다. 20개 JavaScript는 [scripts/](scripts/)에 보관했다.

- [35q7g4fdvyi9m.js](scripts/35q7g4fdvyi9m.js)의 `StatsClient`: `/api/stonkex`, `/api/analytics`, `/api/volume` 조회.
- [1pz4zgu4j2xka.js](scripts/1pz4zgu4j2xka.js)의 `useDexPrices`: `/api/dex-prices` 조회. Stats는 WETH와 STONKEX를 `addrs`·`quotes`에 넣고 `minLiq=0`을 전달한다.
- `35q7g4fdvyi9m.js`의 `useOnchainMc`: Uniswap V3 풀의 `slot0()`와 WETH USD 가격으로 STONKEX 가격·시가총액 계산. 약 30초 간격 조회.
- `stonkex`는 30초, `analytics`는 60초 간격 갱신. `volume`은 `staleTime: Infinity`, `retry: false`; `dex-prices`는 60초 간격.

4개 API 모두 GET으로 HTTP 200과 유효 JSON을 반환했다. [요청 URL·시각·해시](api-manifest.json), [응답 JSON·헤더](api/)를 보관했다. API 조회 시각은 2026-09-16 06:53:52~53 UTC (15:53:52~53 KST)다.

## API 응답 결과

| 항목 | 값 | 출처 |
|---|---|---|
| STONKEX 총공급 | 1,000,000,000 | [stonkex.json](api/stonkex.json) |
| dead 주소 누적 수량 | 87,854,617.823252692959078633 STONKEX | 위 응답 `burned`, 18 decimals 적용 |
| 소각 비율 | 8.7854% | 위 응답 `burnedPct` |
| 바이백 인덱스 일시정지 | false | 위 응답 `paused` |
| 실행 간격 | 900초 | 위 응답 `intervalSeconds` |
| 인덱스 분배 | platform 1000 / creator 0 / burn 9000 bps | 위 응답 `split` |
| 이벤트 | 150개 | 위 응답 `events`; 전체 이력이라는 의미는 아님 |
| 누적 출시 | 823개 | [analytics.json](api/analytics.json) `launches.total` |
| day / week 출시 | 59 / 277개 | 위 응답 필드명 기준; 서버 집계 경계는 확인하지 않음 |
| creator 수 | 336 | 위 응답 `launches.creators` |
| 거래량 USD | 49,196,837 | [volume.json](api/volume.json) |
| DEX 기준 STONKEX 가격 | $0.007468 | [dex-prices.json](api/dex-prices.json) `best.priceUsd` |
| 해당 페어 24시간 거래량 | $628,045 | 위 응답 `best.volume24Usd` |
| 해당 페어 유동성 | $447,425 | 위 응답 `best.liquidityUsd` |

`analytics.updatedAt`은 2026-09-16 06:53:39.620 UTC다. **volume의 `asOf`는 2026-09-15 11:29:52 UTC**로, 조회 시각과 다르다. 이를 현재 24시간 거래량으로 해석하지 않는다.

## 온체인 확인 및 화면 계산

Base 기본 공개 RPC `https://mainnet.base.org`에 읽기 전용 `eth_call`을 수행했다. 원본 프런트엔드의 multicall 대신 같은 함수를 개별 호출 묶음으로 조회했으며, 모든 호출을 **블록 51,376,178**에 고정했다. 프런트엔드에 설정된 공급자 대신 Base 기본 공개 RPC를 사용했다.

- [요청·응답 원본](chain-reads.json): `slot0`, `token0`, `token1`, `totalSupply`, `balanceOf(dead)`.
- [계산 결과](chain-summary.json): pool token0 = WETH, token1 = STONKEX.
- 온체인 totalSupply: **1,000,000,000 STONKEX**.
- 온체인 dead 잔액: **87,858,684.989949528742452618 STONKEX**. API 캐시보다 나중에 조회한 값이다.
- Stats 코드와 같은 정수 비율 계산 및 API WETH 가격을 적용한 토큰 가격: **약 $0.00746490758**.
- Stats 코드가 계산하는 시가총액: **약 $7,464,907.58**. 계산식은 `totalSupply × tokenPrice`이고, dead 잔액을 차감한 유통량 기준 값이 아니다.

`sqrtPriceX96² / 2^192`로 token1/token0 비율을 얻고, STONKEX가 token1이므로 역수를 취해 WETH/STONKEX를 구한다. 코드처럼 10^30 정수 스케일을 적용한 뒤 WETH USD 가격과 곱한다. 풀 상태와 API 캐시 가격은 서로 다른 시점의 관측이다.

## 코드에서 추가 확인한 컨트랙트

| 역할 | 주소 | 소스·ABI |
|---|---|---|
| STONKEX 바이백 인덱스 | `0x44b5c100513e6f625037c039300c5bc72b73dcbd` | [자료](../contracts/StonkexBuybackIndex/) |
| 인덱스 구현 | `0x439a53ca03b2761ea036173e93cfba3b25ffa339` | [자료](../contracts/implementation-0x439a53ca03b2761ea036173e93cfba3b25ffa339/) |
| STONKEX/WETH 풀 | `0x7692AcC1CDd771D09EbCae3663e1843b2911BEC7` | [자료](../contracts/StonkexPool/) |
| Stockify 인덱스 팩토리 | `0x78b50dFFE7250638D6F2A24f56B0849CefA69498` | [자료](../contracts/StockifyIndexFactory/) |

추가 컨트랙트의 수집 기록은 [additional-contracts.json](additional-contracts.json)에 있다. Stats 코드의 STONKEX 자체 creator fee 바이백 경로와 About의 플랫폼 fee splitter 경로는 별개다. Stats/API의 90% burn·10% platform 값을 About의 플랫폼 수수료 80% burn·20% operator 설명과 혼합하지 않는다.

## 재조회

프로젝트 루트에서 실행한다. 재실행은 해당 스냅샷을 갱신한다.

```powershell
py -3 -B docs/inspect_response.py
py -3 -B docs/query_response_apis.py
py -3 -B docs/query_response_chain.py
py -3 -B docs/finalize_archive.py
```

응답 코드의 외부 JavaScript를 텍스트로 분석했으며, 지갑 연결·서명·트랜잭션 전송은 필요하지 않았다. 서버 내부 구현 및 전체 과거 이벤트 이력을 확보했다는 의미는 아니다.
