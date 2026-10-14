" Minimal Codex App Server integration for classic Vim.
" Requires Vim with +job and +channel, plus the Codex CLI.

if !has('job') || !has('channel') || !exists('*json_encode')
    echoerr 'vim-codex requires Vim +job, +channel and JSON support'
    finish
endif

let g:codex_vim_job = get(g:, 'codex_vim_job', v:null)
let g:codex_vim_thread = get(g:, 'codex_vim_thread', '')
let g:codex_vim_next_id = get(g:, 'codex_vim_next_id', 1)
let g:codex_vim_pending = get(g:, 'codex_vim_pending', {})
let g:codex_vim_busy = get(g:, 'codex_vim_busy', 0)
let g:codex_vim_output_buf = get(g:, 'codex_vim_output_buf', -1)
let g:codex_vim_output = get(g:, 'codex_vim_output', '')
let g:codex_vim_prompt = get(g:, 'codex_vim_prompt', '')
let g:codex_vim_cwd = get(g:, 'codex_vim_cwd', '')

let g:codex_vim_diff_mode = 0
let g:codex_vim_diff_source_buf = -1
let g:codex_vim_diff_first = 0
let g:codex_vim_diff_last = 0
let g:codex_vim_diff_original = []

if !exists('g:codex_vim_log_buf')
    let g:codex_vim_log_buf = bufnr('Codex-Log')
endif

if !exists('g:codex_vim_log')
    let g:codex_vim_log = g:codex_vim_log_buf > 0
                \ ? join(getbufline(g:codex_vim_log_buf, 1, '$'), "\n") . "\n"
                \ : ''
endif

let g:codex_vim_last_turn_output = ''


" ---------------------------------------------------------------------------
" Log rendering
" ---------------------------------------------------------------------------

function! s:Render() abort
    let l:buf = g:codex_vim_log_buf

    if l:buf <= 0 || !bufexists(l:buf)
        return
    endif

    let l:text = g:codex_vim_log . g:codex_vim_output
    let l:lines = split(l:text, "\n", 1)

    if empty(l:lines)
        let l:lines = ['']
    endif

    let l:old_count = len(getbufline(l:buf, 1, '$'))

    call setbufline(l:buf, 1, l:lines)

    if l:old_count > len(l:lines)
        call deletebufline(l:buf, len(l:lines) + 1, l:old_count)
    endif

    " Follow new output when the log is visible, without leaving its window
    " focused if the user was working elsewhere.
    let l:winnr = bufwinnr(l:buf)

    if l:winnr > 0
        let l:current_winnr = winnr()

        execute l:winnr . 'wincmd w'
        normal! G

        if l:current_winnr != l:winnr
            execute l:current_winnr . 'wincmd w'
        endif
    endif
endfunction


function! s:LogAppend(text) abort
    let g:codex_vim_log .= a:text
    call s:Render()
endfunction


function! s:ShowLog() abort
    let l:buf = g:codex_vim_log_buf

    if l:buf > 0 && bufexists(l:buf)
        let l:winnr = bufwinnr(l:buf)

        if l:winnr > 0
            execute l:winnr . 'wincmd w'
            return
        endif

        botright split
        execute 'buffer ' . l:buf
    else
        botright new
        silent file Codex-Log

        let g:codex_vim_log_buf = bufnr('%')

        setlocal buftype=nofile
        setlocal bufhidden=hide
        setlocal noswapfile
        setlocal nowrap
    endif

    let g:codex_vim_output_buf = g:codex_vim_log_buf
endfunction


function! s:Append(text) abort
    let g:codex_vim_output .= a:text
    call s:Render()
endfunction


" ---------------------------------------------------------------------------
" Codex App Server JSON-RPC
" ---------------------------------------------------------------------------

function! s:SendRaw(message) abort
    if type(g:codex_vim_job) != v:t_job
        throw 'Codex process is not running'
    endif

    call ch_sendraw(
        \ job_getchannel(g:codex_vim_job),
        \ json_encode(a:message) . "\n")
endfunction


function! s:Notify(method, params) abort
    call s:SendRaw({
        \ 'jsonrpc': '2.0',
        \ 'method': a:method,
        \ 'params': a:params
        \ })
endfunction


function! s:Request(method, params, kind) abort
    let l:id = g:codex_vim_next_id
    let g:codex_vim_next_id += 1

    let g:codex_vim_pending[string(l:id)] = a:kind

    call s:SendRaw({
        \ 'jsonrpc': '2.0',
        \ 'id': l:id,
        \ 'method': a:method,
        \ 'params': a:params
        \ })

    return l:id
endfunction


function! s:SendTurn() abort
    let g:codex_vim_busy = 1
    let g:codex_vim_output = 'Waiting for Codex...'

    call s:Render()

    call s:Request('turn/start', {
        \ 'threadId': g:codex_vim_thread,
        \ 'input': [{
        \   'type': 'text',
        \   'text': g:codex_vim_prompt
        \ }]
        \ }, 'turn')
endfunction


function! s:ExtractFinalText(params) abort
    let l:turn = get(a:params, 'turn', {})
    let l:items = get(l:turn, 'items', [])
    let l:parts = []

    for l:item in l:items
        if get(l:item, 'type', '') ==# 'agentMessage'
            if has_key(l:item, 'text')
                call add(l:parts, l:item.text)
            endif

            for l:part in get(l:item, 'content', [])
                if type(l:part) == v:t_dict
                    if has_key(l:part, 'text')
                        call add(l:parts, l:part.text)
                    endif
                endif
            endfor
        endif
    endfor

    return join(l:parts, "\n")
endfunction


" ---------------------------------------------------------------------------
" Diff view
" ---------------------------------------------------------------------------

function! s:OpenDiff() abort
    let l:source_buf = g:codex_vim_diff_source_buf

    if l:source_buf <= 0 || !bufexists(l:source_buf)
        echoerr 'CodexDiff: original buffer no longer exists'
        return
    endif

    let l:text = substitute(
                \ g:codex_vim_last_turn_output, '^\s\+', '', '')
    let l:text = substitute(l:text, '\s\+$', '', '')
    let l:replacement = split(l:text, "\n", 1)

    " Remove Markdown fences if Codex included them.
    if !empty(l:replacement) && l:replacement[0] =~# '^```'
        call remove(l:replacement, 0)

        if !empty(l:replacement)
                    \ && l:replacement[-1] =~# '^```'
            call remove(l:replacement, -1)
        endif
    endif

    if empty(l:replacement)
        echoerr 'CodexDiff: Codex returned no replacement code'
        return
    endif

    " Build a full-file proposal, replacing only the selected lines.
    let l:original = g:codex_vim_diff_original
    let l:proposal = []

    if g:codex_vim_diff_first > 1
        let l:proposal = l:original[
                    \ 0 : g:codex_vim_diff_first - 2]
    endif

    let l:proposal += l:replacement

    if g:codex_vim_diff_last < len(l:original)
        let l:proposal += l:original[g:codex_vim_diff_last :]
    endif

    " Open a new tab showing the original and proposed versions.
    tabnew
    execute 'buffer ' . l:source_buf
    call cursor(g:codex_vim_diff_first, 1)

    rightbelow vnew
    execute 'file Codex-Proposal-' . bufnr('%')

    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal nowrap

    call setline(1, l:proposal)
    setlocal nomodified

    diffthis
    wincmd h
    diffthis
    wincmd l

    echo 'CodexDiff: review the proposal; the original has not been changed.'
endfunction


" ---------------------------------------------------------------------------
" Server output callbacks
" ---------------------------------------------------------------------------

function! s:OnOut(channel, line) abort
    if empty(a:line)
        return
    endif

    try
        let l:msg = json_decode(a:line)
    catch
        call s:Append("\n[Codex: invalid JSON response]")
        return
    endtry

    " Responses to our JSON-RPC requests.
    if has_key(l:msg, 'id')
        let l:key = string(l:msg.id)
        let l:kind = get(g:codex_vim_pending, l:key, '')

        if has_key(g:codex_vim_pending, l:key)
            call remove(g:codex_vim_pending, l:key)
        endif

        if has_key(l:msg, 'error')
            let l:err = get(
                        \ l:msg.error, 'message', string(l:msg.error))

            call s:Append("\n[Codex error: " . l:err . "]")

            let g:codex_vim_busy = 0
            let g:codex_vim_diff_mode = 0
            return
        endif

        if l:kind ==# 'initialize'
            call s:Notify('initialized', {})

            call s:Request('thread/start', {
                \ 'cwd': g:codex_vim_cwd
                \ }, 'thread')

        elseif l:kind ==# 'thread'
            let l:result = get(l:msg, 'result', {})
            let l:thread = get(l:result, 'thread', {})

            let g:codex_vim_thread = get(l:thread, 'id', '')

            if empty(g:codex_vim_thread)
                call s:Append(
                            \ "\n[Codex error: thread/start returned no thread ID]")

                let g:codex_vim_busy = 0
                return
            endif

            call s:SendTurn()
        endif

        return
    endif

    " Streaming assistant text.
    let l:method = get(l:msg, 'method', '')
    let l:normalized = substitute(tolower(l:method), '_', '', 'g')
    let l:params = get(l:msg, 'params', {})

    if stridx(l:normalized, 'agentmessage') >= 0
                \ && stridx(l:normalized, 'delta') >= 0

        let l:delta = get(l:params, 'delta', '')

        if type(l:delta) == v:t_string && !empty(l:delta)
            if g:codex_vim_output ==# 'Waiting for Codex...'
                let g:codex_vim_output = ''
            endif

            call s:Append(l:delta)
        endif

    elseif l:method ==# 'turn/completed'
        let g:codex_vim_busy = 0

        if g:codex_vim_output ==# 'Waiting for Codex...'
                    \ || g:codex_vim_output ==# 'Starting Codex...'
                    \ || empty(g:codex_vim_output)

            let l:final = s:ExtractFinalText(l:params)

            if !empty(l:final)
                let g:codex_vim_output = l:final
            else
                let g:codex_vim_output =
                            \ '[Turn completed; no assistant text was captured.]'
            endif
        endif

        let g:codex_vim_last_turn_output = g:codex_vim_output

        call s:LogAppend(g:codex_vim_last_turn_output . "\n")

        let g:codex_vim_output = ''
        call s:Render()

        if g:codex_vim_diff_mode
            let g:codex_vim_diff_mode = 0

            try
                call s:OpenDiff()
            catch
                echoerr 'CodexDiff error: ' . v:exception
            endtry
        endif

    elseif l:method ==# 'error'
        call s:Append("\n[Codex: "
                    \ . get(l:params, 'message', 'unknown error') . "]")
    endif
endfunction


function! s:OnErr(channel, line) abort
    if !empty(a:line)
        call s:Append("\n[Codex stderr] " . a:line)
    endif
endfunction


" ---------------------------------------------------------------------------
" Start Codex App Server if necessary
" ---------------------------------------------------------------------------

function! s:EnsureServer() abort
    if type(g:codex_vim_job) == v:t_job
        if job_status(g:codex_vim_job) ==# 'run'
            return
        endif
    endif

    let g:codex_vim_thread = ''
    let g:codex_vim_pending = {}

    let g:codex_vim_job = job_start(
        \ ['codex', 'app-server', '--listen', 'stdio://'],
        \ {
        \   'in_io': 'pipe',
        \   'out_io': 'pipe',
        \   'err_io': 'pipe',
        \   'in_mode': 'raw',
        \   'out_mode': 'nl',
        \   'err_mode': 'nl',
        \   'out_cb': function('s:OnOut'),
        \   'err_cb': function('s:OnErr')
        \ })

    if job_status(g:codex_vim_job) !=# 'run'
        throw 'Could not start codex app-server'
    endif

    call s:Request('initialize', {
        \ 'clientInfo': {
        \   'name': 'vim-codex',
        \   'title': 'Vim Codex',
        \   'version': '0.1.0'
        \ }
        \ }, 'initialize')
endfunction


" ---------------------------------------------------------------------------
" Ask Codex
" ---------------------------------------------------------------------------

function! s:Ask(prompt, diff_mode, has_selection, first, last) abort
    if g:codex_vim_busy
        echoerr 'Codex is still working on the previous request'
        return
    endif

    if a:diff_mode && !a:has_selection
        echoerr 'CodexDiff requires a visual selection'
        return
    endif

    let l:source = expand('%:p')
    let l:source_buf = bufnr('%')
    let l:original = getline(1, '$')
    let l:code = ''

    if a:has_selection
        let l:code = join(getline(a:first, a:last), "\n")
    endif

    let l:prompt = a:prompt

    if empty(l:prompt)
        let l:prompt = input('Codex prompt: ')
    endif

    if empty(l:prompt)
        return
    endif

    let g:codex_vim_cwd = getcwd()
    let g:codex_vim_diff_mode = a:diff_mode

    if a:diff_mode
        let g:codex_vim_diff_source_buf = l:source_buf
        let g:codex_vim_diff_first = a:first
        let g:codex_vim_diff_last = a:last
        let g:codex_vim_diff_original = l:original

        let g:codex_vim_prompt =
                    \ l:prompt
                    \ . "\n\nModify only the selected code below."
                    \ . "\nReturn ONLY the complete replacement code."
                    \ . "\nDo not include Markdown fences or explanations."
                    \ . "\nPreserve the intended behavior unless asked otherwise."
                    \ . "\nFile: " . l:source
                    \ . "\nSelected code:\n" . l:code

    elseif a:has_selection
        let g:codex_vim_prompt =
                    \ l:prompt
                    \ . "\n\nFile: " . l:source
                    \ . "\nSelected code:\n```\n" . l:code . "\n```"

    else
        let g:codex_vim_prompt =
                    \ l:prompt
                    \ . "\n\nCurrent working directory: " . getcwd()

        if !empty(l:source)
            let g:codex_vim_prompt .= "\nCurrent file: " . l:source
        endif
    endif

    " Open or focus the shared conversation log.
    call s:ShowLog()

    " Add the question to the persistent log.
    let g:codex_vim_output = ''

    call s:LogAppend(
                \ "\n\n========== YOU ==========\n"
                \ . l:prompt
                \ . "\n\n========== CODEX ==========\n")

    let g:codex_vim_output = 'Starting Codex...'
    let g:codex_vim_busy = 1
    call s:Render()

    try
        call s:EnsureServer()

        if !empty(g:codex_vim_thread)
            call s:SendTurn()
        endif
    catch
        let g:codex_vim_busy = 0
        let g:codex_vim_diff_mode = 0

        call s:Append("\n[Codex startup error: " . v:exception . "]")
    endtry
endfunction


" ---------------------------------------------------------------------------
" Reply in the existing Codex conversation
" ---------------------------------------------------------------------------

function! s:Reply(prompt) abort
    if g:codex_vim_busy
        echoerr 'Codex is still working on the previous request'
        return
    endif

    if empty(g:codex_vim_thread)
        echoerr 'No Codex conversation yet. Start with :CodexAsk first.'
        return
    endif

    if type(g:codex_vim_job) != v:t_job
                \ || job_status(g:codex_vim_job) !=# 'run'
        echoerr 'Codex app-server is not running. Start a new :CodexAsk.'
        return
    endif

    let l:prompt = a:prompt

    if empty(l:prompt)
        let l:prompt = input('Reply to Codex: ')
    endif

    if empty(l:prompt)
        return
    endif

    let g:codex_vim_prompt = l:prompt
    let g:codex_vim_diff_mode = 0

    call s:ShowLog()

    let g:codex_vim_output = ''

    call s:LogAppend(
                \ "\n\n========== YOU ==========\n"
                \ . l:prompt
                \ . "\n\n========== CODEX ==========\n")

    let g:codex_vim_output = 'Starting Codex...'
    call s:Render()

    try
        call s:SendTurn()
    catch
        let g:codex_vim_busy = 0
        call s:Append("\n[Codex reply error: " . v:exception . "]")
    endtry
endfunction


" ---------------------------------------------------------------------------
" Commands and key mappings
" ---------------------------------------------------------------------------

" Normal mode: ask a general question, without automatically sending a line.
command! -nargs=* CodexAsk
            \ call <SID>Ask(<q-args>, 0, 0, 0, 0)

" Visual mode: ask a question about the selected lines.
command! -range -nargs=* CodexAskSelection
            \ call <SID>Ask(<q-args>, 0, 1, <line1>, <line2>)

" Visual mode: ask for a replacement and open a Vim diff.
command! -range -nargs=* CodexDiff
            \ call <SID>Ask(<q-args>, 1, 1, <line1>, <line2>)

" Show the shared Codex log.
command! CodexShow call <SID>ShowLog()

" Continue the current Codex conversation.
command! -nargs=* CodexReply call <SID>Reply(<q-args>)

" \ca works in both normal and visual mode, with different behavior.
nnoremap <silent> <leader>ca :CodexAsk<CR>
xnoremap <silent> <leader>ca :CodexAskSelection<CR>

" Diff mode requires a visual selection.
xnoremap <silent> <leader>cd :CodexDiff<CR>

" Show the shared conversation log.
nnoremap <silent> <leader>cs :CodexShow<CR>

" Reply to Codex.
nnoremap <silent> <leader>cr :CodexReply<CR>
