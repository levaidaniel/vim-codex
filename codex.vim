" Vim-Codex: Codex App Server integration for classic Vim.
" Requires Vim +job, +channel, JSON support, and the Codex CLI.

if !has('job') || !has('channel') || !exists('*json_encode')
    echoerr 'vim-codex requires Vim +job, +channel and JSON support'
    finish
endif

" ---------------------------------------------------------------------------
" State
" ---------------------------------------------------------------------------

let g:codex_vim_job = get(g:, 'codex_vim_job', v:null)
let g:codex_vim_thread = get(g:, 'codex_vim_thread', '')
let g:codex_vim_next_id = get(g:, 'codex_vim_next_id', 1)
let g:codex_vim_pending = get(g:, 'codex_vim_pending', {})
let g:codex_vim_busy = 0
let g:codex_vim_prompt = ''
let g:codex_vim_cwd = get(g:, 'codex_vim_cwd', '')

let g:codex_vim_log_buf = get(g:, 'codex_vim_log_buf', -1)
let g:codex_vim_log = get(g:, 'codex_vim_log', '')
let g:codex_vim_output = ''
let g:codex_vim_response_stream = ''
let g:codex_vim_last_turn_output = ''

" Source snapshot retained until the response has been classified.
let g:codex_vim_source_buf =
            \ get(g:, 'codex_vim_source_buf', -1)
let g:codex_vim_source_path =
            \ get(g:, 'codex_vim_source_path', '')
let g:codex_vim_source_lines =
            \ get(g:, 'codex_vim_source_lines', [])
let g:codex_vim_source_first =
            \ get(g:, 'codex_vim_source_first', 1)
let g:codex_vim_source_last =
            \ get(g:, 'codex_vim_source_last', 1)
let g:codex_vim_source_selection =
            \ get(g:, 'codex_vim_source_selection', 0)


" ---------------------------------------------------------------------------
" Log handling
" ---------------------------------------------------------------------------

function! s:EnsureLog() abort
    if g:codex_vim_log_buf > 0
                \ && bufexists(g:codex_vim_log_buf)
        return
    endif

    let l:buf = bufnr('Codex-Log')

    if l:buf > 0
        let g:codex_vim_log_buf = l:buf
        let g:codex_vim_log =
                    \ join(getbufline(l:buf, 1, '$'), "\n")
                    \ . "\n"
        return
    endif

    let l:current_win = win_getid()

    botright 8new
    silent file Codex-Log

    let g:codex_vim_log_buf = bufnr('%')

    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal nowrap
    setlocal filetype=markdown

    if win_id2win(l:current_win) > 0
        call win_gotoid(l:current_win)
    endif
endfunction


function! s:Render() abort
    call s:EnsureLog()

    let l:buf = g:codex_vim_log_buf
    let l:text = g:codex_vim_log . g:codex_vim_output
    let l:lines = split(l:text, "\n", 1)

    if empty(l:lines)
        let l:lines = ['']
    endif

    call setbufline(l:buf, 1, l:lines)

    let l:old_count = len(getbufline(l:buf, 1, '$'))

    if l:old_count > len(l:lines)
        call deletebufline(
                    \ l:buf,
                    \ len(l:lines) + 1,
                    \ l:old_count)
    endif

    " Follow output if the log is visible, without changing focus.
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


function! s:Append(text) abort
    let g:codex_vim_output .= a:text
    call s:Render()
endfunction


function! s:ShowLog() abort
    call s:EnsureLog()

    let l:winnr = bufwinnr(g:codex_vim_log_buf)

    if l:winnr > 0
        execute l:winnr . 'wincmd w'
        return
    endif

    botright 8split
    execute 'buffer ' . g:codex_vim_log_buf
    setlocal nowrap
endfunction


" ---------------------------------------------------------------------------
" JSON-RPC
" ---------------------------------------------------------------------------

function! s:SendRaw(message) abort
    if type(g:codex_vim_job) != v:t_job
        throw 'Codex process is not running'
    endif

    let l:json = json_encode(a:message)

    " Log the exact outgoing turn/start request for debugging.
    "if get(a:message, 'method', '') ==# 'turn/start'
    "    call writefile([
    "                \ '',
    "                \ '========== OUTGOING turn/start ==========',
    "                \ l:json
    "                \ ],
    "                \ expand('~/.vim/plugin/codex/codex-vim-outgoing.log'),
    "                \ 'a')
    "endif

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
    if empty(g:codex_vim_thread)
        throw 'No Codex conversation thread is available'
    endif

    if empty(g:codex_vim_prompt)
        throw 'Codex hiba: a teljes kérés hiányzik'
    endif

    if stridx(g:codex_vim_prompt, 'USER REQUEST:') < 0
                \ || stridx(g:codex_vim_prompt,
                \ 'CURRENT FILE CONTENTS:') < 0
        throw 'Codex hiba: a kérésből hiányzik a felhasználói utasítás vagy a fájltartalom'
    endif

    let g:codex_vim_busy = 1
    let g:codex_vim_response_stream = ''
    let g:codex_vim_output = 'Codex dolgozik...'

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
" Response parsing
" ---------------------------------------------------------------------------


function! s:ExtractJsonObject(text) abort
    let l:start = -1
    let l:depth = 0
    let l:in_string = 0
    let l:escaped = 0

    let l:i = 0
    while l:i < strlen(a:text)
        let l:char = strpart(a:text, l:i, 1)

        if l:start < 0
            if l:char ==# '{'
                let l:start = l:i
                let l:depth = 1
            endif
        elseif l:in_string
            if l:escaped
                let l:escaped = 0
            elseif l:char ==# '\'
                let l:escaped = 1
            elseif l:char ==# '"'
                let l:in_string = 0
            endif
        else
            if l:char ==# '"'
                let l:in_string = 1
            elseif l:char ==# '{'
                let l:depth += 1
            elseif l:char ==# '}'
                let l:depth -= 1

                if l:depth == 0
                    return strpart(
                                \ a:text,
                                \ l:start,
                                \ l:i - l:start + 1)
                endif
            endif
        endif

        let l:i += 1
    endwhile

    return ''
endfunction


function! s:HandleResponse(text) abort
    let g:codex_vim_last_turn_output = a:text
    let g:codex_vim_output = ''

    " Parse the model response as a JSON object.
    let l:json = s:ExtractJsonObject(a:text)

    if empty(l:json)
        call s:LogAppend(
                    \ "[Hiba: a Codex válaszában nem található JSON-objektum.]\n"
                    \ . a:text . "\n")
        return
    endif

    try
        let l:response = json_decode(l:json)
    catch
        call s:LogAppend(
                    \ "[Hiba: a Codex válasza nem érvényes JSON.]\n"
                    \ . a:text . "\n")
        return
    endtry

    if type(l:response) != v:t_dict
        call s:LogAppend(
                    \ "[Hiba: a Codex válasza nem JSON-objektum.]\n"
                    \ . a:text . "\n")
        return
    endif

    let l:mode = get(l:response, 'mode', '')
    let l:explanation = get(l:response, 'explanation', '')
    let l:code = get(l:response, 'code', v:null)

    if type(l:explanation) != v:t_string
        let l:explanation = ''
    endif

    if l:mode ==# 'diff'
        if type(l:code) != v:t_string
            call s:LogAppend(
                        \ "[Hiba: a diff válaszból hiányzik "
                        \ . "az érvényes code mező.]\n"
                        \ . a:text . "\n")
            return
        endif

        call s:LogAppend(l:explanation . "\n")

        try
            call s:OpenDiff(l:code)
        catch
            call s:LogAppend(
                        \ "\n[CodexDiff hiba: "
                        \ . v:exception . "]\n")
        endtry

        return
    endif

    if l:mode ==# 'answer'
        call s:LogAppend(l:explanation . "\n")
        return
    endif

    call s:LogAppend(
                \ "[Hiba: ismeretlen válaszmód: "
                \ . string(l:mode) . "]\n"
                \ . a:text . "\n")
endfunction


" ---------------------------------------------------------------------------
" Diff view
" ---------------------------------------------------------------------------

function! s:OpenDiff(code) abort
    let l:source_buf = g:codex_vim_source_buf

    if l:source_buf <= 0 || !bufexists(l:source_buf)
        throw 'Original source buffer no longer exists'
    endif

    let l:text = substitute(a:code, '^\n\+', '', '')
    let l:text = substitute(l:text, '\n\+$', '', '')

    let l:replacement = split(l:text, "\n", 1)

    " Remove optional Markdown fences.
    if !empty(l:replacement)
                \ && l:replacement[0] =~# '^\s*```'
        call remove(l:replacement, 0)

        if !empty(l:replacement)
                    \ && l:replacement[-1] =~# '^\s*```'
            call remove(l:replacement, -1)
        endif
    endif

    if empty(l:replacement)
        let l:replacement = ['']
    endif

    " Build the proposed full file.
    let l:original = g:codex_vim_source_lines
    let l:proposal = []

    if g:codex_vim_source_first > 1
        let l:proposal = l:original[
                    \ 0 : g:codex_vim_source_first - 2]
    endif

    let l:proposal += l:replacement

    if g:codex_vim_source_last < len(l:original)
        let l:proposal += l:original[
                    \ g:codex_vim_source_last :]
    endif

    let l:log_buf = g:codex_vim_log_buf

    " New tab: original and proposal above, shared log below.
    tabnew
    execute 'buffer ' . l:source_buf

    belowright 8split

    if l:log_buf > 0 && bufexists(l:log_buf)
        execute 'buffer ' . l:log_buf
    else
        silent file Codex-Log
        let g:codex_vim_log_buf = bufnr('%')

        setlocal buftype=nofile
        setlocal bufhidden=hide
        setlocal noswapfile
        setlocal nowrap
    endif

    wincmd k

    call cursor(g:codex_vim_source_first, 1)

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

    echo 'Codex: diffjavaslat megnyitva; az eredeti fájl változatlan.'
endfunction


" ---------------------------------------------------------------------------
" Codex App Server output callbacks
" ---------------------------------------------------------------------------

function! s:OnOut(channel, line) abort
    if empty(a:line)
        return
    endif

    " Log incoming messages separately from JSON parsing.
    "try
    "    call writefile(
    "                \ [a:line],
    "                \ expand('~/.vim/plugin/codex/codex-vim-incoming.log'),
    "                \ 'a')
    "catch
    "    " Logging failure must not prevent message processing.
    "endtry

    " Parse the incoming JSON message.
    try
        let l:msg = json_decode(a:line)
    catch
        call s:Append(
                    \ "\n[Codex: invalid JSON response: "
                    \ . v:exception . "]")
        return
    endtry

    " Handle server-initiated file-change approval requests first.
    if get(l:msg, 'method', '') ==# 'item/fileChange/requestApproval'
        let l:params = get(l:msg, 'params', {})
        let l:reason = get(l:params, 'reason', '')
        let l:question = 'Codex fájlmódosítást szeretne végrehajtani.'

        if type(l:reason) == v:t_string && !empty(l:reason)
            let l:question .= "\nIndok: " . l:reason
        endif

        let l:choice = confirm(
                    \ l:question,
                    \ "&Engedélyezem\n&Elutasítom\n&Megszakítom",
                    \ 2)
        let l:decision = l:choice == 1
                    \ ? 'accept'
                    \ : (l:choice == 2 ? 'decline' : 'cancel')

        call ch_sendraw(
                    \ job_getchannel(g:codex_vim_job),
                    \ json_encode({
                    \   'id': l:msg.id,
                    \   'result': {'decision': l:decision}
                    \ }) . "\n")
        return
    endif

    " JSON-RPC responses.
    if has_key(l:msg, 'id')
        let l:key = string(l:msg.id)
        let l:kind = get(g:codex_vim_pending, l:key, '')

        if has_key(g:codex_vim_pending, l:key)
            call remove(g:codex_vim_pending, l:key)
        endif

        if has_key(l:msg, 'error')
            let l:err = get(
                        \ l:msg.error,
                        \ 'message',
                        string(l:msg.error))

            let g:codex_vim_busy = 0
            let g:codex_vim_output = ''

            call s:LogAppend(
                        \ "\n[Codex hiba: " . l:err . "]\n")
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
                let g:codex_vim_busy = 0
                let g:codex_vim_output = ''

                call s:LogAppend(
                            \ "\n[Codex hiba: thread ID hiányzik]\n")
                return
            endif

            call s:SendTurn()
        endif

        return
    endif

    let l:method = get(l:msg, 'method', '')
    let l:normalized = substitute(
                \ tolower(l:method),
                \ '_',
                \ '',
                \ 'g')
    let l:params = get(l:msg, 'params', {})

    " Accumulate the entire response without rendering code into the chat.
    if stridx(l:normalized, 'agentmessage') >= 0
                \ && stridx(l:normalized, 'delta') >= 0

        let l:delta = get(l:params, 'delta', '')

        if type(l:delta) == v:t_string && !empty(l:delta)
            let g:codex_vim_response_stream .= l:delta
        endif

    elseif l:method ==# 'turn/completed'
        let g:codex_vim_busy = 0

        " Prefer the complete final response from turn/completed.
        let l:response = s:ExtractFinalText(l:params)

        " Fall back to the accumulated stream only if necessary.
        if empty(l:response)
            let l:response = g:codex_vim_response_stream
        endif

        let g:codex_vim_response_stream = ''
        let g:codex_vim_output = ''

        if empty(l:response)
            call s:LogAppend(
                        \ "[A Codex-turn befejeződött, "
                        \ . "de nem érkezett szöveges válasz.]\n")
            return
        endif

        call s:HandleResponse(l:response)

    elseif l:method ==# 'error'
        let g:codex_vim_busy = 0
        let g:codex_vim_output = ''

        call s:LogAppend(
                    \ "\n[Codex hiba: "
                    \ . get(l:params, 'message', 'unknown error')
                    \ . "]\n")
    endif
endfunction


function! s:OnErr(channel, line) abort
    if !empty(a:line)
        call s:LogAppend("\n[Codex stderr] " . a:line . "\n")
    endif
endfunction


" ---------------------------------------------------------------------------
" Server lifecycle
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
" Prompt editor
" ---------------------------------------------------------------------------

let g:codex_vim_prompt_context = {}


function! s:OpenPrompt(prompt, has_selection, first, last) abort
    if g:codex_vim_busy
        echoerr 'Codex is still working on the previous request'
        return
    endif

    let l:from_log = bufnr('%') == g:codex_vim_log_buf

    if l:from_log
        if g:codex_vim_source_buf <= 0
                    \ || !bufexists(g:codex_vim_source_buf)
                    \ || g:codex_vim_source_buf
                    \ == g:codex_vim_log_buf
                    \ || empty(g:codex_vim_source_path)
            echoerr 'Nincs érvényes forrásfájl-kontextus.'
            return
        endif

        let l:source_buf = g:codex_vim_source_buf
        let l:source_lines = copy(g:codex_vim_source_lines)
        let l:source_path = g:codex_vim_source_path
        let l:cwd = g:codex_vim_cwd
        let l:has_selection = g:codex_vim_source_selection
        let l:first = g:codex_vim_source_first
        let l:last = g:codex_vim_source_last
        let l:source_winid = get(g:, 'codex_vim_source_winid', -1)
    else
        let l:source_buf = bufnr('%')
        let l:source_lines = getline(1, '$')
        let l:source_path = expand('%:p')
        let l:cwd = getcwd()
        let l:has_selection = a:has_selection
        let l:first = a:has_selection ? a:first : 1
        let l:last = a:has_selection ? a:last : len(l:source_lines)
        let l:source_winid = win_getid()
    endif

    let g:codex_vim_prompt_context = {
                \ 'winid': win_getid(),
                \ 'source_winid': l:source_winid,
                \ 'from_log': l:from_log,
                \ 'source_buf': l:source_buf,
                \ 'source_lines': l:source_lines,
                \ 'source_path': l:source_path,
                \ 'cwd': l:cwd,
                \ 'has_selection': l:has_selection,
                \ 'first': l:first,
                \ 'last': l:last
                \ }

    if l:from_log
        " Reuse the chat window instead of creating another split.
        resize 8
        silent enew
    else
        botright 8new
    endif

    silent file Codex-Prompt

    setlocal buftype=nofile
    setlocal bufhidden=wipe
    setlocal noswapfile
    setlocal filetype=markdown
    setlocal wrap

    let l:lines = split(a:prompt, "\n", 1)

    if empty(l:lines)
        let l:lines = ['']
    endif

    call setline(1, l:lines)
    normal! G$
    startinsert!

    command! -buffer CodexSend call <SID>SubmitPrompt()
    nnoremap <buffer> <leader>s :call <SID>SubmitPrompt()<CR>
    inoremap <buffer> <leader>s <Esc>:call <SID>SubmitPrompt()<CR>

    echo 'Vim-Codex: \s = send prompt | :CodexSend'
endfunction


function! s:SubmitPrompt() abort
    if empty(g:codex_vim_prompt_context)
        echoerr 'No active Codex prompt'
        return
    endif

    let l:prompt = join(getline(1, '$'), "\n")

    if empty(substitute(l:prompt, '\_s', '', 'g'))
        echoerr 'The Codex prompt is empty'
        return
    endif

    let l:ctx = copy(g:codex_vim_prompt_context)
    let g:codex_vim_prompt_context = {}

    if get(l:ctx, 'from_log', 0)
        " Restore the chat buffer in the same window.
        execute 'buffer ' . g:codex_vim_log_buf
    else
        close

        if !win_gotoid(l:ctx.winid)
            echoerr 'Could not return to the original Vim window'
            return
        endif
    endif

    call s:StartRequest(l:prompt, l:ctx)
endfunction


" ---------------------------------------------------------------------------
" Unified request entry point
" ---------------------------------------------------------------------------

function! s:StartRequest(prompt, ctx) abort
    if g:codex_vim_busy
        echoerr 'Codex is still working on the previous request'
        return
    endif

    let g:codex_vim_source_winid = get(a:ctx, 'source_winid', a:ctx.winid)
    let g:codex_vim_source_buf = a:ctx.source_buf
    let g:codex_vim_source_path = a:ctx.source_path
    let g:codex_vim_source_lines = copy(a:ctx.source_lines)
    let g:codex_vim_source_first = a:ctx.first
    let g:codex_vim_source_last = a:ctx.last
    let g:codex_vim_source_selection = a:ctx.has_selection
    let g:codex_vim_cwd = a:ctx.cwd

    let l:source = g:codex_vim_source_path
    let l:original = g:codex_vim_source_lines
    let l:code = join(l:original, "\n")
    let l:selected = join(
                \ l:original[
                \ g:codex_vim_source_first - 1 :
                \ g:codex_vim_source_last - 1],
                \ "\n")

    " Always provide enough source context for automatic diff classification.
    " A diff response must replace the selected region or the complete file.
    let g:codex_vim_prompt =
                \ "You are responding through a classic Vim plugin.\n"
                \ . "Return exactly one valid JSON object. Do not use "
                \ . "Markdown fences or add text outside the JSON.\n"
                \ . "Use this schema:\n"
                \ . "{\"mode\":\"answer\","
                \ . "\"explanation\":\"Your answer\","
                \ . "\"code\":null}\n"
                \ . "Use \"mode\":\"diff\" whenever the user asks to modify, "
                \ . "fix, improve, refactor, clean up, or correct the current "
                \ . "file, including fixing issues identified in a code review. "
                \ . "Also use diff mode when the user asks for the modified code, "
                \ . "a patch, or a diff for previously discussed changes. "
                \ . "Put the complete replacement text in the string field "
                \ . "\"code\".\n"
                \ . "Use \"mode\":\"answer\" only for questions, explanations, "
                \ . "or illustrative code examples that do not request changes "
                \ . "to the current file. In answer mode, set \"code\" to null.\n"
                \ . "Always include all three fields: mode, "
                \ . "explanation and code.\n"
                \ . "For diff, code must replace only the selected "
                \ . "region if a selection exists; otherwise it must "
                \ . "contain the complete file.\n\n"
                \ . "USER REQUEST:\n"
                \ . a:prompt
                \ . "\n\nWORKING DIRECTORY:\n"
                \ . g:codex_vim_cwd
                \ . "\n\nCURRENT FILE:\n"
                \ . (empty(l:source) ? '[No file name]' : l:source)
                \ . "\n\nCURRENT FILE CONTENTS:\n"
                \ . "```text\n" . l:code . "\n```\n"

    if g:codex_vim_source_selection
        let g:codex_vim_prompt .=
                    \ "\nThe user has selected lines "
                    \ . g:codex_vim_source_first . " through "
                    \ . g:codex_vim_source_last . ".\n"
                    \ . "If you choose MODE diff, CODE must replace "
                    \ . "only this selection.\n"
                    \ . "SELECTED REGION:\n```text\n"
                    \ . l:selected . "\n```\n"
    else
        let g:codex_vim_prompt .=
                    \ "\nNo visual selection was supplied. If you choose "
                    \ . "MODE diff, CODE must contain the complete "
                    \ . "replacement file.\n"
    endif

    call s:ShowLog()

    let g:codex_vim_output = ''
    let g:codex_vim_response_stream = ''

    call s:LogAppend(
                \ "\n\n========== YOU ==========\n"
                \ . a:prompt
                \ . "\n\n========== CODEX ==========\n")

    let g:codex_vim_output = 'Codex indul...'
    let g:codex_vim_busy = 1
    call s:Render()

    try
        call s:EnsureServer()

        if !empty(g:codex_vim_thread)
            call s:SendTurn()
        endif
    catch
        let g:codex_vim_busy = 0
        let g:codex_vim_output = ''

        call s:LogAppend(
                    \ "\n[Codex indítási hiba: "
                    \ . v:exception . "]\n")
    endtry
endfunction


" ---------------------------------------------------------------------------
" Commands and mappings
" ---------------------------------------------------------------------------

" One unified command for both questions and change requests.
command! -nargs=* Codex
            \ call <SID>OpenPrompt(<q-args>, 0, 1, 1)

" Visual selection: used as context and as the replacement region for diffs.
command! -range -nargs=* CodexSelection
            \ call <SID>OpenPrompt(<q-args>, 1, <line1>, <line2>)

command! CodexShow call <SID>ShowLog()

nnoremap <silent> <leader>ca :Codex<CR>
xnoremap <silent> <leader>ca :CodexSelection<CR>

" Keep the old continuation key as an alias to the unified request.
nnoremap <silent> <leader>cr :Codex<CR>

nnoremap <silent> <leader>cs :CodexShow<CR>
