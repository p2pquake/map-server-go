# map-server-go

[epsp-peer-cs](https://github.com/p2pquake/epsp-peer-cs) の `CLI map server` (C#) と同じ API を持つ地図生成サーバーの Go 実装です。
Cloud Run などで最小インスタンス数 0 のまま運用しても、コールドスタート直後から高速に応答することを目的としています。

epsp-peer-cs の `MapServerGo` から移植しました。

## 使い方

```sh
go run . -port 17101            # カレントディレクトリの resources を使います
```

| オプション | 説明 |
|---|---|
| `-port` | 待ち受けポート。省略時は環境変数 `PORT`、それもなければ `17101` |
| `-resources` | リソース (`Maps`, `Images`, `Points`) のディレクトリ。省略時は環境変数 `MAP_RESOURCES`、実行ファイルと同じ場所の `resources`、カレントディレクトリの `resources` の順に探します |
| `-preload` | 起動時に読み込んでおく地図 (例: `JAPAN_1024,JAPAN_4096`)。既定は初回利用時に読み込み |

エンドポイントとリクエスト形式は epsp-peer-cs の `CLI/Command/ServerSubCommand.cs` と同じです。

| パス | 内容 |
|---|---|
| `/test` | ヘルスチェック (`OK`) |
| `/earthquake` | 地震情報 (震度・震源) |
| `/tsunami` | 津波予報 |
| `/eew` | 緊急地震速報 (警報) |
| `/userquake` | 地震感知情報 |

リクエスト例は `testdata/` にあります。

```sh
curl -X POST --data-binary @testdata/eq_chiba_1024.json localhost:17101/earthquake -o out.png
```

## テスト

```sh
go test ./...
```

`testdata/cases.json` の出力サイズは、同じリクエストを C# 版に送ったときのものです。トリム範囲の計算が C# 版と一致することを確認します。

## Docker

```sh
docker build -t map-server-go .
docker run --rm -p 8080:8080 map-server-go
```

イメージは distroless (static-debian13, nonroot) ベースです。環境変数 `PORT` で待ち受け、SIGTERM で終了します。

## Cloud Run

サービスの設定は `service.yaml` にあります。

| 項目 | 値 | 理由 |
|---|---|---|
| CPU / メモリ | 1 vCPU / 512 MiB | JAPAN_4096 の全域描画でも 1 リクエスト約 170 MB |
| 同時実行数 | 1 | 描画は CPU を使い切るため、同時に処理しても速くならない |
| インスタンス数 | 最小 0 / 最大 10 | 未使用時は課金されない。集中時に足りなければ最大値を増やす |
| 起動時 CPU ブースト | 有効 | コールドスタートを短くする |
| `GOMEMLIMIT` | 450MiB | メモリ上限に近づいたら GC を強める |
| 起動プローブ | `GET /test` | |

JAPAN_8192 は使わない前提です。JAPAN_8192 の全域描画は 1 リクエストで約 420 MB を使うため、使う場合はメモリを 1 GiB 以上にしてください。

### デプロイ

```sh
PROJECT=your-project
REGION=asia-northeast1
IMAGE=$REGION-docker.pkg.dev/$PROJECT/map-server-go/map-server-go:$(git rev-parse --short HEAD)

# 初回のみ: Artifact Registry のリポジトリを作る
gcloud artifacts repositories create map-server-go --repository-format=docker --location=$REGION --project=$PROJECT

# イメージをビルドして、サービスを作成・更新する
gcloud builds submit --tag "$IMAGE" --project=$PROJECT
sed "s#image: IMAGE#image: $IMAGE#" service.yaml > /tmp/map-server-go.yaml
gcloud run services replace /tmp/map-server-go.yaml --region=$REGION --project=$PROJECT
```

作成したサービスは、呼び出しに IAM 認証 (`roles/run.invoker`) が必要です。誰でも呼び出せるようにする場合は、次を実行します。

```sh
gcloud run services add-iam-policy-binding map-server-go --region=$REGION --project=$PROJECT \
  --member=allUsers --role=roles/run.invoker
```

## C# 版との違い

- 描画結果: トリム範囲 (出力画像のサイズ) は C# 版と同じ計算です (`go test` で確認)。
  アンチエイリアスや縮小の実装が異なるため、ピクセル単位では完全には一致しません (平均差 0.4/255 以下)。
- 線の描画 (津波予報の海岸線、緊急地震速報・地震感知情報の輪郭線、震源の × 印) は継ぎ目を丸めています。
- C# 版では例外になる一部の入力 (アイコンのない震度など) は、その地点を描画せずに続行します。
- ピア分布図 (フォントを使う描画) は地図サーバーから使われていないため移植していません。
- C# 版は描画後に地図全体から切り抜きますが、Go 版は切り抜く範囲だけを描画します (結果は同じ)。

## 性能 (参考)

### 起動から生成完了まで

epsp-peer-cs での計測です。千葉県東方沖の地震 (2026/08/30、199 地点) を使い、プロセス起動から JAPAN_1024 と JAPAN_4096 の地震情報を
順に生成し終えるまでの時間 (各 30 回の中央値、CPU 1 コアに制限)。

| 実装 | 起動〜両方生成完了 | 2 回目以降の JAPAN_4096 |
|---|---|---|
| C# (.NET 6, `CLI map server`) | 1158 ms | 220 ms |
| C# (.NET 8) | 1129 ms | 175 ms |
| Go (この実装) | 141 ms | 30 ms |

### メモリ使用量

起動直後のプロセスに 1 リクエストを送ったときの最大 RSS です。メモリ使用量はほぼ出力画像の面積で決まります。

| リクエスト | 出力サイズ | 処理時間 (1 回目 / 2 回目) | 最大 RSS |
|---|---|---|---|
| JAPAN_4096 地震・トリムあり | 786×524 | 63 ms / 15 ms | 36 MB |
| JAPAN_4096 地震・トリムなし | 4096×4200 | 450 ms / 433 ms | 173 MB |
| JAPAN_4096 津波 (広域) | 4096×4007 | 435 ms / 395 ms | 163 MB |
| WORLD_512 地震 | 512×256 | 23 ms / 8 ms | 15 MB |
| WORLD_1024 地震 | 1418×710 | 44 ms / 29 ms | 22 MB |
| JAPAN_8192 地震・トリムなし | 8192×8400 | 1.73 s / - | 421 MB |

## ライセンス

プログラムは [MIT License](LICENSE) です。`resources/` 以下のデータは epsp-peer-cs の `Map/Resources` から必要なものだけを取り出したもので、それぞれ次のライセンスに従います。

- `resources/Maps/`: 詳細は [resources/Maps/README.md](resources/Maps/README.md) を参照してください。
  - ファイル名に `gsi` を含む地図データの日本部分は [地理院タイル](https://maps.gsi.go.jp/development/ichiran.html) を使用しています ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode.ja) 互換)。
  - それ以外の地図データは [GSHHG](https://www.soest.hawaii.edu/pwessel/gshhg/) のデータを使用して [GMT](https://www.generic-mapping-tools.org/) で生成したもので、LGPL v3 です (`LICENSE.TXT`, `COPYINGv3`, `COPYING.LESSERv3`)。
- `resources/Points/`: 気象庁が公開している情報 (CC BY 4.0) とその加工物です。詳細は [resources/Points/README.md](resources/Points/README.md) を参照してください。
- `resources/Images/`: epsp-peer-cs の [LICENSE](https://github.com/p2pquake/epsp-peer-cs/blob/master/LICENSE) (MIT License) に従います。

日本地図には、地理院タイルの出典 (`resources/Images/description.png`) を描き込んでいます。
