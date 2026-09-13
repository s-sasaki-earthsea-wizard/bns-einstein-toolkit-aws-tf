# BNS Einstein Toolkit — AWS Infrastructure (Terraform)

## プロジェクト概要

Einstein Toolkit gallery の [BNS example](https://einsteintoolkit.org/gallery/bns/index.html)
を AWS の spot ノード 1 台で回すための Terraform。
[gw230529-einstein-toolkit-aws-tf](https://github.com/s-sasaki-earthsea-wizard/gw230529-einstein-toolkit-aws-tf)
の sibling で、**2026-09-13 にそこからの verbatim import として起こした**。
最初のコミットは完全なコピー、以降のコミットが「BNS のために変えたもの」の一覧。

設計の全体像と根拠は [docs/architecture.md](docs/architecture.md)、
ユーザー向けの手順と現状は [README.md](README.md)。本ファイルは運用ルールと
「何が測れていて何が測れていないか」を記す。

### 3 つの repo の関係

| repo | 役割 | BNS での扱い |
| --- | --- | --- |
| `gw230529-einstein-toolkit` | Docker イメージのビルド (ET_2025_05 + FUKA) | **イメージはここで作る**。NSTracker を 1 行足す再ビルドが要る |
| `gw230529-einstein-toolkit-aws-tf` | BHNS の AWS 実行環境。本番 run 完了 (2026-08-29) | 設計と実測の出典。wiki に実測値 |
| `bns-einstein-toolkit-aws-tf` (本 repo) | BNS の AWS 実行環境 | **足場のみ。apply も run も未実施** |

### 現状 (2026-09-13)

| | 状態 |
| --- | --- |
| Terraform 3 スタック、sidecar、spot 処理、relaunch loop、監視 | 継承済み。`make check` 通過。`bns` prefix では未 apply |
| gallery 入力 (parfile / LORENE データ / thornlist) | 取得・checksum pin 済み。派生 parfile は Cactus の param check 通過 |
| コンテナイメージ | **NSTracker が無い**。他の thorn は全部 `gw230529-et:local` にコンパイル済み |
| AWS 上の sec/iter、メモリ、checkpoint サイズ、import 時間 | **未計測**。数字は全部見積り |
| gallery 自身のログとの照合 (`make validate-run`) | 動作確認済み (自己比較でゼロ差)。live run では未使用 |
| ポスプロ | BHNS 用スクリプトのまま |

**残作業は全部 GitHub issue にしてある。** 新しい未確定事項もまず issue に書くこと。

### 出自と流用の方針

- **コード中の「2026-08-xx に実測」という記述はすべて GW230529 のもの。**
  BNS で測り直すまで、それらは設計の根拠であって本 repo の数字ではない。
  `docs/architecture.md` の該当セクションには provenance の注記を入れた
- スラグは `gw230529` → `bns` に機械置換した (URL は除く)。IAM role / S3 /
  ECR / SNS / budget / systemd unit / `WORK_DIR=/opt/bns` まで全部
- **同一 AWS アカウントで GW230529 と同居する前提**。role 名は別 (`bns-*`) だが
  IAM user・budget・cost allocation tag は交差する (issue 参照)

## 確定済みの設計判断

### GW230529 から無変更で継承したもの

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| リージョン | us-west-2 | ECR/S3 がリージョン束縛。GW230529 の選定理由はインスタンスサイズに依存しない |
| state backend | S3 + native lockfile | DynamoDB 不要 |
| S3 構成 | 1 バケット + カテゴリ先頭の prefix (`checkpoints/<run>/` 等) + lifecycle | ルールは先頭一致しかできない |
| ネットワーク | public subnet + IGW + S3 Gateway Endpoint、ingress なし | NAT は月 33 USD |
| スタック分割 | bootstrap / foundation / compute (寿命別) | compute の destroy がデータに届かない |
| spot | `aws_instance` + one-time spot、`run_enabled` フラグ、relaunch loop | 再開が `terraform apply` 1 発 |
| checkpoint 同期 | slot-a/b 交互 + `CURRENT` マーカー、push 成功後にのみ書く、sidecar が keep 世代に刈る | 中断で torn set を掴まない |
| recovery | restore 直後に `drop_caches` + `--stamp-only` | NUMA 配置が壊れて 3 倍遅くなる事故の修正 |
| 資格情報 | operator role (MFA 必須) + observer role (read only、MFA なし) | 「変える」側だけが MFA |
| 監視 | `make throughput` / `validate-run` / `ledger` / `heartbeat` を observer で | 無人で回る |

### BNS で変えたもの

| 論点 | 決定 | 理由 |
| --- | --- | --- |
| インスタンス | **c7a.24xlarge (96 コア / 192 GiB) を仮置き**。16xlarge と 48xlarge が代替 | gallery run が 32 rank で 43.8 GB (Carpet) / 約 89 GiB 常駐。192 rank だと ghost だらけ (GW230529 は 52k 点/rank で total = active の +95%) |
| 並列形状 | **24 rank × 4 thread の hybrid** | gallery の Frontera 構成。GRHydro/ML_BSSN は OpenMP 対応。**binding は未設定** (issue) |
| 終点 | `cctk_final_time = 2500` (gallery のまま) | 合体 t≈1750 + HMNS 750。`CCTK_FINAL_TIME` で上書き可 |
| budget | cap 200 USD、閾値 25/50/75/100/150/200 | run 見積り 40–135 USD + probe + 再起動 |
| root volume | 300 GB | checkpoint 35–50 GB 見積り × keep 2 + 出力 |
| parfile 派生 | 7 点 (下記) | gallery は simfactory + バッチキュー前提 |
| リファレンス | gallery の `bns-20260604.tar.gz` の stdout (`results/bns-1905387.out`) | 毎 iteration の info line、フォーマット同一 |

### parfile の派生 (`scripts/upload_inputs.sh`、2026-09-13 決定)

| キー | 上流 | クラウド | 扱い |
| --- | --- | --- | --- |
| `IO::checkpoint_every_walltime_hours` | 無し (終了時のみ) | **1.0** | 追加 |
| `IO::checkpoint_keep` | 無し (既定 1) | **2** | 追加 |
| `IO::checkpoint_dir` / `recover_dir` | `$parfile` | **`"../CHECKPOINTS"`** | 書き換え。sidecar の mount 分離に合わせる |
| `TerminationTrigger::max_walltime` | `@WALLTIME_HOURS@` | **8760** | 書き換え。simfactory の placeholder は Cactus が読めない |
| `HTTPD` + `Socket` | active | **削除** | ingress が無いので無用、かつ**コンテナ内で socket を bind できず segfault** (`-P` で実測) |
| `IO::checkpoint_ID` | "yes" | 同 | 検査のみ |
| `IO::recover` | "autoprobe" | 同 | 検査のみ |
| `Meudon_Bin_NS::filename` | 絶対パス | basename のみ検査 | ノードが起動時に mount 先へ書き換え、fail-fast |

- LORENE データ (`.resu.xz` 3.6 MB) は **fetch 時にローカルで展開して 12 MB の `.resu` を上げる**。
  ノードに xz 依存を持ち込まない。展開後の checksum も pin
- `-P` (`--exit-after-param-check`) は **NSTracker 入りイメージでないと thorn activation で落ちる**。
  それまでは `LOCAL_IMAGE` に無いイメージ名を渡して SKIP させるか、NSTracker を
  手で外した写しで検査する (2026-09-13 に後者で通過。ML_BSSN の deprecated
  パラメータ警告 level 1 が出るが gallery 由来で無害)

## gallery 側の事実 (2026-09-13 読み取り)

| 項目 | 値 |
| --- | --- |
| ID | LORENE `G2_I12vs12_D4R33T21_45km`: Γ=2、baryon mass 1.4456 M☉ × 2、ADM 2.695 M☉、45 km |
| 物理 | GRHydro + ML_BSSN + EOS_Omni polytrope (K=123.6)。磁場なし |
| 対称性 | RotatingSymmetry180 + ReflectionSymmetry → 1/4 領域 |
| 格子 | 400 立方、dx₀=8、星ごと 7 levels (finest 0.125)、半径 240/120/60/26.1/17.9/13。NSTracker で追従 |
| `max_refinement_levels` | **9**。Trigger が合体後に原点へ 7 levels (崩壊時 8) を移し、星の箱を切る。**dt/iter は最初から 0.0125** (finest possible level 基準) |
| 時間 | final 2500 → **200,000 iteration** |
| 合体 | rho_max のステップ t=1751、ψ4 (r=300) ピーク t=2059 → **t≈1750** |
| 出力 | 2D xy を 1536 it (=19.2 M☉) ごと → 130 フレーム。ψ4 は ASCII (8 半径、l≤6)。info line 毎 iteration |
| Teton run (2026-06-04) | 2 ノード × 384 コア (32 rank × 24 thread)、**10 h 33 min**、Carpet 43.777 GB、maxrss 2.86 GB/rank × 32 ≈ 89 GiB |
| Teton のレート | 合体前 15.8 s/M☉、**合体後 13.5 s/M☉ (速くなる)** |
| Frontera (ページ記載) | `--procs=128 --num-threads=4` で約 30 h、約 64 GB |

## 見積り (未計測、probe で置き換える)

| アンカー | c7a.24xlarge 1 台 (24×4) | c7a.48xlarge 1 台 |
| --- | --- | --- |
| Frontera 3,840 core-h × Genoa 1.3–1.8 倍 | 22–31 h / 43–61 USD | 11–16 h / 33–47 USD |
| Teton 8,100 core-h (24 thread/rank の効率込み) | 40–60 h / 80–115 USD | 20–30 h / 60–89 USD |
| GW230529 の 4.16 s/it を point-update あたりで適用 (上限) | 約 75 h / 約 146 USD | 45 h / 約 134 USD |

- 格子点数の計数: BNS 8.3 M 点 (1/4 領域)、point-update 356 M / coarse step × 781 step = 0.28 T。
  GW230529 (→1750) は 0.21 T。**仕事量は 1.33 倍、per-point は軽い**
- 全領域 (非等質量・磁場) なら ×4–5
- Spot Advisor (us-west-2、2026-09-13): 16xlarge 63% / 5–10%、24xlarge 62% / >20%、48xlarge 69% / 10–15%

## 未確定 / 要対応

GitHub issue に一覧がある。主なもの:

- イメージに NSTracker を足して ECR へ (最優先、これが無いと何も動かない)
- 90 分 throughput probe (c7a.24xlarge、次に 16xlarge)。sec/iter・メモリ・checkpoint サイズ・import 時間・cold start
- parfile 派生と user_data の LORENE 経路を実機で通す (ops-rehearsal → 短い simulation)
- IAM: operator user を新設するか `gw230529` user を流用するか。bootstrap-user policy に `bns-*` 2 role を足す
- budget の同居問題: `preexisting_spend_usd` の実測、cost allocation tag の有効化
- hybrid の thread binding (`mpirun.mpich` の bind/map、`OMP_PROC_BIND`)
- validate-run / read_throughput を live run で検証。Trigger による level 追加後の投影
- ポスプロを BNS 出力 (ASCII multipole、rho.xy.h5 130 フレーム、AH なし) に合わせる
- GW230529 から持ち越した #22 (capacity 探索) / #23 (relaunch principal) / #25 (loop の停止理由) / #27 (dashboard)
- 2 分警告内に checkpoint が書けるか (TerminationTrigger の termination file 経由)

## 言語設定

このプロジェクトでは**日本語**での応答を行う。ただし以下は**英語必須**。

**英語必須** — リポジトリにコミットされる成果物の中身:

- `*.tf` / `*.tftpl` のコメントと `description`
- `Makefile` / `makefiles/*.mk` のコメント、ヘルプテキスト (`## コメント`)、`echo` 出力
- `scripts/*.sh` のコメントとメッセージ
- `README.md`, `docs/*.md`, GitHub issue / PR
- `.env.example`, `*.tfvars.example`, `backend.hcl.example` のコメント
- コミットメッセージ

**日本語で可** — 人間が読む記録:

- `CLAUDE.md` (本ファイル)
- `.claude-notes/` のセッションノート
- チャット上の応答

## 開発ルール

### Terraform 規約

- 変数・出力・リソース名: snake_case
- すべての変数に `description` を書く。単位と既定値の根拠を含める。
  **根拠が GW230529 の実測なら、そう書く**
- **なぜその選択なのかをコメントに残す**。特にコストを理由に却下した代替案
- モジュールは `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` に分割
- provider は `~> 6.0` で固定、`.terraform.lock.hcl` はコミットする
- コミット前に `make check` (fmt-check + validate + check-secrets)

### 上流ギャラリー成果物の扱い

parfile、LORENE 初期データ、thornlist は **本 repo が自分で取得する**
(`make fetch-inputs`、SHA-256 pin)。落とし先 `upstream/` は gitignore。
repo が持つのは **URL と checksum だけ**。イメージにも ECR にも入れない。

- `make upload-inputs` — 上流 parfile をそのままは上げない。上記「parfile の派生」
  の 7 点を書き換え・検査してから S3 へ。検査に落ちたら**何も上げない**
- 上流ファイルは無改変で残し、派生を `upstream/.cloud/` に作る
- `make fetch-inputs ARGS=--reference` で gallery の results tarball (88 MB) から
  stdout / 実行 parfile / run notes を取り出す

### 秘匿情報の扱い

gitignore 済み: `*.tfvars` / `*.tfstate*` / `backend.hcl` / `.env` / `.terraform/` / `upstream/`

- backend は **partial configuration**。`terraform init -backend-config=backend.hcl`
- 追跡ファイルに 12 桁数値・ARN・`AKIA` が入ると `make check-secrets` が落ちる
- **アカウント ID の秘匿は多層防御であって境界ではない**。境界は IAM

### Terraform で完結しない手作業

1. **SNS subscription の確認** — apply 後、2 通の確認メールをクリック。
   `make check-alerts` で配信可否を検査、`make run` は無効なら課金前に停止
2. **コスト配分タグ `Project` の有効化** — Billing コンソール。
   **GW230529 と同居するアカウントでは、これをしないと両方の budget が
   互いの支出を数える**
3. **spot vCPU クォータ** — `L-34B43A08` を 96 以上に。GW230529 を回した
   アカウントなら us-west-2 は 256 済み
4. **IAM user 側のポリシー適用** — `policies/terraform-bootstrap-user.json` は
   admin から `put-user-policy`。operator には `iam:PutUserPolicy` が無い

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

機能追加や計測の完了時には以下を同期更新する:

1. **CLAUDE.md**: 設計判断の確定・保留状況、「現状」表
2. **README.md**: 「Status」表、手順、コストモデル
3. **docs/architecture.md**: 構成図と根拠。GW230529 の provenance 注記は
   BNS の実測で置き換えたら外す
4. **Makefile / makefiles/**: ヘルプテキスト (`## コメント`)
5. **GitHub issue**: 解消したら close、新しい未確定事項は起票
