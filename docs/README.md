# Stonks 문서 아카이브

최종 상세 분석: **[Codex PDF 보고서](analysis/STONKEX_Contract_Holder_Analysis_Codex.pdf)** · [상위 100 홀더·평단가 및 재현 자료](analysis/README.md).

수집일: 2026-09-16. 문서와 수집 도구를 모두 이 `docs` 디렉토리에 보관한다.

**응답 코드를 이용한 실제 조회:** [stonk_response.txt 분석 및 API·온체인 조회 결과](response-analysis/README.md). 사용자의 의도에 맞춰 응답에 참조된 JavaScript를 추적하고 Stats의 API 4개와 풀·토큰 읽기 호출을 실행했다.

**컨트랙트 중심 상세 분석 (2026-09-16):** [초기 토크노믹스 분배 · 상위 100 홀더 보유량과 평단가](holder-analysis/README.md) — 최종 산출물 [PDF 보고서](holder-analysis/STONKEX-onchain-analysis-2026-09-16.pdf). 작성: Claude.

## 사용자 제공 자료

- [브라우저 요청·응답 헤더](provided/browser-requests.txt): About / Stats의 사용자 제공 기록. 수집 시점의 헤더와 구분하며 중복 필드도 보존했다.
- [About 본문](provided/about-user.txt): 사용자가 붙여 넣은 본문 전체 내용. 줄바꿈·티커 표기는 정리했고 동일한 티커 2회 반복은 1회로 합쳤다. 가격과 블록 번호는 사용자 화면의 당시 값이다.
- [바탕화면 원본](provided/stonk_response.txt): 실제 발견한 `C:\Users\user\OneDrive\바탕 화면\stonk_response.txt`의 바이트 그대로 복사. 요청에서 언급한 `stonk.txt`라는 정확한 파일명은 발견하지 못했다.
- [원본에서 추출한 텍스트](provided/stonk_response.extracted.txt), [원본 경로·해시](provided/local-file.json).

## 사이트 응답

| 페이지 | 원본 HTML | 읽기용 텍스트 | 응답 헤더 | 링크 |
|---|---|---|---|---|
| [About](https://www.thestonks.exchange/about) | [HTML](site/about.html) | [TXT](site/about.txt) | [헤더](site/about.headers.txt) | [링크](site/about.links.json) |
| [Stats](https://www.thestonks.exchange/stats) | [HTML](site/stats.html) | [TXT](site/stats.txt) | [헤더](site/stats.headers.txt) | [링크](site/stats.links.json) |

Stats HTML 자체에는 `reading the chain` 로딩 상태가 포함된다. 이후 원본 응답이 참조한 JavaScript 20개를 수집·분석하여 실제 API 응답과 온체인 조회 결과를 `response-analysis/`에 추가했다. 전체 거래 이력과 이미지·폰트까지 복제한 오프라인 사이트는 아니다.

## 컨트랙트

Base, chain ID `8453`. 각 폴더의 `page.html` / `page.txt`는 BaseScan 페이지, `page.headers.txt`는 응답 헤더, `abi.json`은 공개 ABI, `sources/`는 페이지에서 추출한 Solidity 파일과 라이브러리, `metadata.json`은 URL·수집 시각·주소·추출 결과다.

| 이름 | 주소 | 저장 폴더 |
|---|---|---|
| STONKEX | `0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5` | [자료](contracts/STONKEX/) |
| StonkLauncher2 | `0x4714f6EC81639Ca59EEBE634490a4d8671DCe7B4` | [자료](contracts/StonkLauncher2/) |
| StonkFeeLocker2 | `0x71D1D363176723f85d98B8B430DF33cde89f0A7f` | [자료](contracts/StonkFeeLocker2/) |
| StonkQuoteRegistry2 | `0x4db9F13325A83662cf992184bc070755a212e95B` | [자료](contracts/StonkQuoteRegistry2/) |
| StonkTradeRouter3 | `0x01F178473DcaC0CE4b2B2111BecFB074b586dd12` | [자료](contracts/StonkTradeRouter3/) |
| StonkQuoter | `0x2826DF040b68F528f5DEF00A5727e14691B755b4` | [자료](contracts/StonkQuoter/) |
| StonkDisperse | `0x3e3F3A9f15614FA40244219F025C88602db58e1c` | [자료](contracts/StonkDisperse/) |
| StonkFeeSplitter | `0xfBC9eE130f1CFeeb192b18CF1202865d757FA680` | [자료](contracts/StonkFeeSplitter/) |

STONKEX의 [토큰 페이지 원본](contracts/STONKEX/token.html)도 별도 보관했다.

BaseScan의 해당 주소 Implementation 표시에서 확인한 구현 컨트랙트:

- 런처: [0x6a9f14e7742e8972fcf86429c5aa7db56589806d](contracts/implementation-0x6a9f14e7742e8972fcf86429c5aa7db56589806d/)
- 락커: [0x6c9c9fd81b914a59585d966af140211df0325273](contracts/implementation-0x6c9c9fd81b914a59585d966af140211df0325273/)

각 구현의 소스·ABI도 저장했다. `implementation-0x000100abaad02f1cfc8bbe32bd5a564817339e72/`는 거래 목록에 나타난 추가 참조 주소 자료이며, 위 8개 컨트랙트의 구현으로 확인된 주소가 아니다. 폴더명만으로 구현 관계를 해석하지 않는다.

About의 보안·권한·수수료 설명은 사이트 작성자의 설명으로 보관했다. 독립적인 코드 감사나 배포 바이트코드 검증은 수행하지 않았다. BaseScan의 별도 탭·페이지네이션 전체는 포함하지 않는다. 응답 코드에서 발견한 추가 컨트랙트 4개와 제한된 온체인 상태 조회는 `response-analysis/`에 출처와 함께 정리했다.

## 출처와 검증

- [manifest.json](manifest.json): 다운로드 URL, UTC 시각, HTTP 결과, 원본 SHA-256, 소스·ABI 확보 여부.
- [checksums.json](checksums.json): 저장 파일별 SHA-256.
- [archive.py](archive.py): 사이트·컨트랙트 자료 재수집 (`py -3 docs/archive.py`, 기존 스냅샷 갱신).
- [finalize_archive.py](finalize_archive.py): 로컬 파일 동일성, HTML 해시, ABI JSON, Solidity 파일 수 확인 및 체크섬 생성 (`py -3 -B docs/finalize_archive.py`). 원본 바탕화면 파일 경로가 필요하다.

최초 연결 확인용 응답은 `about.html`, `launcher-check.html`에도 남겨 두었다. 정리된 본 자료는 `site/`와 `contracts/`를 기준으로 사용한다.
