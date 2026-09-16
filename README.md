# STONKEX — Codex 컨트랙트·홀더 분석

**[최종 PDF 보고서 — Codex](docs/analysis/STONKEX_Contract_Holder_Analysis_Codex.pdf)**

Base의 STONKEX 프로젝트를 컨트랙트 소스·배포 거래·전체 토큰 전송 로그·실제 스왑을 중심으로 분석했다. 기준은 **블록 51,376,534 / 2026-09-16 16:06:55 KST**다.

- 초기 공급·분배, LP 잠금, 운영자 권한, 실제 수수료·소각 경로
- [전체 주소 상위 100개](docs/analysis/top100-addresses.csv): 소각·풀·컨트랙트 포함
- [일반 지갑 상위 100개](docs/analysis/top100-wallets.csv): EOA·위임 EOA·확인된 스마트 지갑
- 잔여 수량 중 매수 원가를 추적한 부분의 이동평균 단가와 추적률
- [거래별 원가 근거](docs/analysis/acquisition-audit.csv), [분석 방법·재현](docs/analysis/README.md)

**평단가는 DEX 체결가 기반 추정치다.** 이전 입금·미지원 거래쌍 등의 원가는 0으로 간주하지 않았다. 일반 지갑 100개 중 전량 추적 18개, 일부 추적 71개, 잔여 원가 추적 불가 11개다. 자세한 정의와 한계는 PDF에 있다.

원본 증거는 GitHub 파일 크기 제한에 맞춰 `docs/analysis/evidence/`의 ZIP으로 보관했다. API 키는 저장하지 않았다. 자료 수집과 보고서 작성: **Codex**.

기존 사이트 응답·소스 아카이브 안내: [docs/README.md](docs/README.md).
