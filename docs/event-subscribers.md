# イベント購読の一覧

15本のプラグインが本体のどこに割り込んでいるかをまとめたもの。**購読しているクラスは34本、
イベントのキーは47個**ある。1本ずつ開かなくても、どこに何がぶら下がっているかが分かるようにした。

実物は各プラグインの `EventListener/` と `Doctrine/EventListener/` にある。この文書は
入り口の索引で、細かい理由はクラスの docblock に書いてある。**中身を変えたらここも直す。**

## 入り口は4種類

| 仕組み | キーの書き方 | 数 | 向いている用途 |
| --- | --- | --- | --- |
| TemplateEvent | `'Mypage/history.twig'` / `'@admin/Order/edit.twig'` | 18 | 画面に何かを足す |
| EccubeEvents | `EccubeEvents::ADMIN_PRODUCT_EDIT_COMPLETE` | 13 | 本体の処理の前後に割り込む |
| Doctrine | `#[AsDoctrineListener(event: Events::postLoad)]` | 7 | どこから保存されても効かせる |
| KernelEvents | `KernelEvents::RESPONSE` | 5 | 画面が誰の持ち物でも効かせる |
| 独自イベント | `OrderApprovedEvent::class` | 3 | 自分のプラグインの処理を外から差し替えさせる |

Doctrine のリスナーだけ `Doctrine/EventListener/` に分けてある。本体と同じ分け方。

**探すときは `getSubscribedEvents` だけを見ても足りない。** CustomerGroupRank44/LoginListener は
インターフェースを実装せず、`services.yaml` の `kernel.event_listener` タグだけで登録している。
いま YAML でタグを付けているのはこの1本だけ。

**15本のうち3本は1つも購読していない。** CustomerGroupDelivery44 と CustomerGroupPayment44 は
購入フローのバリデータ（`Service/PurchaseFlow/`）、CustomerGroupEntry44 はフォーム拡張だけで
用が足りている。イベントに割り込む必要が無いなら割り込まない。

---

## B2BCompany（11本）

取引先と担当者の関係を保つ側。**数が多いのは、同じ約束を経路ごとに守らせているから。**
フォームで止めるだけでは足りない場面が多い。

| クラス | 購読するもの | すること |
| --- | --- | --- |
| GroupInheritListener | Doctrine `prePersist` | 担当者を作るとき、取引先から会社情報と会員グループを写す |
| GroupSyncListener | Doctrine `onFlush` | 取引先の会員グループを担当者にも反映する。管理画面・CSV取込・独自コードのどこから変えても効く |
| CompanyProfileSubscriber | `FRONT_MYPAGE_CHANGE_INDEX_COMPLETE` | 会社の情報を担当者に書き換えさせない。保存後に親の値へ戻す |
| CompanyProfileNoticeSubscriber | `Mypage/change.twig` | 会社の項目が固定されている理由を画面に出す |
| CompanyOrderHistorySubscriber | `FRONT_MYPAGE_MYPAGE_INDEX_SEARCH`<br>`FRONT_MYPAGE_MYPAGE_HISTORY_INITIALIZE`<br>`Mypage/index.twig` | 取引先の管理者には自社全体の履歴、担当者には自分の分だけ見せる |
| CustomerWithdrawSubscriber | `FRONT_MYPAGE_WITHDRAW_INDEX_COMPLETE`<br>`ADMIN_CUSTOMER_EDIT_INDEX_COMPLETE` | 取引先の管理者が退会したら担当者も退会させる |
| CompanyAccountHintSubscriber | `ADMIN_CUSTOMER_EDIT_INDEX_COMPLETE` | 会社名だけ入れて取引先にしていない会員を保存したら、その場で知らせる |
| MemberMypageGuardSubscriber | `KernelEvents::CONTROLLER` | 担当者に開けさせないマイページ（退会・お届け先）をURL直打ちでも塞ぐ |
| MypageNaviSubscriber | `KernelEvents::RESPONSE` (-64) | マイページのナビに「担当者アカウント」を足す |
| CustomerListSubscriber | `@admin/Customer/index.twig` | 会員一覧に「取引先」「担当者（会社名）」の印を出す |
| OrderListSubscriber | `@admin/Order/index.twig`<br>`@admin/Order/edit.twig` | 受注一覧・詳細に、どの取引先の受注かを出す |

## B2BOrderApproval（4本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| OrderMailSubscriber | `EccubeEvents::MAIL_ORDER` | 注文完了メールに割り込み、承認依頼も同じ場所から送る。**受注1件につき1回しか通らない場所** |
| ApprovalMailSubscriber | `OrderApprovedEvent`<br>`OrderForwardedEvent`<br>`OrderRejectedEvent` | 承認・転送・差し戻しの通知を送る。**止めて自分のものに差し替えられる** |
| OrderHistorySubscriber | `Mypage/history.twig` | 注文履歴に差し戻しの理由を出す |
| MypageNaviSubscriber | `KernelEvents::RESPONSE` (-64) | ナビに「承認待ちの発注」を足す。承認する番が回る会員だけ |

## B2BBilling（1本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| OrderInvoiceLinkSubscriber | `@admin/Order/edit.twig` | 受注詳細から、その受注が載った請求へのリンクを出す。外部キーは張らず請求明細から引く |

## OrderPad（2本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| MypageNaviSubscriber | `KernelEvents::RESPONSE` (-64) | ナビに「型番で発注」「発注リスト」を足す |
| OrderHistorySubscriber | `Mypage/history.twig` | 注文履歴に「この注文をリストに保存」を足す |

## OrderDocument（2本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| AdminOrderSubscriber | `@admin/Order/edit.twig` | 受注詳細に帳票のボタンを足す。納品書の隣 |
| MypageHistorySubscriber | `Mypage/history.twig` | 注文履歴の詳細に帳票のボタンを足す |

## CustomerGroup44（2本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| ProductListener | `KernelEvents::REQUEST` | 商品一覧・商品詳細・ユーザー定義ページを Voter で判定し、見せない相手には403 |
| LoginSubscriber | `SecurityEvents::INTERACTIVE_LOGIN` | ログイン時に、見てよい商品IDとカテゴリIDをトークンの属性に載せる |

## CustomerGroupPrice44（4本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| ProductClassEventListener | Doctrine `postLoad` / `preUpdate` (-9999) | 会員グループの価格に差し替える。`preUpdate` は**差し替えた価格を保存させない**ための巻き戻し |
| GroupPriceEventListener | Doctrine `postLoad` (-9999) | グループ価格の税込を計算して入れる |
| Event | `@admin/Product/product.twig`<br>`@CustomerGroup44/admin/Customer/Group/edit.twig` | 管理画面にグループ価格の入力を足す。**JPY のときだけ**（率で計算するため） |
| ProductOptionListener | `FRONT_SHOPPING_SHIPPING_MULTIPLE_COMPLETE` (-99999) | ProductOption プラグインが有効なときだけ、複数配送の明細を組み直す |

## MembersOnly44（2本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| ListEventListener | Doctrine `postLoad` | 未ログインの商品ページで価格を0にする。**元データのスナップショットも揃えて**保存されないようにする |
| Event | `Mypage/login.twig`<br>`Product/list.twig`<br>`Product/detail.twig`（各 -256） | ログインを促す文言と、価格を隠す表示を差し込む |

## CustomerApproval（1本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| EntryListener | `FRONT_ENTRY_INDEX_COMPLETE`<br>`MAIL_CUSTOMER_CONFIRM`<br>`MAIL_ADMIN_CUSTOMER_CONFIRM`（各 +10） | 承認が要る会員は仮登録で止め、承認依頼を管理者へ送る。**誰を承認制にするかは差し替えられる**（`ApprovalTargetChain`） |

## ProductSort44（2本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| ProductSubscriber | Doctrine `prePersist` | 新しい商品に並び順の初期値を入れる |
| Event | `@admin/Product/index.twig`<br>`ADMIN_PRODUCT_EDIT_COMPLETE`<br>`ADMIN_PRODUCT_COPY_COMPLETE` | 商品一覧に並び順の入力を足す。保存・複製のあとに採番し直す |

## CustomerGroupRank44（2本）/ ProductFeedExporter44（1本）

| クラス | 購読するもの | すること |
| --- | --- | --- |
| CustomerGroupRank44/Event | `@CustomerGroup44/admin/Customer/Group/edit.twig` | 会員グループ編集にランクの入力を足す |
| CustomerGroupRank44/LoginListener | `SecurityEvents::INTERACTIVE_LOGIN`<br>（YAML のタグで登録） | ログイン時にランクを判定して会員へ当てはめる |
| ProductFeedExporter44/ClassNameEventListener | `@admin/Product/class_name.twig` | 規格名の管理画面にフィード用の入力を足す |

---

## 同じ場所に集まっているところ

**足す順番が画面の並びになる。** ここに手を入れるときは他の2つを確認する。

| イベント | ぶら下がっているもの |
| --- | --- |
| `Mypage/history.twig` | B2BOrderApproval（差し戻し理由）、OrderDocument（帳票）、OrderPad（リストに保存） |
| `@admin/Order/edit.twig` | B2BBilling（請求リンク）、B2BCompany（取引先名）、OrderDocument（帳票） |
| `KernelEvents::RESPONSE` (-64) | B2BCompany、B2BOrderApproval、OrderPad のナビ3本 |
| `@CustomerGroup44/admin/Customer/Group/edit.twig` | CustomerGroupPrice44、CustomerGroupRank44 |
| `ADMIN_CUSTOMER_EDIT_INDEX_COMPLETE` | B2BCompany の2本（退会の連動、取引先にし忘れの警告） |
| `SecurityEvents::INTERACTIVE_LOGIN` | CustomerGroupRank44（ランク判定）、CustomerGroup44（見てよい商品IDの控え） |
| Doctrine `postLoad`（ProductClass） | CustomerGroupPrice44（-9999）、MembersOnly44（0） |

下2行には補足がいる。

**ログインの2本は順番に意味があるが、priority はどちらも0。** ランクを当ててから
見てよい商品IDを控えないと、ランクで会員グループが変わった直後のセッションだけ
古いIDを持つことになる。実機では Rank が先に走っており（`debug:event-dispatcher` で確認）
いまは正しい順だが、**登録順に頼っている。** どちらかを動かすならここを確かめる。

**postLoad の2本は同時には走らない。** CustomerGroupPrice44 は会員がログインしていること、
MembersOnly44 はログインしていないことを条件にしているので、`supports()` の時点で
どちらか片方しか通らない。priority が違うのは偶然で、依存関係ではない。

## priority を明示しているもの

既定（0）のままのものは書いていない。**値が入っているものには理由がある。**

| 値 | どこ | なぜ |
| --- | --- | --- |
| +10 | CustomerApproval/EntryListener | 他の購読者より先に走らせる |
| -64 | マイページのナビ3本 | 画面が組み上がったあとに差し込む |
| -256 | MembersOnly44/Event | 他のスニペットより後ろに回す |
| -9999 | CustomerGroupPrice44 の Doctrine 2本 | 他が価格を触った**後**に差し替える。上げると競合し、**例外は出ず金額だけ変わる** |
| -99999 | CustomerGroupPrice44/ProductOptionListener | ProductOption が明細を作り終えたあとに組み直す |

理由がコードに書いてあるのは -9999 の2本だけ。ほかは値から読み取ったもので、**動かして
良いかどうかは分からない。** 触るなら実機で確かめる。

---

## 踏んだ罠

同じ失敗を繰り返さないための記録。**どれも例外が出ないので、目で見るまで気づけない。**

### `default_frame.twig` を購読してスニペットを足さない

`TemplateEvent::addSnippet()` は空の配列に足してから `plugin_snippets` を上書きする。
親テンプレートで足すと、**子テンプレートに積まれた他プラグインのスニペットが消える。**
試したときはマイページのナビからプラグインの項目が全部消えた。

### マイページのナビをテンプレート名で拾わない

以前は TemplateEvent にページのテンプレート名を並べていた。次の3つで黙って消える。

- 本体がマイページを増やしたとき
- **他のプラグインがマイページを増やしたとき。** 実際、承認待ち一覧で OrderPad のメニューが出ていなかった
- ページ管理から編集できるようテーマへ写して、描画名が変わったとき

いまは `KernelEvents::RESPONSE` でナビの HTML の目印を見て差し込む。誰がその画面を
作ったかに依存しない。

### 本体のテンプレートを文字列置換で書き換えない

目印にしていた Twig の式は、本体が属性をひとつ足すだけで一致しなくなる。
`addSnippet` で JavaScript を差し込み、行の id を手がかりにする。

### 出す条件をテンプレートに書かない

画面を開いたときの判定と二重になってずれる。実際、自己発行を切っていてもメニューだけ出て、
押すと403になっていた。PHP 側で決めて渡す。

### メールの件名はテンプレートを上書きしても変わらない

件名は `dtb_mail_template.mail_subject` にある。`MAIL_ORDER` で組み立て終わったメールを
受け取れば、件名も本文も差し替えられる。

### フォームの `help` はマイページに出ない

本体の `Mypage/change.twig` は `form_widget` と `form_errors` しか呼ばない。
注記を出したいならスニペットで足す。

### 登録が落ちてもテストは緑のまま通りえる

Doctrine のリスナーは、登録を外しても他のテストが通ってしまうことがある。実際に
`preUpdate` を外して236件全部緑だった。**登録そのものを見るテスト**を
`Tests/Doctrine/DoctrineListenerRegistrationTest.php` に置いてある（CustomerGroupPrice44、MembersOnly44）。
