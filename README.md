# vim-codex

A lightweight Codex CLI integration for **classic Vim**. Ask questions from Vim, continue a Codex conversation, keep replies in a shared log buffer, and review proposed code changes with Vim's built-in diff mode.

## Requirements

- Classic Vim with `+job`, `+channel`, and JSON support
- [Codex CLI](https://github.com/openai/codex) installed and authenticated

Check Vim features with `:version`.

## Installation

1. Create the plugin directory if needed:

   ```sh
   mkdir -p ~/.vim/plugin
   ```

2. Save `codex.vim` to `~/.vim/plugin/codex.vim`.
3. Restart Vim, or load it with:

   ```vim
   :source ~/.vim/plugin/codex.vim
   ```

## Key bindings

The default Vim `<Leader>` is `\`.

| Binding | Mode | Action |
|---|---|---|
| `\ca` | Normal | Ask a general question |
| `\ca` | Visual | Ask about the selected lines |
| `\cd` | Visual | Request a replacement and open a diff |
| `\cr` | Normal | Reply in the current Codex conversation |
| `\cs` | Normal | Show the shared conversation log |

You can also use these commands:

- `:CodexAsk [question]`
- `:CodexAskSelection [question]` (with a visual selection)
- `:CodexDiff [instructions]` (with a visual selection)
- `:CodexReply [message]`
- `:CodexShow`

If no question or reply text is provided, Vim prompts for it.

## Diff workflow

1. Select the lines to change in Visual mode.
2. Press `\cd` and describe the change.
3. Review the proposed version in the side-by-side diff.
4. Apply only the changes you want using Vim's diff commands or manual editing.

The plugin does **not** automatically write proposed changes to the original file. Save the original file only after reviewing and applying the changes you want.

## Notes and limitations

- The plugin communicates with `codex app-server --listen stdio://`.
- A new Vim session does not automatically restore the previous Codex thread.
- The conversation log is held in Vim buffers and variables; this version does not persist it to a file.
- This is a small plugin; behavior may need adjustment for your Vim setup or future Codex CLI versions.
