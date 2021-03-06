if get(g:,"LanguageClient_loaded", 0)
    finish
endif

function! s:Echoerr(message) abort
    echohl Error | echomsg a:message | echohl None
endfunction

function! s:Debug(message) abort
    if !exists('g:LanguageClient_loggingLevel')
        return
    endif

    if g:LanguageClient_loggingLevel ==? 'INFO' || g:LanguageClient_loggingLevel ==? 'DEBUG'
        call s:Echoerr(a:message)
    endif
endfunction

function! s:hasSnippetSupport() abort
    " https://github.com/SirVer/ultisnips
    if exists('g:did_plugin_ultisnips')
        return 1
    endif
    " https://github.com/Shougo/neosnippet.vim
    if exists('g:loaded_neosnippet')
        return 1
    endif
    " https://github.com/garbas/vim-snipmate
    if exists('loaded_snips')
        return 1
    endif

    return 0
endfunction

" When editing a [No Name] file, neovim reports filename as "", while vim reports null.
function! s:Expand(exp) abort
    let l:result = expand(a:exp)
    return l:result ==# '' ? '' : l:result
endfunction

function! s:Text() abort
    return getbufline('', 1, '$') + (&fixendofline ? [''] : [])
endfunction

" Get all listed buffer file names.
function! s:Bufnames() abort
    return map(filter(range(0,bufnr('$')), 'buflisted(v:val)'), 'fnamemodify(bufname(v:val), '':p'')')
endfunction

function! s:getInput(prompt, default) abort
    call inputsave()
    let l:input = input(a:prompt, a:default)
    call inputrestore()
    return l:input
endfunction

function! s:FZF(source, sink) abort
    let l:options = get(g:, 'LanguageClient_fzfOptions', v:null)
    if l:options == v:null
        let l:options = fzf#vim#with_preview('right:50%:hidden', '?').options
    endif
    call fzf#run(fzf#wrap({
                \ 'source': a:source,
                \ 'sink': function(a:sink),
                \ 'options': l:options,
                \ }))
    if has('nvim')
        call feedkeys('i')
    endif
endfunction

let s:id = 1
let s:handlers = {}

" Note: vim execute callback for every line.
let s:content_length = 0
let s:input = ''
function! s:HandleMessage(job, lines, event) abort
    if a:event ==# 'stdout'
        while len(a:lines) > 0
            let l:line = remove(a:lines, 0)

            if l:line ==# ''
                continue
            elseif s:content_length == 0
                let s:content_length = str2nr(substitute(l:line, '.*Content-Length:', '', ''))
                continue
            endif

            let s:input .= strpart(l:line, 0, s:content_length)
            if s:content_length < strlen(l:line)
                call insert(a:lines, strpart(l:line, s:content_length), 0)
                let s:content_length = 0
            else
                let s:content_length = s:content_length - strlen(l:line)
            endif
            if s:content_length > 0
                continue
            endif

            try
                let l:message = json_decode(s:input)
                let s:input = ''
            catch
                let s:input = ''
                call s:Debug(string(v:exception))
                continue
            endtry

            if has_key(l:message, 'method')
                let l:id = get(l:message, 'id', v:null)
                let l:method = get(l:message, 'method')
                let l:params = get(l:message, 'params')
                try
                    if l:method ==# 'execute'
                        for l:cmd in l:params
                            execute l:cmd
                        endfor
                    else
                        let l:params = type(l:params) == type([]) ? l:params : [l:params]
                        let l:result = call(l:method, l:params)
                    endif
                    if l:id != v:null
                        call LanguageClient#Write(json_encode({
                                    \ 'jsonrpc': '2.0',
                                    \ 'id': l:id,
                                    \ 'result': l:result,
                                    \ }))
                    endif
                catch
                    if l:id != v:null
                        call LanguageClient#Write(json_encode({
                                    \ 'jsonrpc': '2.0',
                                    \ 'id': l:id,
                                    \ 'error': {
                                    \   'code': -32603,
                                    \   'message': string(v:exception)
                                    \   }
                                    \ }))
                    endif
                    call s:Debug(string(v:exception))
                endtry
            elseif has_key(l:message, 'result') || has_key(l:message, 'error')
                let l:id = get(l:message, 'id')
                " Function name needs to begin with uppercase letter.
                let l:Handle = get(s:handlers, l:id)
                unlet s:handlers[l:id]
                if type(l:Handle) == type(function('tr')) ||
                            \ (type(l:Handle) == type('') && exists('*' . l:Handle))
                    call call(l:Handle, [l:message])
                elseif type(l:Handle) == type([])
                    call add(l:Handle, l:message)
                elseif type(l:Handle) == type('') && exists(l:Handle)
                    let l:outputs = eval(l:Handle)
                    call add(l:outputs, l:message)
                else
                    call s:Echoerr('Unknown Handle type: ' . string(l:Handle))
                endif
            else
                call s:Echoerr('Unknown message: ' . string(l:message))
            endif
        endwhile
    elseif a:event ==# 'stderr'
        call s:Echoerr('LanguageClient stderr: ' . string(a:lines))
    elseif a:event ==# 'exit'
        if type(a:lines) == type(0) && a:lines == 0
            return
        endif
        call s:Echoerr('LanguageClient exited with: ' . string(a:lines))
    else
        call s:Debug('LanguageClient unknown event: ' . a:event)
    endif
endfunction

function! s:HandleStdoutVim(job, data) abort
    return s:HandleMessage(a:job, [a:data], 'stdout')
endfunction

function! s:HandleStderrVim(job, data) abort
    return s:HandleMessage(a:job, [a:data], 'stderr')
endfunction

function! s:HandleExitVim(job, data) abort
    return s:HandleMessage(a:job, [a:data], 'exit')
endfunction

function! s:HandleOutput(output) abort
    if has_key(a:output, 'result')
        " let l:result = string(a:result)
        " if l:result !=# 'v:null'
            " echomsg l:result
        " endif
        return get(a:output, 'result')
    elseif has_key(a:output, 'error')
        let l:error = get(a:output, 'error')
        let l:message = get(l:error, 'message')
        call s:Echoerr(l:message)
        return v:null
    else
        call s:Echoerr('Unknown output type: ' . json_encode(a:output))
        return v:null
    endif
endfunction

let s:root = expand('<sfile>:p:h:h')
function! s:Launch() abort
    if exists('g:LanguageClient_devel')
        if exists('$CARGO_TARGET_DIR')
            let l:command = [$CARGO_TARGET_DIR . '/debug/languageclient']
        else
            let l:command = [s:root . '/target/debug/languageclient']
        endif
    else
        let l:command = [s:root . '/bin/languageclient']
    endif

    if has('nvim')
        let s:job = jobstart(l:command, {
                    \ 'on_stdout': function('s:HandleMessage'),
                    \ 'on_stderr': function('s:HandleMessage'),
                    \ 'on_exit': function('s:HandleMessage'),
                    \ })
        if s:job == 0
            call s:Echoerr('LanguageClient: Invalid arguments!')
            return 0
        elseif s:job == -1
            call s:Echoerr('LanguageClient: Not executable!')
            return 0
        else
            return 1
        endif
    elseif has('job')
        let s:job = job_start(l:command, {
                    \ 'out_cb': function('s:HandleStdoutVim'),
                    \ 'err_cb': function('s:HandleStderrVim'),
                    \ 'exit_cb': function('s:HandleExitVim'),
                    \ })
        if job_status(s:job) !=# 'run'
            call s:Echoerr('LanguageClient: job failed to start or died!')
            return 0
        else
            return 1
        endif
    else
        echoerr 'Not supported: not nvim nor vim with +job.'
        return 0
    endif
endfunction

function! LanguageClient#Write(message) abort
    let l:message = a:message . "\n"
    if has('nvim')
        return jobsend(s:job, l:message)
    elseif has('channel')
        return ch_sendraw(s:job, l:message)
    else
        echoerr 'Not supported: not nvim nor vim with +channel.'
    endif
endfunction

function! LanguageClient#Call(method, params, callback, ...) abort
    let l:id = s:id
    let s:id = s:id + 1
    if a:callback is v:null
        let s:handlers[l:id] = function('s:HandleOutput')
    else
        let s:handlers[l:id] = a:callback
    endif
    let l:skipAddParams = a:0 > 0 && a:1
    let l:params = a:params
    if type(a:params) == type({}) && !skipAddParams
        let l:params = extend({
                    \ 'buftype': &buftype,
                    \ 'languageId': &filetype,
                    \ }, l:params)
    endif
    return LanguageClient#Write(json_encode({
                \ 'jsonrpc': '2.0',
                \ 'id': l:id,
                \ 'method': a:method,
                \ 'params': l:params,
                \ }))
endfunction

function! LanguageClient#Notify(method, params) abort
    let l:params = a:params
    if type(params) == type({})
        let l:params = extend({
                    \ 'buftype': &buftype,
                    \ 'languageId': &filetype,
                    \ }, l:params)
    endif
    return LanguageClient#Write(json_encode({
                \ 'jsonrpc': '2.0',
                \ 'method': a:method,
                \ 'params': l:params,
                \ }))
endfunction

function! LanguageClient#textDocument_hover(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/hover', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_definition(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'gotoCmd': v:null,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/definition', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_rename(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'cword': expand('<cword>'),
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/rename', l:params, v:null)
endfunction

let g:LanguageClient_documentSymbolResults = []
function! LanguageClient#textDocument_documentSymbol(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : g:LanguageClient_documentSymbolResults
    return LanguageClient#Call('textDocument/documentSymbol', l:params, l:callback)
endfunction

let g:LanguageClient_workspaceSymbolResults = []
function! LanguageClient#workspace_symbol(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'query': '',
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : g:LanguageClient_workspaceSymbolResults
    return LanguageClient#Call('workspace/symbol', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_codeAction(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/codeAction', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_completion(...) abort
    " Note: do not add 'text' as it might be huge.
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:false,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/completion', l:params, l:callback)
endfunction

let g:LanguageClient_referencesResults = []
function! LanguageClient#textDocument_references(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'includeDeclaration': v:true,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : g:LanguageClient_referencesResults
    return LanguageClient#Call('textDocument/references', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_formatting(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/formatting', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_rangeFormatting(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/rangeFormatting', l:params, l:callback)
endfunction

function! LanguageClient#rustDocument_implementations(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('rustDocument/implementations', l:params, l:callback)
endfunction

function! LanguageClient#textDocument_didOpen() abort
    return LanguageClient#Notify('textDocument/didOpen', {
                \ 'filename': s:Expand('%:p'),
                \ 'text': s:Text(),
                \ })
endfunction

function! LanguageClient#textDocument_didChange() abort
    " Note: do not add 'text' as it might be huge.
    return LanguageClient#Notify('textDocument/didChange', {
                \ 'filename': s:Expand('%:p'),
                \ })
endfunction

function! LanguageClient#textDocument_didSave() abort
    return LanguageClient#Notify('textDocument/didSave', {
                \ 'filename': s:Expand('%:p'),
                \ })
endfunction

function! LanguageClient#textDocument_didClose() abort
    return LanguageClient#Notify('textDocument/didClose', {
                \ 'filename': s:Expand('%:p'),
                \ })
endfunction

function! LanguageClient#getState(callback) abort
    return LanguageClient#Call('languageClient/getState', {}, a:callback)
endfunction

function! LanguageClient#alive(callback) abort
    return LanguageClient#Call('languageClient/isAlive', {}, a:callback)
endfunction

function! LanguageClient#startServer(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'cmdargs': [],
                \ }
    call extend(l:params, a:0 > 0 ? {'cmdargs': a:000} : {})
    return LanguageClient#Call('languageClient/startServer', l:params, v:null)
endfunction

function! LanguageClient#registerServerCommands(cmds, ...) abort
    let l:handle = a:0 > 0 ? a:1 : v:null
    return LanguageClient#Call('languageClient/registerServerCommands', a:cmds, l:handle, v:true)
endfunction

function! LanguageClient#setLoggingLevel(level) abort
    let l:params = {
                \ 'loggingLevel': a:level,
                \ }
    return LanguageClient#Call('languageClient/setLoggingLevel', l:params, v:null)
endfunction

function! LanguageClient#registerHandlers(handlers, ...) abort
    let l:handle = a:0 > 0 ? a:1 : v:null
    return LanguageClient#Call('languageClient/registerHandlers', a:handlers, l:handle)
endfunction

function! LanguageClient_runSync(fn, params) abort
    let s:LanguageClient_runSync_outputs = []
    call call(a:fn, [a:params, s:LanguageClient_runSync_outputs])
    while len(s:LanguageClient_runSync_outputs) == 0
        sleep 100m
    endwhile
    let l:output = remove(s:LanguageClient_runSync_outputs, 0)
    return s:HandleOutput(l:output)
endfunction

function! LanguageClient#handleBufReadPost() abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    try
        call LanguageClient#Notify('languageClient/handleBufReadPost', {
                    \ 'filename': s:Expand('%:p'),
                    \ })
    catch
        call s:Debug('LanguageClient caught exception: ' . string(v:exception))
    endtry
endfunction

function! LanguageClient#handleTextChanged() abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    try
        " Note: do not add 'text' as it might be huge.
        call LanguageClient#Notify('languageClient/handleTextChanged', {
                    \ 'filename': s:Expand('%:p'),
                    \ })
    catch
        call s:Debug('LanguageClient caught exception: ' . string(v:exception))
    endtry
endfunction

function! LanguageClient#handleBufWritePost() abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    try
        call LanguageClient#Notify('languageClient/handleBufWritePost', {
                    \ 'filename': s:Expand('%:p'),
                    \ })
    catch
        call s:Debug('LanguageClient caught exception: ' . string(v:exception))
    endtry
endfunction

function! LanguageClient#handleBufDelete() abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    try
        call LanguageClient#Notify('languageClient/handleBufDelete', {
                    \ 'filename': s:Expand('%:p'),
                    \ })
    catch
        call s:Debug('LanguageClient caught exception: ' . string(v:exception))
    endtry
endfunction

let s:last_cursor_line = -1
function! LanguageClient#handleCursorMoved() abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    let l:cursor_line = line('.')
    if l:cursor_line == s:last_cursor_line
        return
    endif
    let s:last_cursor_line = l:cursor_line

    try
        call LanguageClient#Notify('languageClient/handleCursorMoved', {
                    \ 'filename': s:Expand('%:p'),
                    \ 'line': line('.') - 1,
                    \ })
    catch
        call s:Debug('LanguageClient caught exception: ' . string(v:exception))
    endtry
endfunction

function! s:LanguageClient_FZFSinkLocation(line) abort
    return LanguageClient#Notify('LanguageClient_FZFSinkLocation', [a:line])
endfunction

function! s:LanguageClient_FZFSinkCommand(selection) abort
    return LanguageClient#Notify('LanguageClient_FZFSinkCommand', {
                \ 'selection': a:selection,
                \ })
endfunction

function! LanguageClient#NCMRefresh(info, context) abort
    return LanguageClient#Notify('LanguageClient_NCMRefresh', {
                \ 'info': a:info,
                \ 'ctx': a:context,
                \ })
endfunction

let g:LanguageClient_omniCompleteResults = []
function! LanguageClient#omniComplete(...) abort
    try
        " Note: do not add 'text' as it might be huge.
        let l:params = {
                    \ 'filename': s:Expand('%:p'),
                    \ 'line': line('.') - 1,
                    \ 'character': col('.') - 1,
                    \ 'handle': v:false,
                    \ }
        call extend(l:params, a:0 >= 1 ? a:1 : {})
        let l:callback = a:0 >= 2 ? a:2 : g:LanguageClient_omniCompleteResults
        call LanguageClient#Call('languageClient/omniComplete', l:params, l:callback)
    catch
        call add(a:0 >= 2 ? a:2 : g:LanguageClient_omniCompleteResults, [])
        call s:Debug(string(v:exception))
    endtry
endfunction

let g:LanguageClient_completeResults = []
function! LanguageClient#complete(findstart, base) abort
    if a:findstart
        let l:line = getline('.')
        let l:start = col('.') - 1
        while l:start > 0 && l:line[l:start - 1] =~# '\w'
            let l:start -= 1
        endwhile
        return l:start
    else
        let l:result = LanguageClient_runSync(
                    \ 'LanguageClient#omniComplete', {
                    \ 'character': col('.') - 1 + len(a:base) })
        return l:result is v:null ? [] : l:result
    endif
endfunction

function! LanguageClient#textDocument_signatureHelp(...) abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('textDocument/signatureHelp', l:params, l:callback)
endfunction

function! LanguageClient#workspace_applyEdit(...) abort
    if &buftype !=# '' || &filetype ==# ''
        return
    endif

    let l:params = {
                \ 'edit': {},
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('workspace/applyEdit', l:params, l:callback)
endfunction

function! LanguageClient#exit() abort
    return LanguageClient#Notify('exit', {
                \ 'languageId': &filetype,
                \ })
endfunction

" Set to 1 when the language server is busy (e.g. building the code).
let g:LanguageClient_serverStatus = 0
let g:LanguageClient_serverStatusMessage = ''

function! LanguageClient#serverStatus() abort
    return g:LanguageClient_serverStatus
endfunction

function! LanguageClient#serverStatusMessage() abort
    return g:LanguageClient_serverStatusMessage
endfunction

" Example function usable for status line.
function! LanguageClient#statusLine() abort
    if g:LanguageClient_serverStatusMessage ==# ''
        return ''
    endif

    return '[' . g:LanguageClient_serverStatusMessage . ']'
endfunction

function! LanguageClient#cquery_base(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('$cquery/base', l:params, l:callback)
endfunction

function! LanguageClient#cquery_derived(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('$cquery/derived', l:params, l:callback)
endfunction

function! LanguageClient#cquery_callers(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('$cquery/callers', l:params, l:callback)
endfunction

function! LanguageClient#cquery_vars(...) abort
    let l:params = {
                \ 'filename': s:Expand('%:p'),
                \ 'line': line('.') - 1,
                \ 'character': col('.') - 1,
                \ 'handle': v:true,
                \ }
    call extend(l:params, a:0 >= 1 ? a:1 : {})
    let l:callback = a:0 >= 2 ? a:2 : v:null
    return LanguageClient#Call('$cquery/vars', l:params, l:callback)
endfunction

function! LanguageClient#registerHandlers(handlers, ...) abort
    let l:handle = a:0 > 0 ? a:1 : v:null
    return LanguageClient#Call('languageClient/registerHandlers', a:handlers, l:handle)
endfunction

let g:LanguageClient_loaded = s:Launch()
