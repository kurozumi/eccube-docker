// EC-CUBE のフロントに負荷をかける k6 のシナリオ（bin/loadtest.sh から動かす。docs/loadtest.md）。
//
// **「毎秒何 PV」で流す（到着数を固定する open model）。** VU の数で流すと、サーバーが遅くなるほど
// 流す量も減り、限界より手前で「まだ余裕がある」ように見えてしまう。ramping-arrival-rate は
// 遅くなっても同じ数を送り続けるので、詰まったところがそのまま数字に出る。
//
// 流すもの（1 回の繰り返し = 1 ページ）
//   browse … ログインしていない人の閲覧。トップ・商品一覧・カテゴリ・検索・商品詳細を実際の比率で混ぜる
//   cart   … 商品詳細 → カートに入れる（Ajax）→ カート画面。RATE × CART_RATIO 回/秒（1 回で 3 PV）
// **注文までは流さない。** 本物の受注・在庫の引き当て・メールが作られる。カートの行（dtb_cart）は増える。
//
// 静的ファイル（CSS / JS / 画像）は取りに行かない。本番では CDN や nginx の長期キャッシュが返すもので、
// PHP と DB の限界を測るのに混ぜると数字がぼやける。
//
// 環境変数（bin/loadtest.sh が渡す）
//   BASE_URL     … 例 http://127.0.0.1:8080（末尾の / なし）
//   PROFILE      … smoke | load | stress | spike
//   RATE         … 山の PV/秒（browse の分）
//   DURATION     … load の山を保つ時間（例 5m）
//   RAMP         … load の上り時間（例 2m）
//   CART_RATIO   … browse に対する cart の割合（0〜1）
//   MAX_VUS      … 同時に待てる仮想ユーザーの上限（遅くなるとここまで増える）
//   P95_MS       … 合格とする 95 パーセンタイルの応答時間
import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';

const BASE = (__ENV.BASE_URL || '').replace(/\/+$/, '');
const PROFILE = __ENV.PROFILE || 'smoke';
const RATE = Math.max(1, Number(__ENV.RATE || 10));
const DURATION = __ENV.DURATION || '5m';
const RAMP = __ENV.RAMP || '2m';
const CART_RATIO = Math.min(1, Math.max(0, Number(__ENV.CART_RATIO || 0.1)));
const MAX_VUS = Number(__ENV.MAX_VUS || Math.max(50, RATE * 20));
const P95_MS = Number(__ENV.P95_MS || 1000);

if (!BASE) {
  throw new Error('BASE_URL がありません（bin/loadtest.sh から動かしてください）');
}

const cartAdded = new Counter('cart_added');

// stress は段ごとに数字を出す（全部まとめた数字では、どの段で崩れ始めたかが読めない）。
// 1 段 = 上り 30 秒 + 保つ 2 分。各リクエストに「いまの段」（目標の PV/秒）の印を付ける
const STRESS_STEPS = [0.25, 0.5, 0.75, 1, 1.25, 1.5];
const STEP_SEC = 150;
const stepLabels = STRESS_STEPS.map((x) => String(Math.max(1, Math.round(RATE * x))));
function markStep() {
  if (PROFILE !== 'stress') return;
  const sec = (Date.now() - exec.scenario.startTime) / 1000;
  exec.vu.tags.step = stepLabels[Math.min(stepLabels.length - 1, Math.max(0, Math.floor(sec / STEP_SEC)))];
}

// ── 流し方 ──
function stages(rate) {
  const r = (x) => Math.max(1, Math.round(rate * x));
  switch (PROFILE) {
    case 'smoke': // 動くかだけ。1 PV/秒で 30 秒
      return [{ target: 1, duration: '30s' }];
    case 'load': // 想定の山まで上げて保つ
      return [
        { target: r(1), duration: RAMP },
        { target: r(1), duration: DURATION },
        { target: 0, duration: '30s' },
      ];
    case 'stress': // 山の 25% 刻みで 150% まで。どこで崩れるかを見る
      return STRESS_STEPS.flatMap((x) => [
        { target: r(x), duration: '30s' },
        { target: r(x), duration: '2m' },
      ]).concat([{ target: 0, duration: '30s' }]);
    case 'spike': // 平常（10%）から 10 秒で山へ。セールの開始やメルマガの直後
      return [
        { target: r(0.1), duration: '1m' },
        { target: r(1), duration: '10s' },
        { target: r(1), duration: '1m' },
        { target: r(0.1), duration: '10s' },
        { target: r(0.1), duration: '1m' },
        { target: 0, duration: '10s' },
      ];
    default:
      throw new Error(`PROFILE が不明です: ${PROFILE}（smoke / load / stress / spike）`);
  }
}

function scenario(exec, rate) {
  return {
    executor: 'ramping-arrival-rate',
    exec,
    startRate: 0,
    timeUnit: '1s',
    preAllocatedVUs: Math.min(MAX_VUS, Math.max(5, Math.ceil(rate * 2))),
    maxVUs: MAX_VUS,
    stages: stages(rate),
  };
}

const scenarios = { browse: scenario('browse', RATE) };
if (CART_RATIO > 0 && PROFILE !== 'smoke') {
  scenarios.cart = scenario('cart', Math.max(1, RATE * CART_RATIO));
}
if (PROFILE === 'smoke' && CART_RATIO > 0) {
  scenarios.cart = scenario('cart', 1);
}

export const options = {
  scenarios,
  // 合格の線。落ちても最後まで流す（どこで崩れたかを数字に残すため）
  // ページごとの行は、しきい値を書いたものしか結果に出ない（k6 の仕様）ので、全種類に書く
  thresholds: Object.assign(
    {
      http_req_failed: ['rate<0.01'],
      'http_req_duration{kind:page}': [`p(95)<${P95_MS}`],
      checks: ['rate>0.99'],
    },
    Object.fromEntries(
      ['top', 'list', 'category', 'search', 'detail', 'add_cart', 'cart']
        .map((n) => [`http_req_duration{name:${n}}`, [`p(95)<${P95_MS}`]]),
    ),
    // 段ごとの行を出すためだけのしきい値（合否には効かない）
    PROFILE === 'stress'
      ? Object.fromEntries(stepLabels.flatMap((s) => [
        [`http_req_duration{step:${s}}`, ['max>=0']],
        [`http_reqs{step:${s}}`, ['count>=0']],
        [`http_req_failed{step:${s}}`, ['rate>=0']],
      ]))
      : {},
  ),
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  // 遅れて VU が足りなくなったら、それも結果（dropped_iterations）に出す
  discardResponseBodies: false,
  userAgent: 'eccube-docker-loadtest (k6)',
};

// ── 事前に商品とカテゴリを集める ──
export function setup() {
  const top = http.get(`${BASE}/`, { tags: { name: 'setup' } });
  if (top.status !== 200) {
    fail(`トップが ${top.status} を返しました。BASE_URL（${BASE}）と、サイトが開いているかを確かめてください`);
  }
  const categories = uniq((top.body.match(/category_id=(\d+)/g) || []).map((s) => s.split('=')[1]));
  const ids = [];
  for (let page = 1; page <= 5; page++) {
    const r = http.get(`${BASE}/products/list?disp_number=60&pageno=${page}`, { tags: { name: 'setup' } });
    const found = uniq((r.body.match(/products\/detail\/(\d+)/g) || []).map((s) => s.split('/').pop()));
    const before = ids.length;
    found.forEach((id) => { if (!ids.includes(id)) ids.push(id); });
    if (ids.length === before) break;
  }
  if (ids.length === 0) {
    fail('商品が 1 件も見つかりません（商品一覧に公開中の商品が要ります）');
  }
  // 検索語は商品名から。ヒットする検索とヒットしない検索の両方を混ぜる
  const words = [];
  const d = http.get(`${BASE}/products/detail/${ids[0]}`, { tags: { name: 'setup' } });
  const title = (d.body.match(/<h2 class="ec-headingTitle">\s*([^<]+?)\s*<\/h2>/) || [])[1];
  if (title) words.push(title.slice(0, 2));
  words.push('zzz-no-hit');
  console.log(`商品 ${ids.length} 件・カテゴリ ${categories.length} 件で流します（${PROFILE}、山 ${PROFILE === 'smoke' ? 1 : RATE} PV/秒、cart ${CART_RATIO}）`);
  return { ids, categories, words };
}

// ── 閲覧（1 回 = 1 ページ）──
// 比率は一般的な EC の閲覧の内訳に寄せた目安。店ごとに違うので、アクセス解析の実数があれば合わせる
const MIX = [
  ['top', 15],
  ['list', 20],
  ['category', 20],
  ['search', 10],
  ['detail', 35],
];
const MIX_TOTAL = MIX.reduce((a, [, w]) => a + w, 0);

export function browse(data) {
  markStep();
  let n = Math.random() * MIX_TOTAL;
  let kind = 'detail';
  for (const [k, w] of MIX) {
    if ((n -= w) < 0) { kind = k; break; }
  }
  let url;
  switch (kind) {
    case 'top': url = `${BASE}/`; break;
    case 'list': url = `${BASE}/products/list?pageno=${1 + Math.floor(Math.random() * 2)}`; break;
    case 'category':
      url = data.categories.length
        ? `${BASE}/products/list?category_id=${pick(data.categories)}`
        : `${BASE}/products/list`;
      break;
    case 'search': url = `${BASE}/products/list?name=${encodeURIComponent(pick(data.words))}`; break;
    default: url = `${BASE}/products/detail/${pick(data.ids)}`;
  }
  const r = http.get(url, { tags: { name: kind, kind: 'page' } });
  check(r, { [`${kind} 200`]: (x) => x.status === 200 });
}

// ── カートに入れる（1 回 = 3 PV）──
export function cart(data) {
  markStep();
  const id = pick(data.ids);
  const jar = http.cookieJar();
  const d = http.get(`${BASE}/products/detail/${id}`, { jar, tags: { name: 'detail', kind: 'page' } });
  if (!check(d, { 'detail 200': (x) => x.status === 200 })) return;

  const form = buildCartForm(d.body, id);
  if (!form) return; // 在庫切れ・規格が選べない商品は飛ばす（失敗には数えない）

  const add = http.post(`${BASE}/products/add_cart/${id}`, form, {
    jar,
    headers: { 'X-Requested-With': 'XMLHttpRequest' },
    tags: { name: 'add_cart', kind: 'page' },
  });
  const ok = check(add, {
    'add_cart 200': (x) => x.status === 200,
    'add_cart done': (x) => {
      try { return JSON.parse(x.body).done === true; } catch (e) { return false; }
    },
  });
  if (ok) cartAdded.add(1);

  const c = http.get(`${BASE}/cart`, { jar, tags: { name: 'cart', kind: 'page' } });
  check(c, { 'cart 200': (x) => x.status === 200 });
}

// 商品詳細の #form1 から、カートに入れる POST の中身を組み立てる。
// 規格のある商品は、ページに埋め込まれた eccube.classCategories から在庫のある組み合わせを選ぶ
// （2 段目の選択肢は JavaScript が作るので、HTML の <option> には無い）。
function buildCartForm(body, id) {
  const token = (body.match(/name="_token" value="([^"]+)"/) || [])[1];
  if (!token) return null;
  const form = { product_id: String(id), quantity: '1', _token: token };
  const pc = (body.match(/id="ProductClass" name="ProductClass" value="(\d+)"/) || [])[1];
  if (pc) {
    form.ProductClass = pc;
    return form;
  }
  const m = body.match(/eccube\.classCategories = (\{.*\});\s*$/m);
  if (!m) return null;
  let cats;
  try { cats = JSON.parse(m[1]); } catch (e) { return null; }
  const hasSecond = /name="classcategory_id2"/.test(body);
  for (const cc1 of Object.keys(cats)) {
    if (cc1 === '__unselected') continue;
    for (const [key, v] of Object.entries(cats[cc1])) {
      if (!v.product_class_id || v.stock_find === false) continue;
      form.classcategory_id1 = cc1;
      if (hasSecond) form.classcategory_id2 = key.replace(/^#/, '');
      form.ProductClass = String(v.product_class_id);
      return form;
    }
  }
  return null;
}

function pick(a) { return a[Math.floor(Math.random() * a.length)]; }
function uniq(a) { return [...new Set(a)]; }

// 結果は bin/loadtest.sh が指定したディレクトリへ（JSON と、人が読む要約）
export function handleSummary(data) {
  const out = {};
  if (__ENV.OUT_DIR) out[`${__ENV.OUT_DIR}/summary.json`] = JSON.stringify(data, null, 2);
  out.stdout = textSummary(data);
  if (__ENV.OUT_DIR) out[`${__ENV.OUT_DIR}/summary.txt`] = out.stdout;
  return out;
}

function textSummary(data) {
  const m = data.metrics;
  const v = (name, key) => (m[name] && m[name].values[key] !== undefined ? m[name].values[key] : null);
  const ms = (x) => (x === null ? '-' : `${Math.round(x)}ms`);
  const shown = PROFILE === 'smoke' ? 1 : RATE;
  const lines = [];
  lines.push('');
  lines.push(`== 負荷試験の結果（${PROFILE}、山 ${shown} PV/秒、cart ${CART_RATIO}）==`);
  lines.push(`リクエスト   ${v('http_reqs', 'count') ?? 0} 件（平均 ${(v('http_reqs', 'rate') ?? 0).toFixed(1)} 件/秒）`);
  lines.push(`失敗の割合   ${((v('http_req_failed', 'rate') ?? 0) * 100).toFixed(2)}%`);
  lines.push(`取りこぼし   ${v('dropped_iterations', 'count') ?? 0} 回（VU が足りず送れなかった。多ければサーバーが追いついていない）`);
  lines.push(`カート投入   ${v('cart_added', 'count') ?? 0} 回`);
  lines.push('');
  lines.push('ページごとの応答時間        中央値     p95      p99      最大');
  const names = Object.keys(m)
    .filter((k) => k.startsWith('http_req_duration{name:') && !k.includes('setup'))
    .sort();
  for (const k of names) {
    const label = k.replace('http_req_duration{name:', '').replace('}', '');
    if (!v(k, 'max')) { lines.push(`  ${label.padEnd(24)}       -  （流れなかった）`); continue; }
    lines.push(`  ${label.padEnd(24)} ${ms(v(k, 'med')).padStart(7)}  ${ms(v(k, 'p(95)')).padStart(7)}  ${ms(v(k, 'p(99)')).padStart(7)}  ${ms(v(k, 'max')).padStart(7)}`);
  }
  if (PROFILE === 'stress') {
    lines.push('');
    lines.push('段ごと（目標は閲覧の PV/秒。実際はカートの分も入る。崩れ始めた段の 1 つ前が、安心して受けられる量）');
    lines.push('  目標 PV/秒   実際 件/秒    中央値      p95     失敗');
    for (const s of stepLabels) {
      const n = v(`http_reqs{step:${s}}`, 'count');
      if (!n) { lines.push(`  ${s.padStart(9)}        -   （届かなかった）`); continue; }
      const f = v(`http_req_failed{step:${s}}`, 'rate') || 0;
      lines.push(`  ${s.padStart(9)}   ${(n / STEP_SEC).toFixed(1).padStart(9)}   ${ms(v(`http_req_duration{step:${s}}`, 'med')).padStart(7)}  ${ms(v(`http_req_duration{step:${s}}`, 'p(95)')).padStart(7)}  ${(f * 100).toFixed(1).padStart(6)}%`);
    }
  }
  lines.push('');
  const failed = Object.entries(data.metrics)
    .filter(([, x]) => x.thresholds && Object.values(x.thresholds).some((t) => !t.ok))
    .map(([k]) => k);
  lines.push(failed.length ? `**不合格**: ${failed.join(', ')}` : '合格（失敗 1% 未満・p95 が基準以内・check 99% 以上）');
  lines.push('');
  return lines.join('\n');
}
