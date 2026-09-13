# GW230529 Einstein Toolkit — AWS Infrastructure (Terraform)

## プロジェクト概要

[gw230529-einstein-toolkit](../gw230529-einstein-toolkit) の **Phase 4–6
(クラウド実行)** を担う sibling repo。EC2 spot ノード 1 台、S3 (成果物の正本)、
ECR (ET イメージ配布)、およびコストガードレールを Terraform で管理する。

設計の全体像と根拠は [docs/architecture.md](docs/architecture.md) にある。
本ファイルは運用ルールのみを記す。

### 確定済みの設計判断

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| repo 名 | `gw230529-einstein-toolkit-aws-tf` | 本体 repo の sibling |
| 公開範囲 | public。アカウント固有値は gitignore + `.example` | Q7 |
| リージョン | 起動ごとの選択はしない。**1 回決めて固定** | ECR/S3 がリージョン束縛。移動 = 4.06 GB 再 push |
| リージョン | **us-west-2 に確定 (2026-08-19 実測)** | 下記「リージョン選定の実測結果」 |
| AZ | **us-west-2d (`usw2-az4`)**、次点 `us-west-2a` → `us-west-2c` | placement score 9 かつ c7a.48xlarge が最安 |
| インスタンス | **c7a.48xlarge が既定 (2026-08-20 実測で確定)** | np=192 フル解像度のメモリ実測 136 GiB は 384 GiB の 35%。下記「Phase 5 メモリ実測」 |
| 本番 run の長さ | **33.7 時間 / 約 100 USD (終点 1750 M、2026-08-27 決定)** | 4.16 sec/iter (2026-08-21 実測) × 29,167 iteration。下記「本番 run の終点は 1750 M」 |
| state backend | S3 + native lockfile (`use_lockfile`) | DynamoDB テーブルが不要になる |
| S3 構成 | 1 バケット + prefix 別 lifecycle | バケット分割は分離を買わずポリシー面だけ増える |
| ネットワーク | public subnet + IGW + S3 Gateway Endpoint | private + NAT は月 33 USD、予算の 11% |
| スタック分割 | bootstrap / foundation / compute の 3 つ | **環境別ではなく寿命別**。compute の destroy がデータに届かない |
| spot instance | `aws_instance` + one-time spot、`run_enabled` フラグ | 中断後の再開が `terraform apply` 1 発になる |

### リージョン選定の実測結果 (2026-08-19、`make region-scout`)

target 192 vCPU / single-AZ / c7a・m7a・c7i の 48xlarge で計測 (当時の候補リスト。
2026-08-20 に m7a・c7a・r7a へ入れ替えた。下記「インスタンス選定の再評価」)。

| リージョン | score 9 の AZ 数 | c7a.48xlarge 最安 | spot vCPU クォータ |
| --- | --- | --- | --- |
| us-west-2 | 4 中 3 | 2.970 USD/h (us-west-2d) | 256 |
| us-east-1 | 6 中 4 | 2.996 USD/h (us-east-1a) | 256 |
| us-east-2 | 3 中 2 (1 つは 6) | 2.572 USD/h | **5** |

- **us-east-2 は脱落**。約 15% 安いがクォータが 5。緩和申請の承認待ち
  (数時間〜数日) に見合う差ではない (76 時間 run で約 30 USD)
- **us-west-2 を採用**。容量では差がつかない (どちらも score 9、クォータ済み)。
  決め手は**フォールバック AZ の価格が近い**こと:
  us-west-2 は 2.97 → 3.05 → 3.32、us-east-1 は 2.996 → 3.49 → 3.52。
  第一希望の AZ を外されたときの傷が浅い。加えて us-east-1 は
  AWS 全体の大規模障害が集中する
- **クォータ緩和申請は不要だった** — us-east-1 / us-west-2 は既に 256 vCPU。
  当初の「今すぐ申請」という申し送りは解消

**AZ は名前順ではなく明示リストで指定する (2026-08-20 修正)**

`modules/network` は当初 `slice(names, 0, az_count)` で AZ を選んでいたが、
us-west-2 の名前順は a → b → c → d なので `az_count = 3` だと
**最安・score 9 の us-west-2d が漏れ、unscored の us-west-2b が入る**。
compute は subnet を AZ 名で引くので、`availability_zone = "us-west-2d"` が
plan 時にキー不在で落ちる状態だった。

`availability_zones = ["us-west-2d", "us-west-2a", "us-west-2c"]` を
foundation の変数として渡す方式に変更。`az_count` は null 時のフォールバック
として残す。併せて `public_subnet_ids` の出力を map 反復 (辞書順) から
`local.azs` 順に直した — compute が AZ を指定しないときの既定が
辞書順先頭ではなく第一希望になるようにするため。

- **リストの順序は CIDR に効く**。subnet の CIDR はリスト位置から
  `cidrsubnet` で決まるので、並べ替えると全 subnet が replace される。追加は安全

### インスタンス選定の再評価 (2026-08-20)

sibling repo が公開リファレンス出力 (`bhns_gw230529.out` の Carpet ログと
SLURM エピローグ) を直読みして数値を訂正した。**本 repo が使っていた
「256 コア / 30 時間 / 140 GB」は 3 つとも誤り**だった。

| 項目 | 旧 (本 repo の記述) | 実測 (2026-08-20) |
| --- | --- | --- |
| 並列度 | 256 cores | **480 rank** (12 ノード × 40 コア) |
| 実行時間 | 30 時間 | 46.4 h で t=3041 M / t=2000 M まで約 30.5 h |
| core-hours | — | **約 14,600 core-hours** (t=2000 M) |
| メモリ | 140 GB | **438.5 GB** (12 ノード合計、SLURM 申告) |
| 速度 | — | 3.30 sec/iter (dt = 0.06 M) |
| 合体時刻 | — | t ≈ 713 M (ψ4 ピーク 1213 M − 抽出半径 500 M) |

140 GB の出所は sibling 側でも特定できず、**もう使わない**ことにした。

**メモリが律速で、価格ではない。** 438.5 GB は 480 rank 時の全ノード合計。
192 rank なら ghost zone の重複が減るぶん下がるが、chunk の体積が 2.5 倍でも
線寸は 1.36 倍にしかならず、ghost 比は線寸に従うので下げ幅は弱い。
SLURM の値を一番甘く 10 進 GB (= 408 GiB) と読んでも、**削減を当てる前から
c7a.48xlarge の 384 GiB を超えている**。

物理コア単価 (us-west-2d spot、2026-08-20 実測):

| タイプ | 物理コア | メモリ | ch | USD/h | USD/物理コア時 |
| --- | --- | --- | --- | --- | --- |
| c7a.48xlarge | 192 Genoa 3.7 GHz | 384 GiB | 12 | 2.978 | **0.0155** |
| m7a.48xlarge | 192 Genoa 3.7 GHz | 768 GiB | 12 | 3.747 | 0.0195 |
| r7a.48xlarge | 192 Genoa 3.7 GHz | 1536 GiB | 12 | 4.220 | 0.0220 |
| c7i.48xlarge | 96 SPR 3.2 GHz + HT | 384 GiB | 8 | 3.072 | 0.0320 |
| c7a.24xlarge | 96 Genoa 3.7 GHz | 192 GiB | 12 | 1.950 | 0.0203 |

- **【2026-08-20 更新】c7a.48xlarge を既定に昇格した。** 下記「Phase 5 メモリ実測」
  のとおり実測 136 GiB は 384 GiB の 35%。この項の当初判断は
  「参照 run の 438.5 GB」を単一ノード np=192 の下限のように扱っていたが、
  あれは 12 ノード 480 ランクに対するスケジューラの高水位だった
- **m7a.48xlarge (768 GiB) は退避先**。合体時の regrid が working set を
  2.8 倍に増やすようなら戻る。r7a.48xlarge (1536 GiB) はその後ろ
- **r7a.48xlarge (1536 GiB) を scout に追加**。768 GiB でも足りなかった場合の逃げ道
- **c7i.48xlarge を scout から除外**。時間単価が c7a の 3% 差に見えるのが罠で、
  物理コア単価は **2.06 倍**。メモリ 8ch / 3.2 GHz も不利。
  これ以上測っても比は変わらないので候補から落とした
- **小さくする案は成立しない**。c7a.24xlarge は 192 GiB でフル解像度が載らず、
  しかも 48xlarge より物理コア単価が 31% 高い

**コスト見積り【2026-08-21 実測で確定】**: 下記「Phase 5 スループット実測」の
とおり **4.16 sec/iter**。t=2000 M までは 33,333 iteration = **38.5 時間**、
c7a.48xlarge spot で **115 USD**。
【2026-08-27 更新】終点は 1750 M に決定したので本番は **33.7 h / 約 100 USD**。

| | 実測 4.16 s/it → 2000 M | 1500 M で打ち切り | (旧) 悲観端 76 h |
| --- | --- | --- | --- |
| c7a.48xlarge @ 2.978 | **115 USD (38.5 h)** | 86 USD (28.9 h) | 226 USD |

外挿は **38–76 時間**という帯だった (14,600 core-hours ÷ 192 コアで参照ノード
per-core 同等なら 76 時間、Genoa は 1.5–2 倍と見て下限 38 時間)。実測は
参照ノードの **2.07 倍**で、帯の楽観端をわずかに超えた。

- **逃げ道は当面いらない**。「合体が t≈713 M なので ~1500 M で打ち切る」案は
  29 USD の節約にしかならず、post-merger のディスク進化を捨てる価値はない。
  これは物理側の判断だが、少なくともコストが理由で迫られる決定ではなくなった
- **run 長依存の数値は 76 時間のまま据え置く**。checkpoint 世代数、S3 常駐量、
  gp3 スループット費はすべて悲観側で見積もってある。実測が半分になったので
  安全側に倍の余裕がついただけで、締め直す理由はない。中断からの再開を
  何度か挟めば実 wall clock は 38.5 時間より延びる

### Phase 5 メモリ実測 (2026-08-20、np=192 フル解像度)

**プロジェクト最大の未確定事項が解消した。** `bhns_smoke_dx19p2_l8_it4.par`
(dx=19.2 / 8 levels / itlast=4 / ID checkpoint 無し) を m7a.48xlarge で
起動し、Carpet の格子構造統計を読んだ。**起動から 3 分半**で答えが出る。

| | dx=28 / np=32 | **dx=19.2 / np=192** |
| --- | --- | --- |
| Carpet `Total required memory` | 42.347 GB | **125.273 GB** |
| ノード実測 (`free`) | 43–47 GiB | **134–136 GiB** |
| GF active | 1,665M pts | 4,597M pts |
| GF owned | 2,905M (+74%) | 6,787M (+48%) |
| GF total | 4,889M | 13,215M (+95%) |
| checkpoint 1 世代 | 30.1 GB / 32 ファイル | **85.7 GB / 192 ファイル** |
| Kadath import 合計 | 549 秒 | **342 秒** |

- **136 GiB は c7a.48xlarge (384 GiB) の 35%。** 単一ノードで走る。
  マルチノード MPI は必要条件に**ならなかった**
- **参照 run の 438.5 GB を単一ノードの下限と読んだのが誤りだった。**
  あれは 12 ノード 480 ランクに対する SLURM の高水位。ランクを 2.5 倍に
  割ると ghost の重複が増える。実際 np=192 でも total は owned の +95% で、
  np=32 の +68% より大きい
- **checkpoint は 85.7 GB/世代**。従来の外挿値 78 GB に対し +10%。
  `root_volume_size_gb = 500` は keep=2 で 171 GB なので余裕がある
- 検算に使える関係: **checkpoint サイズ ∝ GF total 点数**。
  30.1 GB × (13,215/4,889) = 81 GB で、実測 85.7 GB と 5% 差

**残る最大の未知は sec/iter だった。**【2026-08-21 解消、下記】この probe は
4 iteration で終わるので、起動時解析に埋もれて意味のある値が取れない
(Phase 2 の「短い区間でサンプリングするな」がそのまま効く)。実際この probe が
報告した 29.37 M/h に対し、90 分回した実測は **54.06 M/h** だった。
**4 iteration の値で予算を立てていたら 1.8 倍外していた**。

### Phase 5 スループット実測 (2026-08-21、np=192 フル解像度)

**コスト見積り最後の外挿が消えた。** `bhns_gw230529_probe.par`
(production と同一設定 + `Cactus::terminate = "runtime"` /
`Cactus::max_runtime = 90`) を c7a.48xlarge / us-west-2d で 90 分回した。
run_name `phase5-throughput-dx19p2`、t=0 → 62.94 M (iteration 1049)。

| | 実測 |
| --- | --- |
| **evolution ループ単体** (サンプル中央値) | **3.75 sec/iter** |
| **実効レート** (窓平均、全オーバーヘッド込み) | **4.16 sec/iter** |
| Carpet `physical_time_per_hour` 中央値 | 54.06 M/h (= 4.00 sec/iter) |
| 突き合わせ (Carpet / 壁時計) | **0.961** |
| checkpoint 書き込み 85.7 GB | 約 76 秒 (毎時 = wall clock の 2.1%) |
| 2D 出力 (1024 iteration ごと) | 約 31 秒 |
| FUKA import 8 レベル | 344 秒 (5.7 分) |
| import → evolution 開始 | 約 10 分 (iteration 0 解析 + AH 探索 + ID checkpoint) |
| **cold start 合計** (コンテナ起動 → evolution) | **約 18 分** |
| Carpet 必要メモリ / ノード実測 | 125.273 GByte / **137 of 369 GiB** |

- **2 通りの独立した読み方が 3.9% で一致した。** Carpet 自身の
  `physical_time_per_hour` (10 分の後方移動平均) と、行タイムスタンプの差分。
  片方だけなら「たまたまそう見えた」を排除できない
- **cold start は import の 5.7 分ではなく約 18 分。** import 完了から
  evolution 開始まで 10 分あり、これは今まで誰も見ていなかった区間
  (iteration 0 の解析と 1D/2D/0D 出力)。`IO::checkpoint_ID = "yes"` を
  必須にした判断の裏取りになった — 中断のたびに 18 分払うところだった
- **メモリが本番インスタンス型で再現した。** 昨日の測定は m7a.48xlarge
  だったが、c7a.48xlarge (384 GiB、うち OS 込み 369 GiB 可視) でも
  Carpet 125.273 GByte / ノード 137 GiB。**37%**
- **checkpoint 書き込みは 1000 MB/s ちょうど** = `root_volume_throughput` に
  設定した gp3 の帯域。設計文書の「78 GB で 78 秒」はサイズが増えたぶん
  比例して伸びただけで、仮定は正しかった

**測定条件の限界を明記しておく。** これは **t=0–63 M、2000 M の 3%** で、
純粋な inspiral である。合体は **t≈713 M**。合体時の regrid とディスク形成が
per-iteration コストを上げる可能性は残っている。`Carpetregrid2` の半径は
M 単位で固定、`num_levels` も 8 で固定なので格子点数は増えないが、
con2prim の反復回数は増えうる。**38.5 時間は下限に近い値として扱うこと**。

### Phase 5 recovery 実証 (2026-08-26、issue #3)

**spot 中断からの復帰がクラウドで成立した。** ローカル (sibling Phase 2) では
確認済みだったが、クラウド固有の 3 点 — S3 からの復元、復元後の uid 委譲、
自分が書いていない checkpoint への `autoprobe` — は未検証だった。
8/21 の probe が残した `phase5-throughput-dx19p2` に同じ `run_name` で
再起動する形で実施。約 30 分・約 1.5 USD。

| 判定項目 | 結果 |
| --- | --- |
| S3 からの復元 | 08:22:51 `restoring checkpoints from slot-b` |
| Kadath import なしの recovery | `Filling took` 0 件。`it_1049` / t=62.94 M から再開 |
| 停止点を越えた evolution | `it_1124` / t=67.44 M まで |
| 終了時 checkpoint の slot 回転 | 08:48:50 push → 08:50:25 `CURRENT is now slot-b` |
| ノードの自滅 | cloud-init 08:50:25 完了、08:51:34 poweroff |

- **`CURRENT` を push 成功後に書く規律が効いた。** 途中まで「回転しなかった」
  と読み違えたが、実際は slot-b → slot-a → slot-b と **2 回転**して戻っていた。
  マーカーだけでは回転の有無を判定できない。**slot の中身の世代番号を見ること**
- **run をまたいだ刈り取りが実証された**。復元した `it_897` は最終 slot に無い
- **cold start 18 分に対し、recovery は evolution 開始まで約 10 分**。
  うち 7.5 分が 175 GB のダウンロードで、Cactus 側は速い

**【2026-08-26 解消】再開後のスループットが 3 倍遅い問題は、
ページキャッシュが NUMA 配置を壊していたのが原因だった。**

| | 8/21 probe (fresh) | 8/26 recovery (sync=1) | 8/26 検証 run (sync=5) |
| --- | --- | --- | --- |
| 壁時計 sec/iter | 4.16 | 12.36 | 8.0 → **4.08** |
| 投影 (t=2000 M) | 115 USD | 341 USD | **113 USD** |

**当初の候補だった sidecar 干渉 (sync=1) は犯人ではなかった。** 検証 run で
`sync_interval_minutes = 5` に戻しても遅いままで、しかも 3 つの独立な計測が
sidecar を否定した:

- **tick ログの実測**: 何もしない tick のコストは **1–9 秒 / 5 分** (0.3–3%)
- **Carpet の内訳** (`carpet-timing..asc` の it_1280): `time_io` は **1.5%**。
  時間は全部 `time_computing` に消えていた
- **`top`**: 192 ランクが全部 R で 100%、`%Cpu 89.9 us / 5.2 id`。
  **CPU を奪われているのではなく、回っているのに遅い**

**真因 — 順番の事故。recovery だけがこの順番を踏む:**

1. restore が 162 GiB の checkpoint をボリュームに落とす。全バイトが
   ページキャッシュを通り、c7a.48xlarge は 184 GiB の NUMA ノード 2 枚なので
   **片方が完全に埋まる**
2. Cactus が 208 GiB を確保する。`vm.zone_reclaim_mode` の既定は 0 で、
   **空きが無いノードは自分の clean なキャッシュを回収せず、他ノードから
   確保を満たす**。first touch でリモートに置かれ、そのまま固定される
3. ノード上の実測: node0 が FilePages 115 GiB / AnonPages 68 GiB、
   node1 が 6 / 140。**node0 側 96 ランクの working set の約 35% が
   インターコネクト越し**。帯域律速のステンシルには致命的
4. AutoNUMA は気づくが直せない — **150 GiB 分のページを移動**しても
   node0 に行き場が無い。この churn 自体もコスト

**fresh run が速いのは初期データを綺麗なメモリに生成するから。**
Phase 5 でこれが見つからなかったのは、recovery を測るまで
この順番を踏まなかったからで、性能の話ではなく手順の話だった。

**因果は介入で閉じた。** 走行中のノードで `echo 1 > /proc/sys/vm/drop_caches`
を叩いたところ、**6 分で 8.44 → 3.79 sec/iter に戻り**、そのまま 54 分維持した。

修正は `templates/user_data.sh.tftpl` の section 3、restore 直後・
`docker run` の前の 1 行 (`sync; echo 1 > /proc/sys/vm/drop_caches`)。
払う代償は recovery の HDF5 読み込み 85.7 GiB がキャッシュではなく
ボリュームから来ること — gp3 1000 MB/s で **約 86 秒、1 回だけ**。

**#11 の修正はこれとセットで要る。** タイマーは `OnBootSec` なので、
実測では restore 完了の **2 秒後**に sidecar が 162 GiB を読み直し始めていた。
Cactus が first touch している最中にキャッシュを埋め戻すので、
drop_caches だけでは 2 秒しか稼げない。stamp を restore 直後に書いて
最初の tick を黙らせることが、drop_caches の効果を保証している。

**併せて確定した数字:**

- **定常状態の checkpoint は傷を作らない** — 85.7 GiB の書き込みで 85 秒
  (毎時なら wall clock の 2.4%、設計時の見積り 2.1% とほぼ一致)。
  メモリ確保がとうに終わっているので配置には影響しない
- **recovery のコストはゼロ**。settled 窓 (54 分・800 iteration) で
  **4.08 sec/iter**、fresh の 4.16 と区別がつかない

**副産物: `read_throughput.sh` が 2 run 分のログを 1 本として測っていた。**
`run_name` が同じなので sidecar が同じ `cactus-stdout.log` に追記し、
**8/21 と 8/26 の間の 4.8 日 (413,603 秒) が 1 個の "stall" として**
evolution 時間に算入されていた。結果は 462 sec/iter・**12,746 USD** の投影。
しかも `cross-check` が「壁時計を信じろ」と言っていて、この局面では
**それが逆**だった (壁時計の方がノードの居ない時間を数えていた)。
2026-08-26 に壁時計ギャップでのセグメント分割を実装 (issue #12)。
既定は最後のセグメントのみを測り、`--segment N` / `--segment all` で選べる。
**中断→再開が設計の前提なのだから、ログが 1 本の連続 run である保証は
どこにも無かった。**

### checkpoint 同期の設計 (2026-08-20 決定)

本体 repo の Phase 2 実測 (checkpoint 25 GB @ dx=28 → フル解像度 78 GB) を
受けて確定。詳細は `docs/architecture.md`「Checkpoint synchronisation」。

- **slot-a / slot-b の 2 面交互書き + `CURRENT` マーカー**。
  push-only mirror だと 76 世代 = 5.9 TB / 約 31 USD (予算の 10%) 溜まる。
  2 面なら (保持世代数 × 78 GB) × 2 slot = 既定の keep=2 で **312 GB** 固定
- **`CURRENT` はアップロード成功後にのみ書く**。78 GB の転送中に中断されると
  S3 に不完全なセットが残り、`recover = autoprobe` は「最新だから」それを
  選んでしまう。タイムスタンプではなくマーカーで復元先を決めるのはこのため
- **checkpoint 1 時間 / sync 5 分**。78 GB の書き込みは全 rank を 78 秒
  止めるので、間隔を半分にすると wall clock の 4.3% を失う。
  76h run で確定 約 1.6 時間の節約 vs 中断 1 回あたり約 15 分の追加ロス
- **同一リージョンの転送料は 0**。残るのは PUT リクエスト (checkpoint 1 回
  約 $0.05) と保管料 (312 GB × 1 週間で約 $1.7) のみ
- sync は変更が無ければ LIST のみで終わるので、間隔を短くしても実質無料。
  **2026-08-26 に実測: 何もしない tick は 1–9 秒** (9 秒は 2D 出力の直後)。
  tick ごとの出力は `<run>/output/sync.log` に残る — journal はインスタンスと
  一緒に死ぬので、以前は最後の 1 tick 分しか読めなかった
- **restore 直後に `--stamp-only` で stamp を書く** (issue #11)。書かないと
  最初の tick が「全部変わった」と判断し、**いま落としてきたばかりの
  162 GiB を反対の slot に上げ直す**。無駄なだけでなく、Cactus が
  メモリを first touch している最中にそれを読み返すので、
  上記「Phase 5 recovery 実証」の NUMA 劣化を悪化させる。
  stamp が指す集合は CURRENT が既に指しているものなので、
  push を省いても失うものは無い

### シミュレーション repo Phase 1–2 の実測を受けた対応 (2026-08-20)

sibling repo の Phase 1 (Docker ビルド) / Phase 2 (ローカル smoke) から
申し送られた 3 点に対応済み。詳細は `docs/architecture.md`。

1. **Phase 4 は物理計算をしない (`run_mode = "ops-rehearsal"`)**

   `c7a.2xlarge` は 16 GiB で、**収まって かつ 走る解像度が存在しない**:

   | dx | メモリ | 16 GiB に収まるか |
   | --- | --- | --- |
   | 28.0 | 37.1 GB (実測) | 入らない |
   | 33.6 | 21–26 GB (推定) | 入らない |
   | 67.2 | 11.6 GB (実測) | 入るが evolution 1 歩目で NaN |

   dx=67.2 が落ちるのは解像度ではなく構造の問題。`Carpetregrid2::radius_*[N]`
   が M 単位で固定なので、dx を粗くしても**ボックスの物理サイズは変わらず
   セル数だけ減る**。level 1 が上流 62 セルに対し 17 セルしかなく、
   ghost_size=3 と prolongation buffer を引くと有効領域が消える

   代案の `c7a.8xlarge` (64 GiB) は Phase 4 予算 ($5–15) の大半を、
   捨てる出力のために使うことになる。**Phase 4 の目的は ops ループの検証**
   なので、rank ごと 1 ファイルの合成ペイロードを吐いて slot 回転 /
   `CURRENT` / 中断フラッシュ / 復元を検証する方式にした。物理は Phase 5 から

2. **parfile と FUKA 初期データは S3 の `inputs/` から取得する**

   上流ギャラリー著作物なので repo にも**イメージにも入れない**
   (シミュレーション repo は `upstream/` を gitignore + `.dockerignore` で
   ビルドコンテキストからも除外している)。ローカルで動いていたのは
   repo 全体を bind mount していたからで、クラウドには mount 元が無い。
   4 ファイル 1.6 MB を `make upload-inputs` で private バケットに置く。
   **ECR に焼かないのは、公開設定を誤ったときに著作物の再配布になるため**

   `.info` の `eosfile` は絶対パスなので user-data 側で `sed` して書き換える。
   **注意: このキーは行頭ではなくインデントされている**。`^eosfile` では
   マッチしないので `^[[:space:]]*eosfile` を使うこと (実ファイルで検証済み)。
   書き換えが効かなかった場合は起動時に fail-fast する

3. **checkpoint の mount 先を parfile に合わせた**

   parfile の `IO::checkpoint_dir = "../CHECKPOINTS"` は run の cwd 相対。
   parfile を触らず、mount 先を
   `$WORK/checkpoints:/home/etuser/simulations/<run_name>/CHECKPOINTS`
   にした (simulations mount の内側にネストさせる)。
   ホスト側では別ディレクトリのままなので、sidecar が checkpoint と output を
   区別できる。output sync 側にも `--exclude '*/CHECKPOINTS/*'` を保険で入れた

   **`run_name` は解像度を含めること**。checkpoint_dir が相対なので、
   親ディレクトリを共有すると `recover = autoprobe` が別解像度の checkpoint を
   拾う

   併せて `IO::checkpoint_ID = "yes"` を parfile 必須設定として記録。
   FUKA ID import は 24.9 分 (ローカル実測) かかり OpenMP 非対応なので、
   これが無いと**中断のたびに払う**ことになる

- 【解消】np≥2 の checkpoint 挙動は Phase 2 で確定 (np=16 で POSIX lock
  エラーゼロ、rank ごと 1 ファイル)。公式と同じ pure MPI 構成で問題ない
- 【入れ違い】申し送りノートの「`sync_interval_minutes = 20` は妥当」は、
  同日先行して 5 分 + slot 方式に変更済みのため superseded

### 本番 run の起動手順 (2026-08-27 時点、残りはこれだけ)

準備は全て完了している。**残っているのは tfvars の本番化と `make run` のみ。**

```hcl
run_mode            = "simulation"
instance_type       = "c7a.48xlarge"
run_name            = "prod-dx19p2-1750m"
parfile             = "bhns_gw230529.par"
image_tag           = "sha256:<digest>"   # 必ず digest で pin
mpi_procs           = 192
root_volume_size_gb = 500
sync_interval_minutes = 5
availability_zone   = "us-west-2d"
```

digest は `aws ecr describe-images --repository-name gw230529/einstein-toolkit
--image-ids imageTag=latest --query 'imageDetails[0].imageDigest' --output text`。
**tag ではなく digest なのは、中断→再起動でタグが動いていると別ビルドに
checkpoint を restore してしまうため。**

`make upload-inputs` → `make check-alerts` → `make plan-compute` → `make run`。

**run 中の監視は observer で無人で回る** (MFA 不要、素のシェルで):

```bash
env -u AWS_SESSION_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
  make throughput AWS_PROFILE=gw230529-observer     # sec/iter とコスト投影
  make validate-run AWS_PROFILE=gw230529-observer   # リファレンスとの照合
  make ledger AWS_PROFILE=gw230529-observer         # 稼働率とダウンタイム
  make heartbeat AWS_PROFILE=gw230529-observer      # メモリとディスク
```

budget アラートは run 中に 2 発鳴る想定 (190 で約 11.9 h 時点、240 で約 28.7 h)。
どちらもプロジェクト支出 50 / 100 USD に相当する意味のある通知。
**FORECASTED 440 は誤報で鳴りうる** — 年次 budget の予測が直近バーンを引くため。
実支出と突き合わせて読む運用で合意済み (2026-08-27)。

### 未確定 / 保留

- 【2026-08-21 解消】**フル解像度の sec/iter** — 実測 **4.16 sec/iter**
  (evolution ループ単体は 3.75)。t=2000 M まで **38.5 時間 / 115 USD**。
  上記「Phase 5 スループット実測」。probe は 105 分・約 5.2 USD

  **残った未知はこれに置き換わる: 合体時 (t≈713 M) の per-iteration コスト。**
  測定は t=0–63 M、つまり全体の 3% の純 inspiral 区間でしかない。格子点数は
  増えない (`Carpetregrid2` の半径は M 固定、`num_levels` も 8 固定) が、
  con2prim の反復回数は増えうる。**38.5 時間は下限に近い値**として扱う。
  安く測る方法は無い — 合体まで走らせるのが唯一の測り方なので、
  これは本番 run の中で監視する (`make throughput` を途中で回せばよい)
- 【解消】**checkpoint からの recover 実証** — sibling の Phase 2 で完了。
  `recover = "autoprobe"` が `it_256` を自動で拾い、**Kadath import 実行 0 回**。
  recover 読み込み + 終了時 checkpoint で 94 秒、cold start の 2065 秒に対し
  33 分の節約。spot 中断からの復帰は成立する
- 【2026-08-26 解消】**`IO::checkpoint_keep` は run をまたいで効かない** —
  sibling の Phase 2 で 2 run 後に 3 世代 77 GB が残った件。sidecar 側の刈り取りは
  **すでに実装済み** (`templates/user_data.sh.tftpl` の sync スクリプト、
  push の前に keep 世代だけ残す)。この項の「要対応」は実装前の記述で、古かった。

  2026-08-26 の recovery テストで **run をまたいだ刈り取りが実証された**。
  S3 から復元した `it_897` / `it_1049` に終了時 checkpoint `it_1124` が加わり、
  最終 slot は `it_1049` + `it_1124` の 2 世代。`it_897` は消えている。
  下記「Phase 5 recovery 実証」
- **【要対応】本番インスタンスタイプは Phase 5 のメモリ実測で確定する**。
  np=192 で単一ノードに載らない場合、マルチノード MPI は
  「学習目的の選択肢」から**必要条件**に格上げされる。

  **【2026-08-20 解消】実測 136 GiB (Carpet 125.273 GB)。384 GiB の 35%。**
  c7a.48xlarge を本番既定に昇格。上記「Phase 5 メモリ実測」。
  probe は 12 分・約 0.75 USD で済んだ (手順は
  `stacks/compute/terraform.tfvars.example` の memory probe プロファイル)
- **78 GB は dx=28 の 25 GB からの外挿**。フル解像度の実測は Phase 5 待ち。
  `root_volume_size_gb` と slot 設計はこの値に依存している。

  **【2026-08-20 解消】実測 85.7 GB/世代 (192 ファイル)。** 78 GB に対し +10%
  なので設計は成立する。keep=2 で EBS 171 GB・S3 343 GB。

  同じ dx=28 でも np=16 の 25 GB に対し np=32 は 30.1 GB で、rank 数が効く。
  正しい検算は **GF total 点数の比**を使うこと (解像度比だけの外挿は誤り、
  ghost 増分を別に掛けるのは二重計上になる)
- **IAM ユーザー `gw230529` に `policies/terraform-operator.json` を付与する**
  【2026-08-20 完了: `make check-permissions` で 109/109 allowed を確認済み】

  経緯 (2026-08-19〜20):
  1. 6 つの managed policy (EC2/S3/ECR/IAM/SNS/EventBridge FullAccess) を付与
     → budgets / ce / ssm / servicequotas が不足 (97 中 16 deny)
  2. 名前スコープ型のインラインポリシーに差し替え
     → s3/ec2/rds/dynamodb/lambda のみになり、ecr/iam/sns/events/budgets/ce/ssm
     が丸ごと欠落 (bootstrap は通るが foundation と compute が全滅)
  3. → **スコープ方針を維持したまま不足分を補った完成版**を作成。
     `make check-permissions-policy` で **109/109 allowed** を確認済み

  設計上の要点:
  - スコープ可能なサービスは `gw230529-*` で絞る (S3 / ECR / IAM / SNS /
    EventBridge / Budgets / SSM パラメータ)
  - **EC2 は名前でスコープできない**。ARN にプロジェクト名が入らないため、
    `arn:aws:ec2:*:*:*/*` のようなパターンは**全 EC2 リソースにマッチする**。
    「絞ったつもり」が一番危ない
  - 代わりに**破壊的 EC2 アクションに tag 条件付きの明示 Deny** を置く。
    `aws:ResourceTag/Project != gw230529` なら explicitDeny。
    provider の `default_tags` が全リソースに Project を打つので自分のものは
    消せる。検証済み: 自分=allowed / タグ無し=explicitDeny / 他=explicitDeny
  - `ce:*` / Session Manager / `ec2:GetSpotPlacementScores` などは
    AWS 側にリソースレベル権限が無いので `*`。README に理由を明記
  - ~~`iam:AttachUserPolicy` / `iam:CreatePolicy` を含めないので、
    **このユーザーは自分を admin に昇格できない**~~

    **【2026-08-26 訂正】この記述は誤りだった。** ユーザーポリシー経由は
    確かに塞がっているが、**role 経由が開いている**:

    | 材料 | 現状 |
    | --- | --- |
    | `iam:CreateRole` on `role/gw230529-*` | Allow、条件なし |
    | `iam:AttachRolePolicy` on `role/gw230529-*` | Allow、**`iam:PolicyARN` 条件なし** |
    | `iam:PutRolePolicy` on `role/gw230529-*` | Allow、条件なし |
    | `iam:PassRole` on `role/gw230529-*` | Allow、条件なし |
    | `ec2:*` on `*` | Allow、条件なし |

    `gw230529-*` という名前の role を作り、`AdministratorAccess` を
    アタッチし (**アタッチ先の role は絞られているが、アタッチする policy は
    絞られていない**)、`RunInstances` で EC2 に渡して IMDS から資格情報を読む。
    `DenyDestructiveEc2OnForeignResources` は破壊的アクションしか見ていないので
    `RunInstances` は素通りする。

    **誤った安心を与える記述が一番たちが悪い**ので、削除ではなく訂正として残す。

    対処は下記「operator 資格情報の設計」。MFA 必須の role を挟むことで、
    この経路に届くのが MFA を持つ本人だけになる。経路そのものを塞ぐには
    `iam:AttachRolePolicy` への `iam:PolicyARN` 条件 (この repo が実際に
    アタッチするのは `AmazonSSMManagedInstanceCore` の 1 つだけ) と、
    インラインポリシー用の **permissions boundary** が要る。後者は未実施

### operator 資格情報の設計 (2026-08-26 決定)

**人間が使う長期アクセスキーだけが、静的な資格情報として残っていた。**
ノードは最初から instance profile + role なので静的キーを持っていない
(`modules/iam`)。つまりワークロード側では「ローテーションを自動化」ではなく
**「長期キーを無くす」**という解き方を既にしていた。

| | IaC に入れる | 理由 |
| --- | --- | --- |
| ポリシー文書 / role / trust policy / MFA 条件 | **入れる** | 宣言的な事実 |
| **自分が認証に使うキーの材料** | **入れない** | 依存が循環する |
| 他プリンシパルのキー | 入れてよい | 依存の向きが一方向 |

`aws_iam_access_key` を Terraform に入れない理由は 2 つ:

1. **secret が state に平文で入り、state バケットは versioned**。後から消しても
   全バージョンに残る。「流出が心配だから IaC 化する」で、キーを S3 の
   消せない場所に恒久的に置くことになる
2. **Terraform が認証に使う資格情報を Terraform が管理する**。apply が途中で
   失敗すると手元に使える資格情報が無く、state ロックは今アクセスを失った
   バケットの中。bootstrap / foundation / compute を寿命で分けたのと同じ理屈

採用した構成:

```
[profile gw230529-bootstrap]   静的キー。単体では何もできない
[profile gw230529]             role_arn + mfa_serial + source_profile
```

- role `gw230529-terraform-operator` は **`stacks/bootstrap`** が持つ。
  foundation/compute はこの role で apply されるので、そこに置くと
  「自分を作る権限を自分が与える」循環になる。bootstrap が state をローカルに
  置いているのと同じ理由
- trust policy は `aws:MultiFactorAuthPresent = true` を **`Bool` で**要求する。
  `BoolIfExists` はキーが無いリクエストを通してしまい、この条件の存在意義を消す
- role には `prevent_destroy`。ユーザー側を絞った後にこの role を消すと
  **アカウントから締め出される** (復旧には admin が要る)
- ユーザー側は `policies/terraform-bootstrap-user.json` — `sts:AssumeRole` と
  自分のキーのローテーションのみ。適用は **admin から** (`iam:PutUserPolicy` は
  operator ポリシーに無い)

**キーのローテーションは手作業のまま**で、README の「Terraform で完結しない
手作業」に 3 つ目として記録した。role を挟んだことでローテーション頻度が
効かなくなる — キー単体では何もできないので。

**副作用として `make check` の隠れた依存が露見した。** `terraform init
-backend=false` はオフラインではなく、S3 backend で初期化済みのディレクトリでは
毎回 backend に手を伸ばす。静的キーが MFA 無しで黙って答えていたので
見えていなかった。`.terraform` があれば init を飛ばすようにして、
**プリコミットチェックは資格情報ゼロで通る**ようになった。

**`make login` が必要になった理由**: Terraform の AWS provider は MFA トークンを
聞けない (`AssumeRoleTokenProvider session option not set`)。AWS CLI の
`~/.aws/cli/cache` も Go SDK は読まない。`eval "$(make login)"` で
一時資格情報を環境変数に入れる。
- **user_data の Phase 4 TODO** — シミュレーション起動コマンドは
  本体 repo の Phase 2–3 (ローカル dx=28 run) でマウント構成と np≥2 の挙動が
  確定してから埋める

### 監査用 observer role の設計 (2026-08-26 決定、issue #10)

**MFA を要求すべきなのは「変える」側だけで、「見る」側ではなかった。**
8/26 の recovery テストで詰まった呼び出しは全部 read だった —
`CURRENT` マーカー、slot の `ls`、run 中の `bootstrap.log` 取得、
`make throughput` / `make heartbeat`、「終わった」と「詰まった」を
区別するための `DescribeInstances`。どれも operator role は要らないのに、
毎回 MFA デバイスを持つ人間に中継させていた。

`stacks/foundation` が `gw230529-observer` を作る。同じ IAM user が principal、
**MFA 条件なし**、権限は read のみ。

| | scope |
| --- | --- |
| data bucket | `ListBucket` + `GetObject`。バケット ARN は `module.storage.bucket_arn` から |
| state bucket | `ListBucket` は無条件、`GetObject` は **`foundation/*` と `compute/*` だけ** |
| EC2 | `Describe{Instances,InstanceStatus,SpotInstanceRequests,Volumes}` on `*` |
| CloudWatch | metric read on `*` |
| Cost Explorer | `GetCostAndUsage` / `GetCostForecast` on `*` |

- **`credential_process` + ローカル TOTP シードは却下**。6 桁の入力は消えるが、
  2 要素が同じ uid の同じディスクに載る。AWS は `MultiFactorAuthPresent = true`
  と評価し続けるので、`operator_role.tf` の条件が買っているものだけが消える。
  そもそも問題の形が違う — 摩擦は read 側にあり、read は第2要素の要らない部分
- **state を `foundation/*` だけに絞ると `make throughput` / `make heartbeat` が
  落ちる**。両方とも `stacks/compute output -raw run_prefix` を読む
  (`read_throughput.sh:85`、`tf.mk` の heartbeat)。issue #10 の権限表と
  "Done when" はこの点で矛盾していたので、`compute/*` を足した
- **2 つの prefix を列挙するのは `bootstrap/` を締め出すためではない。**
  `stacks/bootstrap` は state をローカルに置いている (自分がバケットを作るので
  自分をそこに置けない) ので、このバケットに `bootstrap/` という key は
  そもそも無い。列挙が買っているのは別のもの — **後から足したスタックが
  「初めて state を書いた瞬間に読める」のではなく、明示的に足すまで scope 外**
  であること。issue #10 の "Done when" にあった「bootstrap の state が
  AccessDenied になること」は、証明できない条件だった
- **state バケットの `ListBucket` は絞らない**。露出するのは stack 名だけで、
  それは repo に書いてある。絞る価値があるのは object の read の方
- **`ce:GetCostAndUsage` は入れた**。暴走支出に気づくのが watcher の仕事の大半で、
  budget アラートは閾値でしか鳴らない。露出はアカウント全体の請求データだが、
  このアカウントはこのプロジェクトしか持っていない。**この role で最初に削るなら
  ここ**、と `observer_role.tf` にコメントで書いた
- **`prevent_destroy` は付けない**。operator と違って、消えても締め出されない。
  ただし foundation を destroy すると observer profile は無言で AccessDenied になる

**払う対価を明記しておく。** これまでは access key 単体で**何も**できなかった
(唯一届く role が第2要素を要求したから)。以後は同じ key で simulation output と
checkpoint、foundation/compute の state が読める。作れず・変えられず・壊せず・
使えない (spend できない) のは変わらない。

**`terraform-bootstrap-user.json` は 2 本の ARN を明示列挙に変えた** (#8 step 2 が
まだ未適用なので、順序問題は発生しない)。`role/gw230529-*` のワイルドカードは
使わない — それは #8 step 3 のエスカレーション形状そのもの。

**ただし同一アカウントではこの列挙は「意図の記録」であって効力ではない可能性が
高い。** trust policy が user の ARN を名指ししていれば identity 側の
`sts:AssumeRole` は不要で、その証拠がこの repo にある:
`policies/terraform-operator.json` には `sts:` のアクションが 1 つも無いのに
`make login` は通っている。確認は
`aws iam list-attached-user-policies --user-name gw230529` と
`list-user-policies` の 2 発。

**検証結果 (2026-08-26)**:

| | 結果 |
| --- | --- |
| `sts:GetCallerIdentity` | MFA プロンプトなしで assumed-role として通る |
| `make throughput` / `make heartbeat` | 通る。**compute state の read が効いている証明** |
| `s3:PutObject` (data bucket) | AccessDenied |
| `ec2:TerminateInstances --dry-run` | UnauthorizedOperation |
| `iam:ListUsers` | AccessDenied |
| state の scope 外 read | **未証明**。下記 |

- **state バケットの scope 外テストは設計ミスだった。** `bootstrap/terraform.tfstate`
  を読もうとしたが、**bootstrap は state をローカルに置いている**ので object が
  存在しない。返ってきたのは 403 ではなく 404。ただし S3 は `ListBucket` が
  無いとき存在しない key にも 403 を返すので、**404 が返ったこと自体が
  `ListBucket` の疎通確認**にはなっている。
  state バケットには `foundation/` と `compute/` しか無く、scope 外に読める
  ものが物理的に存在しない。証明を取るなら operator で捨てオブジェクトを 1 つ
  置いて読み失敗させる (+ version ごと消す) 必要がある。優先度低

**`AWS_PROFILE=gw230529-observer` は operator セッションに負ける。**
`tf.mk` の `ifdef AWS_SESSION_TOKEN → unexport AWS_PROFILE` があるので、
`eval "$(make login)"` 済みのシェルでは環境の一時資格情報が使われる。
operator は observer にできることを全部できるので **エラーにならず、
observer を検証したつもりが operator で通る**。検証は必ず素のシェルで。


### budget の集計期間は暦年だった (2026-08-27 判明)

**`gw230529-01` の 150 USD 超過通知は誤報だった。** 通知時点のプロジェクト
支出は **17.34 USD**。鳴らせたのは、このプロジェクトが生まれる前の
アカウント支出 137.32 USD の方。

| 期間 | 額 | 中身 |
| --- | --- | --- |
| 2026-01-01 〜 08-18 | **137.32** | 前プロジェクトの NAT GW 59 + RDS 49 + Tax 等。4 月に撤去済み |
| 2026-08-19 〜 08-26 (gw230529) | **17.34** | EC2 12.96 / S3 / ECR |
| 合計 | 154.66 | = 通知の `ACTUAL Amount` と一致 |

**原因は AWS の 2 つの挙動が重なったこと:**

1. **`time_unit = "ANNUALLY"` の budget は暦年で集計され、
   `time_period_start` は無視される**。`2026-08-01_00:00` を渡していたが、
   実際の集計は 1/1 から。しかも **API は値をそのまま保存して読み返すので、
   `terraform plan` に差分が出ない**。設定した本人が一生気づけない形をしている
2. **`cost_allocation_tag` が null なので `cost_filter` が空**で、
   budget はアカウント全体を見ている。これは意図した既定
   (「有効化前のタグフィルタは何にもマッチしない」を避けるため) だが、
   **アカウントに他プロジェクトの過去支出があると誤報になる**

**確定に使った証拠 (推測ではない):**

- 通知メール本文の **`for the current year`** という文言と `ACTUAL Amount: $154.66`
- Cost Explorer の 2026 年 YTD 合計が **154.6557** で小数点まで一致
- foundation state の `aws_budgets_budget` に **`cost_filter=[]`**、
  `time_period_start=2026-08-01_00:00` (保存はされている)

**対処 (C 案: 今日止める + 後で本筋)**

`preexisting_spend_usd = 140` を追加し、cap と全閾値をシフトした。
閾値は**プロジェクト支出として読めるまま**で、AWS 側だけが暦年基準になる。

| | 変更前 | 変更後 |
| --- | --- | --- |
| cap | 300 | 440 |
| ACTUAL | 50/100/150/200/250/300 | 190/240/290/340/390/440 |
| FORECASTED | 300 | 440 |

140 の根拠は実測 137.32 + 年末まで続く非プロジェクト支出 (約 0.08 USD/日) の余裕。

- **放置できなかった理由は誤報そのものではなく、残枠**。本番 run 115 USD を
  足すと 270/300 に達し、**閾値 200 と 250 が run 中に鳴る**。どれも見に行く
  価値がない通知で、**アラートが狼少年になるのが実害**だった。
  修正後は run 開始から 10.9 h / 27.7 h に「プロジェクト 50 / 100 USD」で鳴る
- **`cost_filter` を使う案 (本筋) は run の後**。タグ有効化は遡及が保証されず、
  効き始めを検証する時間が本番前に無い。加えて **Tax や Cost Explorer API 料金は
  タグが付かないので budget から漏れる** — 既存の
  `cost_allocation_tag` の description が「アカウント全体が安全な既定」と
  書いているのはそこを見ていた
- **2027-01-01 に `preexisting_spend_usd = 0` に戻すこと。** 暦年が変われば
  前プロジェクトの支出は期間外になる。戻し忘れると閾値が 140 USD ぶん甘くなる

**残骸として月 0.9 USD の Secrets Manager (ap-northeast-1) がある**が、
**消してはいけないものが入っているので放置と決定 (2026-08-27)**。
年 10 USD 相当は budget を食うが、上記の余裕に織り込み済み。


### 本番 run の終点は 1750 M (2026-08-27 決定)

gallery の 2000 M から短縮。**33.7 時間 / 約 100 USD** (4.16 sec/iter)。

- 1500 M 案は「リングダウンの終了直後で終わる」ため却下 (Syota の判断)。
  r=500 の抽出面に合体波が届くのが t≈1213 M で、余白がない
- 2000 M は「ほとんど平坦な状態」— 残骸円盤の質量は merger + ~180 M で
  平坦化する (dx=28 dry run と参照 run の両方で確認)
- 1750 M = merger (t≈713 M) + ~1040 M。IMR 全体 + 初期円盤進化を収めて、
  平坦な尻尾 4.8 h / 約 15 USD を落とす
- 実装は `upload_inputs.sh` の 3 つ目の書き換え (`Cactus::cctk_final_time`)。
  既存の fail-fast 検査に乗せた。`CCTK_FINAL_TIME` 環境変数で上書き可
- `read_throughput.sh` の projection 既定も 1750 に変更

### S3 レイアウト変更と本番前 hardening (2026-08-27)

`fix/pre-production-hardening` ブランチで一括対応。

**レイアウトはカテゴリ先頭に変更 (#17, #5 を close)**:
`checkpoints/<run_name>/`, `output/<run_name>/`, `heartbeat/<run_name>/`,
`logs/<run_name>/`。lifecycle ルールは先頭一致しかできないので、
run_name 先頭の旧レイアウトでは**全ルールが何にもマッチしていなかった**
(524.8 GB / 月 12 USD が無期限滞留)。output sync の起点を
`simulations/<run_name>/` に絞ったので #5 の run_name 重複も同時に消えた。
compute の出力は `run_prefix` から用途別 (`run_log_url` / `heartbeat_url` /
`checkpoint_prefix` / `log_prefix`) に置き換え。
**旧レイアウトの既存データは移行しない** — recovery probe の素材
(throughput run の checkpoint) だけサーバサイドコピーで新レイアウトに移す。

**併せて close したもの**:

- **#9**: bootstrap ログをインスタンス id 付きキーに。同じ run_name の
  再実行 (= spot 中断からの再開そのもの) が前の run のログを上書きしない。
  versioning が意図的に off のバケットでは上書き = 即消失だった
- **#13**: `Carpet::physical_time_per_hour` は**プロセス開始からの累積平均**。
  10 分移動平均と誤読していた。cross-check は同一スパン (セグメント全体) の
  比較に変更。8/26 の NUMA run で旧実装は 1.308「壁時計を疑え」、新実装は
  1.000 (44.16 vs 44.2、issue の手計算と一致)
- **#14**: `make ssm` がエラーを握り潰す件。terraform の stderr を通し、
  セッション欠如と「インスタンス無し」を分離。heartbeat も同様
- **#15**: sync の flock 直列化。タイマー tick と最終 sync / spot flush の
  競合を封じた (待つ方式 — 直接呼び出しは落とせない push だから)
- **#16**: observer に `DescribeLaunchTemplate{s,Versions}` +
  `DescribeInstanceAttribute`。「何で起動したか」を state を読まずに監査できる。
  **注意: user_data は gzip されている** — `base64 -d | gunzip` が要る
- **#6**: operator に `ssm:SendCommand` (document / instance の 2 文に分割、
  instance 側は Project タグ条件) + `cloudwatch:GetMetricStatistics` +
  コマンド結果の read。simulator は 115 actions に増えた。
  **【要対応】ポリシー文書は repo に入ったが IAM ユーザーへの適用は未実施**。
  `iam:PutUserPolicy` は operator に無いので admin から
  `put-user-policy`。追加のみで削除は無いのでいつ適用してもよい
- **image_tag が digest を受けられなかった**のを修正 (`sha256:` なら `@` で
  結合)。本番は digest pin が必須 — 中断→再起動で mutable tag が動くと
  checkpoint を別ビルドに restore する

**リファレンスとの突き合わせバリデーション (実装・実証済み)**:

- 参照 run `bhns_20252103` (同一 dx=19.2、t=3051 M まで) の stdout が
  CarpetIOBasic info line を 4 iteration ごとに持ち、**うちの
  cactus-stdout.log と完全に同一フォーマット**
- 2026-08-27 実測: probe の重複 556 iteration で `rho_b` max と `H` max が
  **表示 7 桁まで一致** (max reduction は結合順に依存しないため)。
  `w_lorentz` は人工大気支配で中央値 1.2e-3
- 恣意的な閾値は置かない — 「同時刻の参照との比」なら正常値は定義から 1。
  3 層: NaNChecker の自動停止 (既存) / 比の変化の無人監視 (observer で
  読めるので MFA 不要) / 停止判断は人間。**自動 abort は足さない** —
  合体前後で「故障か物理か」の判別が変わり、固定ルールは必ず片側で誤る。
  Syota は console 目視 + cron の aws cli でも課金を監視する
- `make fetch-inputs ARGS=--reference` が参照ログを checksum pin で取得
  (573 MB、sibling の tarball を upstream/ に置けばダウンロード省略)
- **`scripts/validate_against_reference.sh` (`make validate-run`) として実装済み。**
  判定基準にもチューナブルを入れていない — **直近窓の中央値が、それ以前の
  最悪値を上回ったか**。誰かが選んだ係数が要らない形にした
- **限界**: 一致を測れたのは t=0–156 M の純 inspiral のみ。合体 (t≈713 M) 以降は
  丸め差が育つので**バンドは物理的に広がる**。これが自動 abort を足さない
  2 つ目の理由 — 固定ルールは合体の片側で必ず誤る

### recovery probe による本番前実証 (2026-08-27、約 2.2 USD)

`phase5-throughput-dx19p2` に 4 セグメント目として再起動し、当日の変更を
すべて実機で通した。**本番前に確認できることは全部確認した**。

| 検証項目 | 結果 |
| --- | --- |
| 新レイアウトからの restore | `restoring checkpoints from slot-a` 174.3 GB / 6.5 分 |
| NUMA 修正 (drop_caches) | `366 GiB available` |
| #11 stamp | restore の 2 秒後、初回 tick は `no new checkpoint generation` |
| recovery | `Recovering ... it_2220`、**Kadath import 0 回** |
| #9 ログ分離 | `bootstrap-i-02f2299a6532fede3.log` |
| #17 lifecycle | S3 が `rule-id="expire-checkpoints"` を返す |
| slot 回転 | slot-a → **slot-b**、中身 it_2220 + it_2605 |
| run をまたぐ刈り取り | it_1800 が消えている |
| 自滅 | 07:10:17 terminated |

**NUMA 修正が確定した:**

| | 8/26 (修正前) | **今回** | 8/21 fresh |
| --- | --- | --- | --- |
| 壁時計 sec/iter | 12.36 | **3.98** | 4.16 |
| ループ外オーバーヘッド | — | −0.6% | +23.7% |
| cross-check | 0.908 | **1.000** | 0.961 |

**recovery のコストはゼロ。** −0.6% は測定窓に checkpoint 書き込みが入らなかった
だけで、統計的に fresh と同じと読む。

**#17 の証拠は S3 自身に言わせた** — 設定を読むのではなく、同じ 450 MB の
ファイルで `Expiration: null` → `rule-id="expire-checkpoints"` の before/after。
`head-object` は `s3:GetObject` で足りるので observer で取れる。

### ダウンタイム計測 (2026-08-27、issue #20/#21)

**動機は診断ではなく実験**: 「安さのためにどの程度の遅延を許容できるか」を
決めるには、実 wall clock と実効計算時間の比が要る (Syota の判断)。

穴は 1 箇所だけだった — 中断されたノードは `bootstrap finished` 行に到達しないので
**開始はあるが終了が無い**。spot watcher が flush の**前に**
`logs/<run>/ended-<instance-id>.json` を書く (数百バイト、2 分の猶予に対し 1 秒未満)。
正常終了側にも同じ形を書くので、マーカーの無いログが「まだ走っている」か
「通知すら無く消えた」かの第 3 の結果として見える。

**`make ledger` は比を 2 つに分けて出す。** 混ぜると時間の行き先が読めない:

- **duty cycle** = uptime / wall clock — 中断と再起動までの遅れ
- **compute fraction** = evolution / uptime — 起動 1 回あたり**約 13 分**
  (boot + image pull + 174 GB restore + checkpoint 読み)

probe 実測は 58.2% だが、これは 30 分しか生きないノードの値。
**中断そのものより頻度が効く**: 4 時間で 95%、無中断 33.7 時間なら 99.4%。


### ポスプロはローカル Docker で行う (2026-08-29 決定)

OpenCAE 講演用の図と動画。**Lambda 案は実測で棄却した** — 前提だった
「クラウドでないと動かせない量のデータ」が成立しない:

- 本番 run の全出力は **9.7 GB / 1,865 ファイル**。図の材料は ~300 MB
  (mp_psi4.h5 3 MB、rho.xy.h5 89 MB、BH_diagnostics 1.6 MB、
  volume_integrals 43 KB、スカラー .asc 群)
- 数回しか呼ばないタスクに ECR push + Lambda + IAM + invoke 導線を作るのは
  開発コストが一桁重い。ゼロ待機コストはローカル実行でも同じ
- 実装は `postprocessing/` (Dockerfile + kuibit スクリプト 3 本) と
  `makefiles/post.mk` (`fetch-results` / `postproc-image` / `figures` /
  `movie` / `pack-results`)。イメージは依存のみ (kuibit 1.5.1 / matplotlib
  3.10.5 / h5py 3.14.0 を pin)、スクリプトは bind mount で編集にリビルド不要
- **VisIt は使わない**。ギャラリーの動画スクリプトは VisIt だが、29 フレームの
  2D データに GUI 志向の巨大インストールは釣り合わない。kuibit の
  read_on_grid で 8 レベルを 800² に合成して matplotlib で描く

**データ側の確定事項** (2026-08-29 実測):

- **ψ4 は mp_psi4.h5 を使うこと**。ASCII の multipole 出力は同じ 15.36 M
  サンプリングしか持たず、参照 run の密な .asc と混同しやすい (一度誤読した)。
  127 点・dt=15.36 M で合体まで 7〜17 サンプル/周期 — チャープ図は成立、
  リングダウン末尾は角張る。ピークは **t=1213.44 M** で既知値と一致
- **2D は 29 フレームが上限** (out2D_every=1024 = 61.44 M ごと)。
  合体を密に吐き直す checkpoint は keep=2 で疾うに消えている。
  動画は 3 fps コマ送り、講演には 3 枚パネル (t=0 / 737 / 1720) が主力
- **recovery の巻き戻しで .asc に重複 iteration がありうる**。
  ギャラリー join.sh の gawk と同じ問題。common.py の dedup_sorted が処理
- **`output/` は 90 日で expire する** (11 月末 = 講演直前)。
  `make fetch-results` は作図の入力取得であると同時にデータ保全。
  図の確定後は `make pack-results` で tar.gz 1 個に畳んで生ツリーを消す
  (NAS がオブジェクト単位で Deep Archive にバックアップされるため、
  ファイル数を減らすこと自体が目的)

## 言語設定

このプロジェクトでは**日本語**での応答を行う。ただし以下は**英語必須**。

**英語必須** — リポジトリにコミットされる成果物の中身:

- `*.tf` / `*.tftpl` のコメントと `description`
- `Makefile` / `makefiles/*.mk` のコメント、ヘルプテキスト (`## コメント`)、`echo` 出力
- `scripts/*.sh` のコメントとメッセージ
- `README.md`, `docs/*.md`
- `.env.example`, `*.tfvars.example`, `backend.hcl.example` のコメント
- コミットメッセージ

**日本語で可** — 人間が読む記録:

- `CLAUDE.md` (本ファイル)
- `.claude-notes/` のセッションノート
- チャット上の応答

**重要**: 他リポジトリからファイルをコピーして流用する場合も、
**コピー元の日本語コメントは必ず英語に書き換える**こと。

## 開発ルール

### Terraform 規約

- 変数・出力・リソース名: snake_case
- すべての変数に `description` を書く。単位と既定値の根拠を含める
- **なぜその選択なのかをコメントに残す**。特にコストを理由に却下した代替案は
  必ず書く (後から「なぜ NAT を使わないのか」を再発見させない)
- モジュールは `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` に分割
- provider は `~> 6.0` で固定、`.terraform.lock.hcl` はコミットする
- コミット前に `make check` (fmt-check + validate + check-secrets)

### 上流ギャラリー成果物の扱い (2026-08-20 決定)

parfile と FUKA 初期データ (4 ファイル 1.6 MB) は **本 repo が自分で取得する**。
以前は `INPUTS_DIR` が `../gw230529-einstein-toolkit/upstream` を指していたが、
これだと**本 repo を単独 clone したマシンで production run ができない**うえ、
その依存がどこにも宣言されていなかった。

- `make fetch-inputs` — ギャラリーから取得。**SHA-256 で pin**。
  落とし先 `upstream/` は gitignore。repo が持つのは **URL と checksum だけ**で、
  これは再配布ではなく出典の記録
- `make upload-inputs` — **上流 parfile をそのままは上げない**。COSMA8 向けの
  `checkpoint_every_walltime_hours = 29` は spot だと中断 1 回で 14.5 時間の損失。
  クラウド用に 2 行を書き換え、4 設定を検査してから S3 へ

| キー | 上流 | クラウド | 扱い |
| --- | --- | --- | --- |
| `checkpoint_every_walltime_hours` | 29 | **1.0** | 書き換え |
| `checkpoint_ID` | 記述なし (既定 "no") | **"yes"** | 追加 |
| `recover` | "autoprobe" | 同 | 検査のみ |
| `checkpoint_keep` | 2 | 同 | 検査のみ |

- 上流ファイルは無改変で残し、派生を `upstream/.cloud/` に作る
- 検査に落ちたら**何も上げない**。sed が黙って空振りするのが最悪なので、
  `.info` の `eosfile` 書き換えと同じ fail-fast 規律を通す
- sibling 側は何も変えなくてよい。クラウド用設定は本 repo の責任

### 秘匿情報の扱い

gitignore 済み: `*.tfvars` / `*.tfstate*` / `backend.hcl` / `.env` / `.terraform/`

- backend は **partial configuration**。`terraform init -backend-config=backend.hcl`
- 追跡ファイルに 12 桁数値・ARN・`AKIA` が入ると `make check-secrets` が落ちる
- **アカウント ID の秘匿は多層防御であって境界ではない**。境界は IAM。
  この仕組みは `terraform output` の貼り付け事故を止めるためのもの

### Terraform で完結しない手作業

1. **SNS subscription の確認** — apply 後、2 通の確認メールの
   「Confirm subscription」をクリック (すぐ下の解除リンクではない)。
   購読は**あとから 1 クリックで消える**。SNS が送る全メールに解除リンクが
   付いていて、消えても Terraform の state 上はリソースが残るので誰も気づかない。
   気づくのは「鳴るべきときに鳴らなかった」瞬間。
   `make check-alerts` で実際に配信できるかを検査でき、`make run` は
   どちらかが無効なら**課金を始める前に停止する** (`SKIP_ALERT_CHECK=1` で回避可)
2. **コスト配分タグ `Project` の有効化** — Billing コンソール。有効化するまで
   タグフィルタは何にもマッチしないので、`cost_allocation_tag` は既定で null
   (アカウント全体を対象にする方が安全)。

   **ただしアカウント全体を見るということは、他プロジェクトの支出も
   この budget を食うということ。** 2026-08-27 にそれで誤報が出た。
   暫定対処は `preexisting_spend_usd`、本筋はこのタグの有効化。
   上記「budget の集計期間は暦年だった」
3. **spot vCPU クォータ緩和** — `L-34B43A08` を 192 以上に

## Git運用

- ブランチ戦略: feature/*, fix/*, refactor/*
- コミットメッセージ: 英文を使用、動詞から始める
- PRはmainブランチへ

### コミット粒度

- **1コミット = 1つの主要な変更**
- **論理的な単位でコミット**
- **段階的コミット**

### プレフィックスと絵文字

- ✨ feat: 新機能
- 🐞 fix: バグ修正
- 📚 docs: ドキュメント
- 🎨 style: コードスタイル修正
- 🛠️ refactor: リファクタリング
- ⚡ perf: パフォーマンス改善
- ✅ test: テスト追加・修正
- 🏗️ chore: ビルド・補助ツール
- 🚀 deploy: デプロイ
- 🔒 security: セキュリティ修正
- 📝 update: 更新・改善
- 🗑️ remove: 削除

**重要**: Claude Codeを使用してコミットする場合は、必ず以下の署名を含める：

```text
🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## ドキュメント更新プロセス

機能追加や Phase 完了時には以下を同期更新する:

1. **CLAUDE.md**: 設計判断の確定・保留状況
2. **README.md**: 手順とコストモデル
3. **docs/architecture.md**: 構成図と根拠
4. **Makefile / makefiles/**: ヘルプテキスト (`## コメント`)
