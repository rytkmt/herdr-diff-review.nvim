# herdr-diff-review.nvim

AIエージェントのファイル変更を、適用前にNeovimのdiffモードで確認・承認/拒否できるようにするプラグイン。

Claude Code（またはPreToolUseフック対応の任意のエージェント）がファイルを編集しようとすると、Herdrの専用タブにNeovimでdiffが表示される。コマンド1つで承認/拒否を選択すると、自動でエージェントのタブにフォーカスが戻る。

## 仕組み

```
エージェントが Edit/Write を実行しようとする
        │
        ▼
PreToolUse フックがインターセプト
        │
        ├─ 変更前/変更後のtempファイルを作成
        ├─ Herdrの "diff-review" タブを開く（または再利用）
        ├─ 常駐Neovimにdiffバッファを送り込む（--server / --remote-expr）
        ├─ ユーザーの操作を待機
        │
        ▼
:HerdrDiffReviewAccept または :HerdrDiffReviewDeny を実行
        │
        ▼
フックがallow/denyをエージェントに返し、フォーカスがエージェントタブに戻る
```

Neovimはレビュー間で常駐し続ける。バッファだけが差し替わる。

## 必要環境

- [Herdr](https://herdr.dev) >= 0.7.4
- Neovim >= 0.10
- jq
- Claude Code（またはPreToolUseフック対応エージェント）

## インストール

### 1. リポジトリのクローン

```sh
git clone https://github.com/rytkmt/herdr-diff-review.nvim.git ~/.local/share/herdr-diff-review.nvim
```

### 2. Herdrプラグインの登録

```sh
herdr plugin link ~/.local/share/herdr-diff-review.nvim
```

### 3. Neovimプラグインの追加

lazy.nvim:

```lua
{
  "rytkmt/herdr-diff-review.nvim",
  lazy = false,
  opts = {},
}
```

### 4. Claude Codeフックの設定

`~/.claude/settings.json` の `hooks.PreToolUse` に追加:

```json
{
  "matcher": "Edit|Write",
  "hooks": [
    {
      "type": "command",
      "command": "bash ~/.local/share/herdr-diff-review.nvim/hooks/claude-diff-review.sh",
      "timeout": 300
    }
  ]
}
```

`timeout` はNeovimでの操作待ち最大秒数（デフォルト300秒 = 5分）。

## 使い方

diffが表示されたら:

| コマンド | 動作 |
|----------|------|
| `:HerdrDiffReviewAccept` | 変更を承認 |
| `:HerdrDiffReviewDeny` | 変更を拒否 |

これらのコマンドはdiff確認中のみ有効。キーマップは自由に設定可能:

```lua
vim.keymap.set("n", "<leader>da", "<cmd>HerdrDiffReviewAccept<cr>")
vim.keymap.set("n", "<leader>dd", "<cmd>HerdrDiffReviewDeny<cr>")
```

## 設定

環境変数（任意）:

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `DIFF_REVIEW_TIMEOUT` | 300 | 操作待ち最大秒数 |
| `DIFF_REVIEW_POLL_INTERVAL` | 0.5 | 結果確認の間隔（秒） |

## 動作の詳細

- **初回呼び出し**: "diff-review" ラベルのHerdrタブを作成し、`--listen`付きでNeovimを起動
- **2回目以降**: ソケット経由で同じNeovimを再利用。バッファだけ差し替え
- **Neovimが死んだ場合**: 次のdiff時にタブとNeovimを自動再作成
- **Herdr外** (`HERDR_ENV`未設定): フックは何もせず通過。エージェントは通常動作
- **サブエージェント**: `agent_id`で検知し、レビューなしで自動許可
- **タイムアウト**: deny扱い

## プロジェクト構成

```
herdr-diff-review.nvim/
├── herdr-plugin.toml            Herdrプラグインマニフェスト
├── hooks/
│   └── claude-diff-review.sh    PreToolUseフック（メインロジック）
├── lua/
│   └── diff-review/
│       └── init.lua             Neovimプラグイン（diff表示 + コマンド）
└── scripts/
    └── start-nvim.sh            常駐Neovim起動スクリプト
```
