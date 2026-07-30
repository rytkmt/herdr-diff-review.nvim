# herdr-diff-review.nvim

AIエージェントのファイル変更を、適用前にNeovimのdiffモードで確認・承認/拒否できるようにするプラグイン。

Claude Code（またはPreToolUseフック対応の任意のエージェント）がファイルを編集しようとすると、Herdrにdiffが表示される。コマンド1つで承認/拒否を選択すると、自動でエージェントのタブにフォーカスが戻る。

## 仕組み

```
エージェントが Edit/Write を実行しようとする
        │
        ▼
PreToolUse フックがインターセプト
        │
        ├─ 変更前/変更後のtempファイルを作成
        ├─ 表示モードに応じてタブまたはペインを作成
        ├─ Neovimを起動しdiffを表示
        ├─ ユーザーの操作を待機
        │
        ▼
:HerdrDiffReviewAccept または :HerdrDiffReviewDeny を実行
        │
        ▼
フックがallow/denyをエージェントに返し、タブ/ペインを閉じる
```

## 必要環境

- [Herdr](https://herdr.dev) >= 0.7.4
- Neovim >= 0.10
- jq
- Claude Code（またはPreToolUseフック対応エージェント）

## インストール

### 1. リポジトリのクローン

任意の場所にクローン:

```sh
git clone https://github.com/rytkmt/herdr-diff-review.nvim.git ~/path/to/herdr-diff-review.nvim
```

### 2. Herdrプラグインの登録

```sh
herdr plugin link ~/path/to/herdr-diff-review.nvim
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
      "command": "bash ~/path/to/herdr-diff-review.nvim/hooks/claude-diff-review.sh",
      "timeout": 1900
    }
  ]
}
```

`timeout` はフックの最大待ち秒数。`DIFF_REVIEW_TIMEOUT`（デフォルト1800秒）より大きい値を設定すること。スクリプト側のタイムアウトが先に発動してクリーンアップを行うため、フック側が先にkillされるとペインが残ったままになる。

## 使い方

diffが表示されたら:

| コマンド | 動作 |
|----------|------|
| `:HerdrDiffReviewAccept` | 変更を承認 |
| `:HerdrDiffReviewDeny` | 変更を拒否 |

modified側のバッファは編集可能。変更してからAcceptすると、編集後の内容がファイルに反映される。modified側で`:w`を実行してもAcceptとして扱われる。

キーマップはsetupで設定可能（diff表示中のバッファにのみ適用される）:

```lua
{
  "rytkmt/herdr-diff-review.nvim",
  lazy = false,
  opts = {
    keymaps = {
      accept = "<leader>da",
      deny = "<leader>dd",
      accept_with_message = "<leader>dA",
      deny_with_message = "<leader>dD",
    },
  },
}
```

## 設定

環境変数（任意）:

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `DIFF_REVIEW_MODE` | tab | 表示モード: `tab` / `vertical_split` / `horizontal_split` |
| `DIFF_REVIEW_TIMEOUT` | 1800 | 操作待ち最大秒数。AIエージェント側のフックtimeoutより短い値にすること |
| `DIFF_REVIEW_POLL_INTERVAL` | 0.5 | 結果確認の間隔（秒） |

### 表示モード

- **tab** (デフォルト): 新しいHerdrタブを作成してdiffを表示。画面全体を使えるため差分が大きいときに見やすい
- **vertical_split**: 現在のペインを横に分割してdiffを表示
- **horizontal_split**: 現在のペインを縦に分割してdiffを表示

## 動作の詳細

- **レビューごとにNeovimを起動**: 毎回新しいNeovimインスタンスでdiffを表示し、操作完了後にタブ/ペインごと閉じる
- **Herdr外** (`HERDR_ENV`未設定): フックは何もせず通過。エージェントは通常動作
- **サブエージェント**: `agent_id`で検知し、レビューなしで自動許可
- **タイムアウト**: deny扱い

## プロジェクト構成

```
herdr-diff-review.nvim/
├── herdr-plugin.toml            Herdrプラグインマニフェスト
├── hooks/
│   └── claude-diff-review.sh    PreToolUseフック（メインロジック）
└── lua/
    └── herdr-diff-review/
        └── init.lua             Neovimプラグイン（diff表示 + コマンド）
```
