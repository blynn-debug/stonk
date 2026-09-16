# STONKEX 상세 분석 — Codex

최종 결과물: **[PDF 보고서](STONKEX_Contract_Holder_Analysis_Codex.pdf)** · [텍스트 본문](REPORT.md).

## 기준과 산출물

Base chain ID 8453, token `0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5`.

잔액·주요 상태 기준: 블록 **51,376,534**, **2026-09-16 07:06:55 UTC / 16:06:55 KST**. 작성 중 진행된 이후 블록과 섞지 않았다.

| 파일 | 의미 |
|---|---|
| `top100-addresses.csv` | 잔액 기준 전체 주소 상위 100개. 소각 주소·풀·토큰 자기주소 포함 |
| `top100-wallets.csv` | EOA·EIP-7702 위임 EOA·검증된 Coinbase 스마트 지갑 중 상위 100개 |
| `acquisition-audit.csv` | 입금별 거래 해시, 블록, 원가가 배분된 수량·USD·ETH 원가 |
| `evidence/manifest.json` | 분할 ZIP 및 각 원본 파일의 SHA-256 |
| `evidence/raw-*.zip` | 전체 로그, 4,191개 영수증, 상태·오라클·홀더 증거 |

사람별 실소유자 통합은 하지 않았다. 다른 컨트랙트는 최종 수익자를 확정할 수 없어 일반 지갑 표에서 제외했다. 모든 계정은 전체 주소 표에는 그대로 포함한다.

## 평단가의 정확한 의미

`known_remaining_avg_usd`는 **잔여 보유분 가운데 체결 원가가 추적되는 수량만의 이동평균 단가**다. 전체 물량 평균이 아니다. `remaining_cost_coverage_pct`를 반드시 함께 본다.

- `raw_balance`: 18 decimals 적용 전 정수 잔액. `tokens`: 토큰 단위 정확한 잔액.
- `known_remaining_tokens`, `unknown_remaining_tokens`: 원가 추적 가능·미확인 잔여 물량.
- `full_balance_avg_usd`: 미확인 잔여가 10^-9개 이하인 경우에만 표시한 모형상 전체 평균.
- `lifetime_buy_avg_usd`: 전 기간 추적 가능한 매수 수량의 가중 평균. 현재 보유분 평균과 다르다.
- ETH 기준 평균도 별도 열에 저장했다. USDC 매수의 ETH 값은 당시 ETH/USD 환산 값이다.
- 공란은 0달러가 아니라 산출 불가 또는 적용 대상 아님이다.

매도·출금은 알려진/미확인 물량을 기존 비율대로 차감한다. 일반 전송의 송신자 취득원가는 수신자에게 자동 승계하지 않는다. 같은 거래 안의 스왑→라우터→수신자 흐름만 비례 원가를 전달한다. 수신자는 실제 비용 부담자와 다를 수 있으며, 이는 개인별 실지출 원가가 아닌 체결가 기반 추정이다. 가스·별도 라우터 수수료·CEX/OTC 원가 등은 포함하지 않는다.

ETH/WETH는 Base Chainlink ETH/USD 직전 라운드로 환산했다. phase 전환 블록 50,530,334를 이진 탐색으로 확인하고 각 aggregator 로그를 적용했다. USDC=$1 근사이며, 환산할 수 없는 결제자산의 스왑 88건은 미확인으로 남겼다.

## 증거 복원 및 재현

Git에는 대용량 원본 디렉토리 대신 무손실 분할 ZIP을 저장한다. 기존 로컬 `raw/`는 그대로 유지한다.

```powershell
py -3 -m pip install -r docs/analysis/requirements.txt
py -3 -B docs/analysis/restore_evidence.py
py -3 -B docs/analysis/cost_basis.py
py -3 -B docs/analysis/summarize.py
py -3 -B docs/analysis/build_report.py
```

PDF 생성 스크립트는 Windows의 `C:/Windows/Fonts/malgun.ttf`와 `malgunbd.ttf`를 사용한다. 다른 환경에서는 한국어 폰트 경로를 수정해야 한다. 네트워크 재수집은 각 수집 스크립트를 별도로 실행하며, 동일한 기준 블록과 기존 원본을 보존한 상태에서 재현하는 것을 권장한다.

`collect.py`의 Etherscan 조회는 환경변수 `ETHERSCAN_API_KEY`만 읽는다. 제공된 키는 저장하지 않았다. 당시 응답은 Free API Base 체인 지원 제한이었으며, 실제 완료 데이터는 공개 RPC와 BaseScan으로 수집했다.

## 검증 범위

- 배포부터 기준 블록까지 490개 연속 범위에서 548,348개 로그 수집
- 429,787개 Transfer로 7,561개 양의 잔액 주소 재구성
- 총공급 보존·중복 로그 없음·음수 잔액 없음
- 상위 후보 125개를 기준 블록 `balanceOf`로 모두 교차검증
- 선정 거래 영수증과 수집 토큰 로그 수 일치 확인
- 초기·최종 런처/락커 구현 슬롯 일치, LP NFT 실제 소유자 확인
- PDF 본문과 100개씩의 부록 두 표 검증

이는 전문 보안 감사나 독립 컴파일·배포 바이트코드 재현 검증은 아니다. 다른 블록·다른 분모·다른 평균 산식의 보조 자료와 숫자를 섞지 않는다. 별도 `docs/holder-analysis/` 자료가 있는 경우 이 보고서의 주 근거는 본 디렉토리의 고정 블록 데이터다.
