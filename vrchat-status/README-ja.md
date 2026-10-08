# VRChat Status

VRChatのステータスをNoctaliaのバーに表示し、パネルから変更できるプラグインです。

## プラグイン


| Field | Value |
| --- | --- |
| ID | `surumeika1987/vrchat-status` |
| Entries | Bar widget:`status`;panel:`status-panel` |


## 必要要件

本プラグインを使用するには、`vrchat-status-helper`が必要です。

`vrchat-status-helper`を`PATH`の通った場所に配置するか、プラグイン設定から実行ファイルの場所を指定してください。

## 使用方法

### 1. バックグラウンドデーモンをセットアップする

`vrchat-status-helper`をリポジトリからダウンロードするか、ソースコードからビルドしてください。

[noctalia-vrchat-status-helper](https://github.com/surumeika1987/noctalia-vrchat-status-helper)

`vrchat-status-helper`を`PATH`の通った場所に配置します。

例:

```sh
$HOME/.local/bin/vrchat-status-helper
```

次に、以下のコマンドを実行してVRChatにログインしてください。

```sh
vrchat-status-helper login
```

ログイン後、`vrchat-status-helper`がバックグラウンドで起動するよう設定します。

Hyprlandなどのデスクトップ環境・コンポジタの起動時に`vrchat-status-helper`を実行するよう設定してください。  
Hyprlandの例
```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("noctalia")
    hl.exec_cmd("/home/<your name>/.local/bin/vrchat-status-helper")
end)
```

### 2. プラグインを有効にする

プラグインマネージャーから本プラグインをインストールしてください。

手動でインストールする場合は次のコマンドを実行します。  
```sh
mkdir -p $HOME/.local/share/noctalia/plugins
git clone https://github.com/surumeika1987/noctalia-vrchat-status.git \
    $HOME/.local/share/noctalia/plugins/vrchat-status
```

その後、Noctaliaの設定画面から`surumeika1987/vrchat-status`を有効にします。

バーの設定から`VRChat Status`を追加してください。

### パネルを開く

パネルはバーの`VRChat Status`ウィジェットから開くことができます。

IPCから直接開く場合は、以下のコマンドを使用します。

```sh
noctalia msg panel-toggle surumeika1987/vrchat-status:status-panel
```

## 設定
プラグイン設定では以下の設定ができます。  

| 設定名 | 値 | デフォルト | 説明 |
| --- | --- | --- | --- |
| vrchat-status-helper path | `ファイル` | `vrchat-status-helper` | vrchat-status-helperのパス |

ウィジェット設定では以下の設定ができます。  
| 設定名 | 値 | デフォルト |説明 |
| --- | --- |--- | --- |
| Join Me | `色` | `#3B82F6` |Join Meステータスの色 |
| Online | `色` | `#3CB371` | Onlineステータスの色 |
| Ask Me | `色` | `#F59E0B` | Ask Meステータスの色 |
| Do Not Disturb | `色` | `#EF4444` | Do Not Disturbステータスの色 |
| Offline | `色` | `#6B7280` | Offlineステータスの色 |
| Status message color | `Match status` `Fixed color` | `Match status` |ステータスメッセージの色モード |
| Fixed message color | `色` | `#FFFFFF` |`Fixed Color`の場合のメッセージの色 |
| Min Length | `整数` | `100` | ウィジェットの最小サイズ |
| Max Length | `整数` | `300` | ウィジェットの最大サイズ |

## 注意事項

本プラグインではVRChat APIを使用します。

VRChat APIの利用によって発生した問題について、本プラグインの開発者は責任を負いません。

`vrchat-status-helper`および本プラグインは自己責任で使用してください。

## 開発者向け

`vrchat-status-helper`から本プラグインへのデータ送信には、NoctaliaのIPC機能を使用しています。

以下のコマンドで、外部プログラムからステータス情報をプラグインへ送信できます。

```sh
noctalia msg plugin surumeika1987/vrchat-status:status all push-status '<payload>'
```

`payload`の形式は以下のとおりです。

```text
<Status Number>:<Status Message>
```

`Status Number`には`0`から`4`までの1桁の数字を指定します。

- `4`: `Join Me`
- `3`: `Online`
- `2`: `Ask Me`
- `1`: `Do Not Disturb`
- `0`: `Offline`

たとえば、ステータスを`Join Me`、ステータスメッセージを`Test Message`にする場合は以下のようになります。

```sh
noctalia msg plugin surumeika1987/vrchat-status:status all push-status '4:Test Message'
```

## ノート
**API**: 非公式の`VRChatAPI`を利用しています。  
**認証**:
クッキーを`$XDG_CACHE_HOME/noctalia/vrchat-status/cookies.txt`又は  
`~/.cache/noctalia/vrchat-status/cookies.txt`に権限`0600`で保存します。  
**プロセス**: 外部ソフトウェア`vrchat-status-helper`が必要です。  
**ソケット**: `vrchat-status-helper`はUnixソケットを`$XDG_RUNTIME_DIR/vrchat-status-helper.sock`に作成します。  
