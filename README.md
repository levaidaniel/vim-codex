# vim-codex

A lightweight integration between **classic Vim** and the Codex CLI App Server. Ask questions about the current file, continue a conversation from a shared log buffer, and review proposed code changes in Vim's built-in diff mode.

## Features

- Ask questions or request changes from Vim without leaving the editor.
- Include the current file and working directory as context for every request.
- Use a Visual selection as context and, for changes, as the replacement region.
- Continue the conversation from the shared `Codex-Log` buffer while retaining the source-file context.
- Display proposed edits in a side-by-side diff without automatically changing the original file.
- Extract a JSON response object even if the response contains text around it.
- Keep separate raw incoming and outgoing protocol logs for debugging.

## Requirements

- **Classic Vim** with `+job`, `+channel`, and JSON support.
- The [Codex CLI](https://github.com/openai/codex), installed and authenticated.
- The `codex` executable available on Vim's `PATH`.

Check Vim's compiled features with:

```vim
:version
```

The plugin starts the App Server with:

```sh
codex app-server --listen stdio://
```

## Installation

1. Create the plugin directory if it does not exist:

   ```sh
   mkdir -p ~/.vim/plugin
   ```

2. Copy `codex.vim` to:

   ```text
   ~/.vim/plugin/codex.vim
   ```

3. Restart Vim, or load the plugin in the current session:

   ```vim
   :source ~/.vim/plugin/codex.vim
   ```

## Usage

### Start a request

Run `:Codex` or press `\ca` in Normal mode. The plugin opens a small prompt buffer at the bottom of the editor. Type your question or instructions, then submit with `\s` or `:CodexSend`.

You can also pass an initial prompt directly:

```vim
:Codex Explain this function
```

The prompt editor opens with that text, so you can edit it before sending.

### Ask about a selection

Select lines in Visual mode and press `\ca`, or run `:CodexSelection` while a selection is active. The selected lines are included in the request context.

For a change request, the plugin asks Codex to return a replacement for the selected region. Without a Visual selection, it asks for a replacement for the complete file.

### Continue from the conversation log

The shared `Codex-Log` buffer shows your prompts and Codex's explanations. Open it with `:CodexShow` or `\cs`.

While viewing the log, use `:Codex` (or `\ca` in Normal mode) to compose a follow-up. The plugin reuses the existing chat window and retains the last source-file context, so you can continue discussing or changing the same file without switching back to it first.

Use `\cr` as an additional Normal-mode shortcut for `:Codex`.

## Key bindings and commands

The default Vim `<Leader>` is `\`. If you have changed `mapleader`, substitute your configured leader for `\`.

| Binding | Mode | Action |
|---|---|---|
| `\ca` | Normal | Open a prompt for a question or change request |
| `\ca` | Visual | Open a prompt with the selected lines as context |
| `\cr` | Normal | Alias for `\ca`; open a prompt for the current conversation |
| `\cs` | Normal | Show the shared conversation log |
| `\s` | Prompt buffer, Normal mode | Submit the prompt |
| `\s` | Prompt buffer, Insert mode | Submit the prompt |

Available commands:

| Command | Action |
|---|---|
| `:Codex [text]` | Open a prompt, optionally prefilled with text |
| `:CodexSelection [text]` | Open a prompt using the Visual selection as context |
| `:CodexShow` | Show the shared conversation log |
| `:CodexSend` | Submit the current prompt buffer |

`CodexSend` is defined locally in the prompt buffer and is available while that buffer is active.

## Reviewing proposed changes

1. Open the file you want to work on.
2. Optionally select the lines to replace in Visual mode.
3. Run `:Codex` or press `\ca`, then describe the change.
4. Submit the prompt with `\s`.
5. Review the proposal in the diff view.

The diff view opens in a new tab with the original file and a `Codex-Proposal-*` buffer side by side, plus the conversation log below. If you supplied a Visual selection, the proposal replaces that region; otherwise, it represents the complete file.

**The plugin does not automatically write the proposal into the original file.** Review the diff and apply the changes you want manually using Vim's diff workflow or ordinary editing. Save the original file only after you are satisfied with the result.

## Debug logs

For troubleshooting, the plugin appends raw JSON-RPC messages to these files:

```text
~/.vim/plugin/codex/codex-vim-outgoing.log
~/.vim/plugin/codex/codex-vim-incoming.log
```

The outgoing log records `turn/start` requests; the incoming log records messages received from the App Server. These logs can contain your prompts, source-file contents, and Codex responses. Review them before sharing, and remove them when they are no longer needed.

## Limitations and notes

- The Codex conversation thread is not saved for restoration in a later Vim session.
- The visible conversation log is maintained in Vim buffers and plugin variables; it is not a standalone conversation-history database.
- Raw protocol debug logs are persisted separately in the files described above.
- The plugin expects Codex responses to follow the JSON schema in the request. Responses without a usable JSON object, or with an unsupported response mode, are reported in the log.
- This plugin targets classic Vim, not Neovim, and may require updates as Vim or the Codex CLI App Server evolves.
