# herdr-diff-review.nvim

AIエージェントのファイル変更を、適用前にNeovimのdiffモードで確認・承認/拒否できるようにするプラグイン。

Claude CodeまたはKiro CLI（PreToolUseフック対応エージェント）がファイルを編集しようとすると、Herdrにdiffが表示される。コマンド1つで承認/拒否を選択すると、自動でエージェントのタブにフォーカスが戻る。

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

### 4. エージェントのフック設定

本プラグインはClaude CodeとKiro CLIの両方に対応。入力JSONの形式から自動判別するため、同じスクリプトを使用できる。

#### Claude Code

`~/.claude/settings.json` の `hooks.PreToolUse` に追加:

```json
{
  "matcher": "Edit|Write",
  "hooks": [
    {
      "type": "command",
      "command": "bash ~/path/to/herdr-diff-review.nvim/hooks/diff-review.sh",
      "timeout": 1900
    }
  ]
}
```

`timeout` はフックの最大待ち秒数。`DIFF_REVIEW_TIMEOUT`（デフォルト1800秒）より大きい値を設定すること。スクリプト側のタイムアウトが先に発動してクリーンアップを行うため、フック側が先にkillされるとペインが残ったままになる。

#### Kiro CLI

`~/.kiro/agents/kiro_default.json` を作成（全ワークスペース共通で適用される）:

```json
{
  "name": "kiro_default",
  "allowedTools": ["write"],
  "hooks": {
    "preToolUse": [
      {
        "matcher": "write",
        "command": "bash ~/path/to/herdr-diff-review.nvim/hooks/diff-review.sh",
        "timeout_ms": 1900000
      }
    ]
  }
}
```

`timeout_ms` はミリ秒単位。`DIFF_REVIEW_TIMEOUT`（デフォルト1800秒 = 1800000ms）より大きい値を設定すること。

> **重要**: `allowedTools` に `write` を含める必要がある。含めない場合、preToolUseフックがallowを返した後にKiro CLI自体のパーミッション承認プロンプトが表示され、Herdr環境では正しく動作しない。`allowedTools` に含めても、preToolUseフックによるdiff reviewが承認ゲートとして機能するため安全性は維持される。

> 特定のエージェントにのみ適用したい場合は、`.kiro/agents/<agent-name>.json`（ローカル）または `~/.kiro/agents/<agent-name>.json`（グローバル）の `hooks.preToolUse` に同様の設定を追加する。

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
- **ワークスペース対応**: 同じワークスペースならdiffタブに即座にフォーカス。別ワークスペースの場合はフォーカスを奪わず、そのワークスペースに切り替えた時点でdiffタブにフォーカスされる
- **Herdr外** (`HERDR_ENV`未設定): フックは何もせず通過。エージェントは通常動作
- **サブエージェント**: Claude Codeの場合、`agent_id`で検知しレビューなしで自動許可（Kiroではサブエージェント判定をスキップ）
- **タイムアウト**: deny扱い

## ツールごとの制限事項

| 機能 | Claude Code | Kiro CLI |
|------|:-----------:|:--------:|
| Accept | ✓ | ✓ |
| Deny | ✓ | ✓ |
| Accept with message（メッセージ付き承認） | ✓ | ✗ |
| Deny with message（メッセージ付き拒否） | ✓ | ✓ |
| Accept edited（修正して承認） | ✓ | ✓ |

Kiro CLIでは、PreToolUseフックが`exit 0`（allow）を返す際のstdoutはLLMのコンテキストに追加されない仕様のため、Accept時にメッセージを付与してもエージェントには伝わらない。Deny時のメッセージ（stderr経由）は正常にエージェントに返される。

## プロジェクト構成

```
herdr-diff-review.nvim/
├── herdr-plugin.toml            Herdrプラグインマニフェスト
├── hooks/
│   └── diff-review.sh    PreToolUseフック（メインロジック）
└── lua/
    └── herdr-diff-review/
        └── init.lua             Neovimプラグイン（diff表示 + コマンド）
```
