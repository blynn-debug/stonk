"""Build the Korean Codex research report and complete 100-address appendices."""
import datetime,html,json,pathlib
from decimal import Decimal as D
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,PageBreak,KeepTogether
from reportlab.graphics.shapes import Drawing,Rect,String,Line

ROOT=pathlib.Path(__file__).resolve().parent
RAW=ROOT/'raw'
OUT=ROOT/'STONKEX_Contract_Holder_Analysis_Codex.pdf'
pdfmetrics.registerFont(TTFont('Malgun','C:/Windows/Fonts/malgun.ttf'))
pdfmetrics.registerFont(TTFont('MalgunBold','C:/Windows/Fonts/malgunbd.ttf'))
pdfmetrics.registerFontFamily('Malgun',normal='Malgun',bold='MalgunBold',italic='Malgun',boldItalic='MalgunBold')
NAVY=colors.HexColor('#12243A');TEAL=colors.HexColor('#087E8B');GRAY=colors.HexColor('#58677A');PALE=colors.HexColor('#EDF4F7');RED=colors.HexColor('#AD443F')
styles={
 'body':ParagraphStyle('body',fontName='Malgun',fontSize=9,leading=15,spaceAfter=8,textColor=NAVY,wordWrap='CJK'),
 'small':ParagraphStyle('small',fontName='Malgun',fontSize=7.7,leading=12,spaceAfter=6,textColor=GRAY,wordWrap='CJK'),
 'h1':ParagraphStyle('h1',fontName='MalgunBold',fontSize=21,leading=29,spaceAfter=17,textColor=NAVY,wordWrap='CJK'),
 'h2':ParagraphStyle('h2',fontName='MalgunBold',fontSize=12,leading=18,spaceBefore=11,spaceAfter=8,textColor=TEAL,wordWrap='CJK'),
 'cell':ParagraphStyle('cell',fontName='Malgun',fontSize=8,leading=12,wordWrap='CJK',textColor=NAVY),
 'tiny':ParagraphStyle('tiny',fontName='Malgun',fontSize=7,leading=10,wordWrap='CJK',textColor=NAVY),
}
story=[];md=[]
def p(text,style='body'):
    story.append(Paragraph(text,styles[style]));md.append(text.replace('<b>','**').replace('</b>','**').replace('<br/>','\n')+'\n')
def title(text):p(text,'h1')
def h(text):p(text,'h2')
def new():story.append(PageBreak());md.append('\n---\n')
def table(headers,rows,widths=None):
    cells=[[Paragraph(str(c),styles['cell']) for c in headers]]+[[Paragraph(str(c),styles['cell'])for c in row] for row in rows]
    t=Table(cells,colWidths=widths,repeatRows=1,hAlign='LEFT')
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),PALE),('VALIGN',(0,0),(-1,-1),'TOP'),('LINEBELOW',(0,0),(-1,0),.8,TEAL),('LINEBELOW',(0,1),(-1,-1),.25,colors.HexColor('#D5DFE5')),('LEFTPADDING',(0,0),(-1,-1),6),('RIGHTPADDING',(0,0),(-1,-1),6),('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7)]))
    story.append(t);story.append(Spacer(1,9));md.extend([' | '.join(map(str,headers)),' | '.join(['---']*len(headers))]+[' | '.join(map(str,r)) for r in rows]);md.append('')
def fmt(x,n=2):return f'{D(str(x)):,.{n}f}'
def pct(tokens):return fmt(D(tokens)/D(10**7),4)+'%'
def addr(a):return a[:10]+'…'+a[-8:]
def ref(text):p(text,'small')
def bars(items,maxvalue,suffix='%'):
    drawing=Drawing(510,len(items)*32+5)
    for i,(label,value) in enumerate(items):
        y=(len(items)-1-i)*32+7
        drawing.add(String(0,y+4,label,fontName='Malgun',fontSize=8,fillColor=NAVY))
        drawing.add(Rect(145,y,285,17,fillColor=PALE,strokeColor=None))
        drawing.add(Rect(145,y,285*float(value)/maxvalue,17,fillColor=TEAL,strokeColor=None))
        drawing.add(String(440,y+4,f'{float(value):.2f}{suffix}',fontName='MalgunBold',fontSize=8,fillColor=NAVY))
    story.append(drawing);story.append(Spacer(1,10))

def main():
    s=json.loads((RAW/'report-summary.json').read_text());rows=json.loads((RAW/'holder-cost-results.json').read_text());wallets=[r for r in rows if r['role'] in ['EOA','delegated_EOA','smart_wallet']][:100]
    spot=D(s['spot_price_usd']);coverage=D(s['wallet_weighted_coverage_pct']);burn=D(s['dead_tokens']);selfbal=D(s['self_tokens'])
    ts=datetime.datetime.fromtimestamp(int(s['snapshot']['header']['timestamp'],16),datetime.timezone.utc);kst=ts+datetime.timedelta(hours=9)
    p('CODEX  /  ON-CHAIN RESEARCH','small')
    story.append(Spacer(1,24));title('STONKEX<br/>컨트랙트·토크노믹스·홀더 분석')
    p('<b>분석 작성: Codex</b><br/>대상: The Stonks Exchange · Base mainnet (8453)<br/>토큰: 0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5')
    p(f'기준 블록 <b>{s["snapshot"]["block"]:,}</b><br/>기준 시각 {kst:%Y-%m-%d %H:%M:%S} KST / {ts:%H:%M:%S} UTC<br/>수집·작성일 2026-09-16 · 저장 브랜치 codex')
    h('핵심 판단')
    p('<b>고정 공급과 LP 원금 잠금은 소스·온체인 상태로 뒷받침된다.</b> 그러나 수수료 목적지와 플랫폼 바이백 자금은 운영자 권한의 영향을 받는다. 토큰 권한 없음, LP 잠금, 수수료 운영의 무신뢰성은 서로 다른 문제다.')
    p('<b>초기 팀 무상 할당은 배포 거래에서 발견되지 않았다.</b> 10억 개가 런처를 거쳐 풀로 들어갔고, 생성자는 같은 거래에서 0.03 ETH로 약 1,832.69만 개를 매수했다.')
    p('<b>상위 100개 주소의 보유량은 확인했지만, 전원의 개인 평단가는 확정할 수 없다.</b> 일반 지갑 100개 중 89개에서 추적 가능한 매수 원가가 남아 있다. 표의 평단가는 이 추적분의 DEX 체결가 기반 추정치다.')
    table(['검증 항목','결과'],[['총공급 / 양의 잔액 주소','1,000,000,000 STONKEX / 7,561개'],['dead 주소 잔액',f'{fmt(burn,6)} STONKEX ({pct(burn)})'],['전체 주소 상위 100개 집중도',pct(s['address_top100_tokens'])],['일반 지갑 상위 100개 집중도',pct(s['wallet_top100_tokens'])],['주력 풀·오라클 기준 가격',f'${spot:.8f} / STONKEX']], [195,310])
    ref('분석 범위는 이 보고서의 기준 블록까지다. 주소 수는 사람 수가 아니며, 추정 평단가를 실제 세무·회계 취득원가로 간주하지 않는다.')

    new();title('01  무엇을 확인했는가')
    h('증거와 조회 범위')
    table(['자료','수집·검증'],[['토큰·주력 풀 로그','배포 블록 50,397,719부터 51,376,534까지 연속 수집. 총 548,348개 로그, STONKEX Transfer 429,787개, 주력 풀 Swap 118,561개.'],['잔액 재구성','전 주소 입출금을 정수 단위로 재생. 발행량과 전체 잔액 합 일치, 음수 잔액 없음. 상위 후보 125개는 같은 블록 balanceOf로 전부 일치 확인.'],['매수 경로','선정 보유자 관련 거래 영수증 4,191건. Uniswap V2/V3/V4 계열 이벤트와 토큰 전송 경로를 함께 분석.'],['역사적 USD 환산','Base Chainlink ETH/USD의 phase 2·3 오라클 로그 15,045개를 수집. 거래 시점 직전 AnswerUpdated 값을 사용. USDC는 $1로 근사.'],['코드·권한','토큰, 런처·락커 구현, 분배기, Stockify 인덱스·팩토리, 풀 소스와 ABI 및 현재 설정.']], [105,400])
    h('현재의 정의와 표 구분')
    p('분석 중 체인이 계속 진행하므로 모든 잔액과 핵심 설정을 한 블록에 고정했다. 이 보고서에서 “현재”는 2026-09-16 16:06:55 KST의 스냅샷을 뜻한다. PDF를 여는 시점의 실시간 값은 아니다.')
    p('<b>부록 A</b>는 잔액 기준 전체 주소 상위 100개다. 소각 주소, AMM 풀, 자기 토큰 주소, 보관 컨트랙트를 포함한다. <b>부록 B</b>는 EOA·EIP-7702 위임 EOA·소스가 확인된 Coinbase 스마트 지갑 중 상위 100개다. 다른 컨트랙트는 최종 수익자나 소유자를 확정하지 못해 제외했다.')
    p('한 사람이 여러 주소를 보유할 수 있고, 하나의 보관 주소에 여러 사람의 자산이 있을 수 있다. 공통 자금 출처만으로 동일인·팀·내부자라고 판정하지 않았다.')
    h('API 사용 결과')
    p('제공된 Etherscan 키로 Base 조회를 시도했으나 Free API 체인 지원 제한 응답을 받았다. 이후 Base RPC·dRPC 및 BaseScan 공개 검증 자료로 분석을 완료했다. 키는 코드·보고서·저장 데이터에 넣지 않았다.')
    ref('근거: raw/log-coverage.json, reconstruction-summary.json, holders-verification-raw.json, holder-repair-raw.json, receipt-coverage.json, oracle-coverage.json.')

    new();title('02  초기 공급과 실제 분배')
    p('배포 시각: <b>2026-08-24 15:19:45 UTC / 2026-08-25 00:19:45 KST</b>.<br/>생성자: 0x81dd3174d55fcf396e92122881ca591705c4e1e1.')
    table(['단계','온체인에서 확인한 결과'],[['1. 최초 발행','0 주소 → 런처: 1,000,000,000개. StonkToken 생성자의 단일 _mint.'],['2. LP 공급','런처 → 주력 풀: 999,999,999.999999999999992973개. 7,027 wei-token의 반올림 잔여만 런처에 남음.'],['3. 생성자 dev buy','0.03 ETH 소비 → 생성자에게 18,326,925.770262721093259173개. DevBuy 이벤트로 확인.'],['4. 반올림 잔여 정산','7,027 wei-token(0.000000000000007027개)을 생성자에게 전달.'],['거래 종료 후 분포','풀 98.1673074230%, 생성자 1.8326925770%. 배포 거래 내 별도 팀·VC·재단 할당 없음.']], [110,395])
    h('매수가와 초기 가치')
    p('생성자의 순수 풀 체결 평단가는 <b>0.000000001636935751 ETH</b>다. 당시 Chainlink ETH/USD $2,517.4218965를 적용하면 약 <b>$0.00000412085790</b>, 매수 원금 약 <b>$75.52</b>다. 가스비는 포함하지 않았다.')
    p('초기 tick 202600과 같은 ETH/USD로 계산한 오프닝 완전희석가치는 약 <b>$4,004.88</b>다. 이는 사이트의 약 $4,000 목표와 부합한다. 첫 매수 평균은 초기 순간가격과 슬리피지·수수료 때문에 다르다.')
    h('무상 배분·베스팅 여부')
    p('토큰 소스에는 추가 민팅·관리자 전송·거래세·블랙리스트·일시정지·베스팅 스케줄이 없다. creator는 메타데이터 성격의 불변 주소이며, 토큰 자체의 owner 권한이 아니다. LP 잠금도 생성자가 매수한 토큰을 잠그지는 않는다.')
    p('사이트의 FOMO 배포는 dev buy로 산 물량을 재전송하는 방식이다. “매번 1~10%가 별도 발행된다”거나 “STONKEX에 고정 에어드롭 할당이 있다”는 뜻은 아니다. 본 배포 거래에서는 그런 별도 할당을 확인하지 못했다.')
    ref('배포 거래: https://basescan.org/tx/0x03615f1a465b92bbbe75d369b1df35b12758a22af8a5ac5fecb254bb5b13feb6<br/>근거: creation-receipt.json, creation-transaction.json, StonkToken.sol, StonkLauncher2.sol의 _openPoolAndMint·_settleFunds.')

    new();title('03  원금 잠금과 권한 구조')
    table(['계층','확인한 구조','해석'],[['STONKEX 토큰','고정 공급·불변 launcher/creator·추가 민팅 함수 없음','토큰 운영자의 임의 희석이나 전송 차단 경로가 보이지 않음.'],['런처','현재 enforcedSupply=10억 개, launchFeeWei=0. 업그레이드 승인 함수는 무조건 revert','향후 출시 조건·메타데이터·허용 라우터 등은 운영자가 변경 가능.'],['락커','LP NFT #5,872,045 소유자가 락커. NFT 승인 operator=0. _authorizeUpgrade는 revert','원금 감소·NFT 인출 경로가 없는 구조. 수수료 수령 설정과는 별개.'],['주력 풀','WETH / STONKEX, fee=10000(1%), LP tick 범위 -887200~202600','주력 초기 LP가 잠겼어도 다른 풀·LP의 잠금까지 보장하지 않음.'],['현재 공통 운영자','런처·락커·분배기·인덱스의 owner는 생성자 주소','각 계층의 관리자 위험을 합쳐서 봐야 함.']], [82,215,208])
    h('업그레이드와 LP 상태')
    p('배포 블록과 기준 블록의 ERC-1967 구현 슬롯은 각각 같은 주소였다. 런처는 0x6a9f…9806d, 락커는 0x6c9c…25273이다. 저장된 검증 소스의 업그레이드 차단 로직과 함께 현재 구조를 확인했다. 별도의 컴파일·바이트코드 재현 감사까지 수행한 것은 아니다.')
    p('기준 블록의 주력 풀 잔액은 약 <b>37,311,148.13 STONKEX</b> 및 <b>70.41331469 WETH</b>다. 풀 전체 잔액에는 여러 LP의 원금·수수료 등이 섞일 수 있으므로 이를 전부 최초 NFT의 소유 자산이라고 단정하지 않는다.')
    h('운영자가 할 수 있는 일')
    p('락커의 수수료 분배 변경·생성자 역할 변경은 24시간 지연 절차가 있다. 플랫폼 몫 상한 30%, 재유동화 몫 상한 60%, 합계 상한 80%로 생성자 몫 최소 20%가 남는다. 현재는 플랫폼 30%·재유동화 0%·생성자 70%, 대기 중 분배 변경 없음이다.')
    p('반면 플랫폼 feeRecipient 변경은 즉시 가능하다. 생성자 역시 자신의 creator split을 즉시 바꿀 수 있다. LP의 원금 잠금이 수수료 목적지의 영구 고정을 뜻하지 않는다.')
    ref('근거: contract-state.json, extra-state.json, StonkFeeLocker2.sol: _collect, proposeFeeSplit, setFeeRecipient, setCreatorSplit, _authorizeUpgrade.')

    new();title('04  수수료: 설명과 현재 코드의 차이')
    p('사이트는 거래 수수료 1%를 생성자 0.7%·플랫폼 0.3%로 설명한다. 그러나 기준 블록의 주력 풀 <b>slot0.feeProtocol=102(0x66)</b>다. 각 방향의 분모가 6이므로 Uniswap 프로토콜이 스왑 수수료의 <b>1/6</b>을 먼저 가져가고, 나머지가 LP 수수료가 된다.')
    table(['거래액 대비 이론적 비율','명목 설명','현재 주력 풀 상태 반영'],[['총 스왑 수수료','1.000000%','1.000000%'],['Uniswap 프로토콜 몫','별도 언급 없음','0.166667%'],['락커에 귀속되는 LP 수수료','1.000000%로 단순화','약 0.833333%'],['생성자 70% 경로','0.700000%','약 0.583333%'],['플랫폼 30% 경로','0.300000%','약 0.250000%']], [200,130,175])
    p('위 비율은 현재 파라미터를 거래액에 적용한 근사치다. 실제 수수료는 스왑 방향·수수료 자산·반올림·해당 LP의 유동성 점유율에 영향을 받으며, 모든 거래가 최초 LP 한 개에 귀속되는 것은 아니다.')
    h('STONKEX 생성자 수수료 → Stockify 인덱스')
    p('현재 creator split은 인덱스 0x44b5…dcbd 한 곳에 100%다. 인덱스는 mode=1, creatorShareBps=0, 900초 간격으로 설정돼 있다. Stockify 팩토리의 platformFeeBps는 1000(10%)다. 따라서 quote 측 생성자 몫의 90%가 바이백 재원이 되고 10%는 Stockify 몫이다. 현재 풀 가정에서 거래액의 약 0.525%가 이 바이백 경로에 해당한다.')
    h('플랫폼 수수료 → StonkFeeSplitter')
    p('현재 profitBps=2000(20%)로, 나머지 80%는 가치자산을 STONKEX로 매수해 <b>retained로 보관</b>한다. process 함수 자체는 dead 주소로 보내지 않는다. 소유자는 profit 비율을 최대 50%로 바꾸거나, 매수 토큰·수령자·keeper·허용 자산을 변경하고, sweep/rescue/sellViaVelora를 실행할 수 있다.')
    ref('근거: extra-state.json의 pool.slot0, UniswapV3Pool.sol 681~685행; StonkFeeSplitter.sol process·setProfitBps·sweep; IndexFactory.sol setPlatformFee. 인덱스 팩토리 수수료 상한은 20%다.')

    new();title('05  실제 소각과 보장 수준')
    p(f'기준 블록까지 dead 주소에 들어간 총량은 <b>{fmt(burn,6)}개</b>, 총공급의 <b>{pct(burn)}</b>다. 토큰의 totalSupply는 여전히 10억 개다. 이 프로젝트의 소각은 ERC-20 _burn으로 총공급을 줄이는 방식이 아니라, dead 주소로 보내 유통에서 제외하는 방식이다.')
    table(['dead로 보낸 주소','누적 수량','역할'],[[addr(a),fmt(q,6),'Stockify 인덱스' if a.startswith('0x44b5') else '수수료 분배기' if a.startswith('0xfbc9') else '생성자 지갑']for a,q in s['burn_sources_tokens'].items()],[180,165,160])
    h('분배기에서도 실제 소각은 있었다')
    p('분배기발 dead 전송은 481회 확인됐다. 마지막 표본 거래는 소유자가 <b>sweep(STONKEX, dead)</b>를 호출한 거래다. 따라서 “분배기가 전혀 소각하지 않았다”는 해석은 틀리다. 정확한 차이는 <b>과거에 운영자가 소각한 실적은 있지만 process 코드가 그 목적지를 강제하지 않는다는 것</b>이다.')
    p('인덱스는 별도 burn() 함수가 있으며 누구나 호출할 수 있다. 해당 함수는 보유 STONKEX를 고정 BURN 주소로 보낸다. 그러나 인덱스로 들어올 미래 수수료의 목적지는 현재 영구 고정 상태가 아니다(bindIsPermanent=false). 생성자는 락커의 split을 변경할 수 있다.')
    h('생성자 보유와 자금 이동')
    p('생성자 주소의 현재 STONKEX 잔액은 <b>408.875752개</b>다. 토큰 출금 기록은 인덱스로 약 2,110.09만 개, dead로 약 386.46만 개, 다른 한 주소로 1만 개가 확인된다. 이 주소에서 다른 팀 지갑이나 우회 매도가 없었다고 증명하는 자료는 아니며, 다른 주소의 실제 소유관계는 분석하지 않았다.')
    h('자기 토큰 주소에 있는 잔액')
    p(f'19위인 STONKEX 컨트랙트 자체에 <b>{fmt(selfbal,6)}개({pct(selfbal)})</b>가 있다. 소스상 이를 꺼낼 함수는 보이지 않는다. dead 잔액과 별도 표시했으며, 일반 투자자의 매수 평단가를 붙이지 않았다. 이 물량까지 단순 차감할 경우 공급 분모가 달라지므로 표의 지분율은 일관되게 10억 개 기준이다.')
    ref('표본: https://basescan.org/tx/0xfb8ff031527e49e3b59c74f4ef1a066ac244e990e88a91d37e288ef6285a6f63<br/>근거: splitter-burn-transaction.json, creator-flows.json, report-summary.json.')

    new();title('06  보유 집중도와 주소의 성격')
    bars([('주소 기준 상위 100',D(s['address_top100_tokens'])/10**7),('일반 지갑 상위 100',D(s['wallet_top100_tokens'])/10**7),('주소 기준 상위 10',D(s['address_top10_tokens'])/10**7),('일반 지갑 상위 10',D(s['wallet_top10_tokens'])/10**7),('dead 주소',burn/10**7),('주력 풀',D(rows[1]['tokens'])/10**7)],80)
    p(f'전체 주소 상위 100개는 공급의 <b>{pct(s["address_top100_tokens"])}</b>를 차지한다. 하지만 이 값을 곧바로 “상위 100명 고래의 물량”이라고 부르면 소각·풀·자기주소 보유량까지 투자자 물량으로 계산하게 된다.')
    p(f'일반 지갑 상위 100개는 <b>{fmt(s["wallet_top100_tokens"],6)}개({pct(s["wallet_top100_tokens"])})</b>, 상위 10개는 <b>{pct(s["wallet_top10_tokens"])}</b>다. 여러 주소의 동일 소유자 여부를 모르는 상태에서, 이는 주소별 집중도의 하한·상한을 확정하는 분석도 아니다.')
    table(['주의할 주소','보유량 / 분류'],[['1위 dead',fmt(rows[0]['tokens'],2)+'개 / 소각 주소'],['2위 주력 풀',fmt(rows[1]['tokens'],2)+'개 / AMM 유동성'],['6위 0xfa14…f9c3e',fmt(rows[5]['tokens'],2)+'개 / Coinbase 스마트 지갑; 일반 지갑 표에 포함'],['11위 0xba72…36e71',fmt(rows[10]['tokens'],2)+'개 / 다른 토큰과의 AMM 풀'],['37·55·84위 컨트랙트','미검증 코드 또는 보관·트레이딩 구조. 최종 수익자를 확정할 수 없어 일반 지갑 표에서 제외.'],['78위 PoolManager',fmt(rows[77]['tokens'],2)+'개 / Uniswap V4의 공동 보관 주소']], [190,315])
    p('주소 전체 표에는 위 항목을 그대로 남겼다. 일반 지갑 표에서는 제외 기준을 명시했으며, EIP-7702 위임 코드를 가진 EOA를 단순 컨트랙트로 오인해 제외하지 않았다.')
    ref('근거: all-holders-reconstructed.json, holders-verified.json, top100-addresses.csv, top100-wallets.csv. 소스가 없는 주소의 운영 주체는 추정하지 않았다.')

    new();title('07  평단가의 산식과 한계')
    h('보고서에서 사용하는 평단가')
    p('<b>잔여 추적분 평단가 = 현재 남아 있는, 매수 체결가를 추적할 수 있는 수량의 원가 ÷ 해당 수량.</b> 매도·출금 시 알려진 물량과 원가를 기존 잔액 비율대로 줄이는 이동평균 모형을 적용했다. FIFO·개별 지정 원가나 거래소 계정의 표시 평단가와 다를 수 있다.')
    p('실제 Swap 이벤트의 quote 투입량과 STONKEX 출고량을 대응시킨다. 라우터를 거친 경우 같은 거래 안의 STONKEX 전송에 원가를 비례 배분한다. 같은 거래에서 거친 주소의 기존 잔액은 미확인 원가로 두며, 다른 거래에서 들어온 일반 전송은 보내는 사람의 취득원가를 자동 승계하지 않는다.')
    p('이 방식은 DEX 수수료가 포함된 풀 체결 비용을 반영한다. 별도 라우터 수수료·가스·MEV 팁·CEX 입출금 및 장외 지급액은 모두 반영한 개인 실지출 원가가 아니다. 토큰으로 차감된 라우터 수수료가 있으면 경로별 비례 배분과 실제 투자자 부담액이 다를 수 있다.')
    h('통화 환산과 추적 범위')
    p('WETH·ETH 결제는 당시 ETH/USD 오라클로 환산했다. 분석 기간 중 오라클이 phase 2에서 3으로 바뀌어, 전환 블록 <b>50,530,334</b>를 확인하고 각각의 기록을 사용했다. 매수 직전 오라클값은 시장 체결 순간의 USD 현금 가격과 완전히 같지 않을 수 있다. USDC 결제는 $1 가정이다.')
    p('확인한 V2/V3 계열 6개 토큰 페어와 관련 V4 풀을 조사했다. 결제 토큰 가격을 신뢰성 있게 환산하지 못한 스왑 88건은 미확인으로 처리했다. 전송·에어드롭·보관 이동의 원가도 0원으로 채우지 않았다.')
    table(['일반 지갑 100개 결과','개수 / 비율'],[['보유 전량을 모형상 거의 모두 추적','18개 (원가 미확인 잔여 10^-9개 이하 기준)'],['일부만 추적','71개'],['잔여 물량의 원가 추적 불가','11개'],['보유 수량 가중 추적률',f'{coverage:.4f}%']], [330,175])
    ref('부록의 평균 가격은 전체 보유 평단가가 아니라 추적분의 값이다. “—”는 0달러가 아니라 산출 불가 또는 개인 평단가 적용 대상 아님을 뜻한다. CSV에는 전량 모형 평균·누적 매수 평균·ETH 기준 평균도 별도 저장했다.')

    new();title('08  상위 지갑 사례와 해석')
    examples=[rows[i-1]for i in [3,4,5,6,7,8,9,10,13]]
    table(['주소 순위 / 주소','보유량','추적분 평단가','추적률'],[[str(r['rank'])+' / '+addr(r['address']),fmt(r['tokens'],2),'—' if r['known_remaining_avg_usd']is None else '$'+fmt(r['known_remaining_avg_usd'],8),fmt(r['remaining_cost_coverage_pct'],2)+'%']for r in examples],[175,120,120,90])
    p('<b>3위:</b> 약 3,539.66만 개를 보유하지만 추적률은 약 69.97%다. $0.00276656은 추적 가능한 물량의 평단가이며, 전체 보유분의 손익 계산에 그대로 적용하면 안 된다.')
    p('<b>4위:</b> 약 2,826.17만 개 중 추적률이 약 16.96%다. 낮은 표시 평단가만 보고 매우 큰 평가이익을 추정할 근거가 부족하다.')
    p('<b>7위:</b> 약 1,970.66만 개의 잔여 물량이 모형상 전량 추적된다. 추정 평단가 $0.01271524는 기준 시점의 주력 풀 가격보다 높다. 다른 계정의 헤지나 장외 거래가 없는 상태라고 가정해야만 단순 평가손익을 계산할 수 있다.')
    p('<b>8·9위:</b> 현재 잔여 물량에 대해 연결할 수 있는 매수 원가가 없다. 원가 0원·무상 취득·내부자 할당이라고 단정하지 않는다. 별도 지갑 이동이나 장외 지급이 있을 수 있다.')
    h('왜 누적 매수 평균과 보유분 평균이 다른가')
    p('여러 가격에 매수한 뒤 일부 매도하고 다시 매수하면, 과거 모든 매수의 수량가중 평균과 지금 남은 수량의 이동평균 원가는 달라진다. PDF는 잔여 추적분 평균을 중심으로 표시하고, CSV에는 lifetime_buy_avg_usd를 추가해 두 값을 비교할 수 있게 했다.')
    ref('완전한 주소·18자리 잔액·추정값·추적률·매수 거래 수는 첨부 CSV와 뒤의 100개 표에 수록했다. acquisition-audit.csv에서 거래 해시까지 역추적할 수 있다.')

    new();title('09  종합 평가와 재현 자료')
    table(['평가 영역','확인된 사실 / 남는 위험'],[['공급 통제','고정 공급·관리자 없는 토큰은 강점. 단, 토큰 metadata URL의 공통 도메인 등은 런처 운영 설정 영향을 받음.'],['LP 원금','최초 LP NFT의 락커 소유와 업그레이드 차단을 확인. 시장가격·유동성 깊이·다른 풀의 안전을 보장하지는 않음.'],['가치 귀속','STONKEX 생성자 수수료는 현재 바이백 인덱스로 연결. 플랫폼 분배기는 매수 후 보관하며 실제 소각은 운영자 sweep 실적이 존재.'],['운영 권한','수수료 목적지·creator split·분배기 보유자산에 재량이 남음. 일부 변경만 24시간 지연이며 모든 운영 행위가 지연되는 것은 아님.'],['keeper와 외부 의존','분배기 소스는 keeper가 공급하는 라우트와 minBuyOut에 대한 신뢰를 명시. Stockify의 keeper·venue·수수료 설정에도 의존.'],['주식 토큰 연동','이 플랫폼의 다른 출시 코인은 B20 자산의 발행자 정책·오라클에 의존할 수 있음. 분석 대상 STONKEX의 주력 quote는 주식이 아니라 WETH.'],['보유 분포','일반 지갑 상위 100개가 약 59.73% 보유. 신원·실소유자 통합과 중앙화 거래소 내부 원가는 확인 불가.']], [105,400])
    h('확인 결과의 실무적 의미')
    p('이 프로젝트는 “토큰과 최초 LP의 임의 변경을 제한하는 구조”와 “수수료·바이백을 운영하는 관리 구조”가 함께 존재한다. 소각 실적은 실제 전송으로 확인됐지만 미래의 동일한 실행을 무조건 보장하는 것은 아니다. 홀더 평균 단가 역시 자료가 확보된 범위에서만 비교해야 한다.')
    h('재현·검증 파일')
    p('docs/analysis/의 PDF·top100-addresses.csv·top100-wallets.csv·acquisition-audit.csv가 최종 산출물이다. evidence/의 분할 ZIP에는 원본 RPC 응답·전체 범위 로그·영수증·상태 증거가 있으며 manifest.json에 SHA-256이 있다. restore_evidence.py로 원본을 복원할 수 있다.')
    p('checksums와 별개로 토큰 총공급 보존, 연속 블록 범위, 중복 로그 없음, 음수 잔액 없음, 125개 잔액 교차검증, 거래 영수증과 토큰 로그 수 일치를 확인했다. 전문 보안감사·컴파일 재현·경제 모델 스트레스 테스트를 수행한 보고서는 아니다.')
    ref('분석 작성: Codex · 사용자 제공 응답 코드와 공개 온체인 자료 기반 · 사용자 API 키 미포함.')

    new();title('10  주요 출처와 데이터 읽는 법')
    sources=[('토큰·검증 소스','https://basescan.org/address/0x5ab000ff9B9FfE0349CE5ffA5fD86f217C3680F5#code'),('런처','https://basescan.org/address/0x4714f6EC81639Ca59EEBE634490a4d8671DCe7B4#code'),('락커','https://basescan.org/address/0x71D1D363176723f85d98B8B430DF33cde89f0A7f#code'),('플랫폼 분배기','https://basescan.org/address/0xfBC9eE130f1CFeeb192b18CF1202865d757FA680#code'),('바이백 인덱스','https://basescan.org/address/0x44b5c100513e6f625037c039300c5bc72b73dcbd#code'),('주력 풀','https://basescan.org/address/0x7692AcC1CDd771D09EbCae3663e1843b2911BEC7#code'),('Chainlink ETH/USD','https://data.chain.link/feeds/base/mainnet/eth-usd'),('프로젝트 설명','https://www.thestonks.exchange/about'),('Stats','https://www.thestonks.exchange/stats'),('Etherscan 홀더 API','https://docs.etherscan.io/api-reference/endpoint/tokenholderlist')]
    for label,url in sources:
        p(f'<b>{label}</b><br/><link href="{url}" color="#087E8B">{url}</link>','small')
    h('부록 표의 공통 규칙')
    p('보유량은 STONKEX 단위이며, PDF는 소수점 6자리로 반올림했다. CSV에는 정수 원시 잔액과 18자리 소수 단위가 함께 있다. 지분율의 분모는 총공급 10억 개다. 모든 주소는 생략 없이 표에 표시하고 BaseScan 링크를 연결했다.')
    p('<b>추적분 평단가(USD)</b>는 알려진 잔여 원가/알려진 잔여 수량이다. <b>추적률</b>은 알려진 잔여 수량/전체 잔여 수량이다. 예를 들어 추적률 20%의 평균을 나머지 80%에 적용하지 않는다. “—”는 산출 불가 또는 의미 없는 계정 유형이다.')
    p('일반 지갑 표에서의 순위는 풀·소각·기타 컨트랙트를 제외하고 다시 매겼다. 원래 전체 주소 순위는 주소 아래에 병기했다. 동일인 판정은 수행하지 않았다.')

    role_ko={'burn_address':'소각 주소','token_self_balance':'토큰 자기주소','uniswap_v3_pool':'Uniswap V3 풀','amm_pool':'AMM 풀','uniswap_v4_pool_manager':'V4 PoolManager','smart_wallet':'Coinbase 스마트 지갑','EOA':'EOA','delegated_EOA':'위임 EOA','contract':'기타 컨트랙트'}
    for section,data in [('A  전체 주소 상위 100',rows[:100]),('B  일반 지갑 상위 100',wallets)]:
        for start in range(0,100,20):
            new();title(f'부록 {section}')
            p(f'{start+1}–{start+20}위 · 블록 51,376,534 · 잔여 추적분 평단가 · 별도 수수료·가스 제외','small')
            headers=['순위','주소 / 유형','보유량','지분율','추적분 평단가<br/>(USD)','추적률']
            cells=[[Paragraph(x,styles['tiny'])for x in headers]]
            for i,r in enumerate(data[start:start+20],start+1):
                a=r['address'];label=role_ko.get(r['role'],r['role']);fullavg=r['known_remaining_avg_usd'];cov=r['remaining_cost_coverage_pct']
                atext=f'<link href="https://basescan.org/address/{a}" color="#087E8B"><font name="Courier" size="6.2">{a}</font></link><br/><font size="6.6">{label} · 전체주소 #{r["rank"]}</font>'
                values=[str(i),atext,fmt(r['tokens'],6),fmt(D(r['tokens'])/10**7,4)+'%','—' if fullavg is None else '$'+fmt(fullavg,8),'—' if cov is None else fmt(cov,2)+'%']
                cells.append([Paragraph(str(x),styles['tiny'])for x in values])
            t=Table(cells,colWidths=[24,175,100,48,90,68],repeatRows=1)
            t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),PALE),('VALIGN',(0,0),(-1,-1),'MIDDLE'),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#F7FAFB')]),('LINEBELOW',(0,0),(-1,0),.8,TEAL),('LEFTPADDING',(0,0),(-1,-1),3),('RIGHTPADDING',(0,0),(-1,-1),3),('TOPPADDING',(0,0),(-1,-1),4),('BOTTOMPADDING',(0,0),(-1,-1),4)]))
            # Appendix tables use a smaller font and exactly 20 rows, keeping full addresses visible.
            story.append(t);story.append(Spacer(1,10));ref('추적률이 100% 미만인 평단가는 전체 보유분의 평단가가 아니다. — = 0이 아닌 미확인/N.A. · 상세 산식과 ETH 기준 값은 CSV 참조.')
            md.append(f'표: {"top100-addresses.csv" if section.startswith("A") else "top100-wallets.csv"}, {start+1}–{start+20}위\n')
    def footer(c,doc):
        c.saveState();w,h=A4;c.setStrokeColor(colors.HexColor('#D5DFE5'));c.line(36,38,w-36,38)
        c.setFont('Malgun',7);c.setFillColor(GRAY);c.drawString(36,25,'Codex | STONKEX on-chain research | 2026-09-16');c.drawRightString(w-36,25,str(doc.page));c.restoreState()
    doc=SimpleDocTemplate(str(OUT),pagesize=A4,rightMargin=36,leftMargin=36,topMargin=38,bottomMargin=50,title='STONKEX 컨트랙트·토크노믹스·홀더 분석 — Codex',author='Codex')
    doc.build(story,onFirstPage=footer,onLaterPages=footer)
    (ROOT/'REPORT.md').write_text('\n'.join(md),encoding='utf-8')
    print(OUT,OUT.stat().st_size,flush=True)

if __name__=='__main__':main()
