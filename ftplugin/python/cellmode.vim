" Implementation of a MATLAB-like cellmode for python scripts where cells
" are delimited by ##
"
" You can define the following globals or buffer config variables
"  let g:cellmode_tmux_sessionname='$ipython'
"  let g:cellmode_tmux_windowname='ipython'
"  let g:cellmode_tmux_panenumber='0'
"  let g:cellmode_screen_sessionname='ipython'
"  let g:cellmode_screen_window='0'
"  let g:cellmode_use_tmux=1

function! PythonUnindent(code)
    " The code is unindented so the first selected line has 0 indentation
    " So you can select a statement from inside a function and it will run
    " without python complaining about indentation.
    let l:lines = split(a:code, "\n")
    if len(l:lines) == 0 " Special case for empty string
        return a:code
    endif
    let l:nindents = strlen(matchstr(l:lines[0], '^\s*'))
    " Remove nindents from each line
    let l:subcmd = 'substitute(v:val, "^\\s\\{' . l:nindents . '\\}", "", "")'
    call map(l:lines, l:subcmd)
    let l:ucode = join(l:lines, "\n")
    return l:ucode
endfunction

function! GetVar(name, default)
    " Return a value for the given variable, looking first into buffer, then
    " globals and defaulting to default
    if (exists ("b:" . a:name))
        return b:{a:name}
    elseif (exists ("g:" . a:name))
        return g:{a:name}
    else
        return a:default
    endif
endfunction

function! CleanupTempFiles()
    " Called when leaving current buffer; Cleans up temporary files
    if (exists('b:cellmode_fnames'))
        for fname in b:cellmode_fnames
            call delete(fname)
        endfor
        unlet b:cellmode_fnames
    endif
endfunction

function! GetNextTempFile()
    " Returns the next temporary filename to use
    "
    " We use temporary files to communicate with tmux. That is we :
    " - write the content of a register to a tmpfile
    " - have ipython running inside tmux load and run the tmpfile
    " If we use only one temporary file, quick execution of multiple cells
    " will result in the tmpfile being overrident. So we use multiple tmpfile
    " that act as a rolling buffer (the size of which is configured by
    " cellmode_n_files)
    if !exists("b:cellmode_fnames")
        au BufDelete <buffer> call CleanupTempFiles()
        let b:cellmode_fnames = []
        for i in range(1, b:cellmode_n_files)
            call add(b:cellmode_fnames, tempname() . ".ipy")
        endfor
        let b:cellmode_fnames_index = 0
    endif
    let l:cellmode_fname = b:cellmode_fnames[b:cellmode_fnames_index]
    " TODO: Would be better to use modulo, but vim doesn't seem to like %
    " here...
    if (b:cellmode_fnames_index >= b:cellmode_n_files - 1)
        let b:cellmode_fnames_index = 0
    else
        let b:cellmode_fnames_index += 1
    endif

  "echo 'cellmode_fname : ' . l:cellmode_fname
  return l:cellmode_fname
endfunction

function! DefaultVars()
    " Load and set defaults config variables :
    " - b:cellmode_fname temporary filename
    " - g:cellmode_tmux_sessionname, g:cellmode_tmux_windowname,
    "   g:cellmode_tmux_panenumber : default tmux
    "   target
    " - b:cellmode_tmux_sessionname, b:cellmode_tmux_windowname,
    "   b:cellmode_tmux_panenumber :
    "   buffer-specific target (defaults to g:)
    let b:cellmode_n_files = GetVar('cellmode_n_files', 10)

    if !exists("b:cellmode_use_tmux")
        let b:cellmode_use_tmux = GetVar('cellmode_use_tmux', 1)
    endif

    if !exists("b:cellmode_cell_delimiter")
        " By default, use ##, #%% or # %% (to be compatible with spyder)
        let b:cellmode_cell_delimiter = GetVar('cellmode_cell_delimiter',
                    \ '\(##\|#%%\|#\s%%\)')
    endif

    if !exists("b:cellmode_tmux_sessionname") ||
                \ !exists("b:cellmode_tmux_windowname") ||
                \ !exists("b:cellmode_tmux_panenumber")
        " Empty target session and window by default => try to automatically
        " pick tmux session
        let b:cellmode_tmux_sessionname = GetVar('cellmode_tmux_sessionname',
                                               \ '')
        let b:cellmode_tmux_windowname = GetVar('cellmode_tmux_windowname',
                                              \ '')
        let b:cellmode_tmux_panenumber = GetVar('cellmode_tmux_panenumber',
                                              \ '0')
    endif

    if !exists("g:cellmode_screen_sessionname") ||
                \ !exists("b:cellmode_screen_window")
        let b:cellmode_screen_sessionname = GetVar(
                    \ 'cellmode_screen_sessionname', 'ipython')
        let b:cellmode_screen_window = GetVar('cellmode_screen_window', '0')
    endif
endfunction

function! CallSystem(cmd)
    " Execute the given system command, reporting errors if any
    let l:out = system(a:cmd)
    if v:shell_error != 0
        echom 'Vim-cellmode, error running ' . a:cmd . ' : ' . l:out
    endif
endfunction

function! CopyToTmux(code)
    " Copy the given code to tmux. We use a temp file for that
    let l:lines = split(a:code, "\n")
    " If the file is empty, it seems like tmux load-buffer keep the current
    " buffer and this cause the last command to be repeated. We do not want
    " that to happen, so add a dummy string
    if len(l:lines) == 0
        call add(l:lines, ' ')
    endif
    let l:cellmode_fname = GetNextTempFile()
    call writefile(l:lines, l:cellmode_fname)

    " tmux requires the sessionname to start with $ (for example $ipython to
    " target the session named 'ipython'). Except in the case where we want to
    " target the current tmux session (with vim running in tmux)
    if strlen(b:cellmode_tmux_sessionname) == 0
        let l:sprefix = ''
    else
        let l:sprefix = '$'
    endif
    let target = l:sprefix . b:cellmode_tmux_sessionname . ':'
                \ . b:cellmode_tmux_windowname . '.'
                \ . b:cellmode_tmux_panenumber

    " Ipython has some trouble if we paste large buffer if it has been started
    " in a small console. We use %load to work around that
    "call CallSystem('tmux load-buffer ' . l:cellmode_fname)
    "call CallSystem('tmux paste-buffer -t ' . target)
    call CallSystem("tmux set-buffer \"%load -y " . l:cellmode_fname . "\n\"")
    call CallSystem('tmux paste-buffer -t "' . target . '"')
    " In ipython5, the cursor starts at the top of the lines, so we have to
    " move to the bottom
    "let downlist = repeat('Down ', len(l:lines) + 1)
    "call CallSystem('tmux send-keys -t "' . target . '" ' . downlist)
    " Simulate double enter to run loaded code
    "call CallSystem('tmux send-keys -t "' . target . '" Enter Enter')
    call CallSystem('tmux send-keys -t "' . target . '" Enter')
endfunction

function! CopyToScreen(code)
    let l:lines = split(a:code, "\n")
    " If the file is empty, it seems like tmux load-buffer keep the current
    " buffer and this cause the last command to be repeated. We do not want
    " that to happen, so add a dummy string
    if len(l:lines) == 0
        call add(l:lines, ' ')
    endif
    let l:cellmode_fname = GetNextTempFile()
    call writefile(l:lines, l:cellmode_fname)

    if has('macunix')
        call system("pbcopy < " . l:cellmode_fname)
    else
        call system("xclip -i -selection c " . l:cellmode_fname)
    endif
    call system("screen -S " . b:cellmode_screen_sessionname .
                \ " -p " . b:cellmode_screen_window
                \ . " -X stuff '%paste\n'")
endfunction

function! RunTmuxPythonReg()
    " Paste into tmux the content of the register @a
    let l:code = PythonUnindent(@a)
    if b:cellmode_use_tmux
        call CopyToTmux(l:code)
    else
        call CopyToScreen(l:code)
    endif
endfunction

function! RunTmuxPythonCell(restore_cursor)
    " This is to emulate MATLAB's cell mode
    " Cells are delimited by ##. Note that there should be a ## at the end of
    " the file
    " The :?##?;/##/ part creates a range with the following
    " ?##? search backwards for ##
    " Then ';' starts the range from the result of the previous search (##)
    " /##/ End the range at the next ##
    " See the doce on 'ex ranges' here :
    " http://tnerual.eriogerg.free.fr/vimqrc.html
    " Note that cell delimiters can be configured through
    " b:cellmode_cell_delimiter, but we keep ## in the comments for simplicity
    call DefaultVars()
    if a:restore_cursor
        let l:winview = winsaveview()
    endif

    " Generates the cell delimiter search pattern
    let l:pat = ':?' . b:cellmode_cell_delimiter . '?;/'
                \ . b:cellmode_cell_delimiter . '/y a'

    " Execute it
    silent exe l:pat

    "silent :?\=b:cellmode_cell_delimiter?;/\=b:cellmode_cell_delimiter/y a

    " Now, we want to position ourselves inside the next block to allow block
    " execution chaining (of course if restore_cursor is true, this is a no-op
    " Move to the last character of the previously yanked text
    execute "normal! ']"
    " Move one line down
    execute "normal! j"

    " The above will have the leading and ending ## in the register, but we
    " have to remove them (especially leading one) to get a correct
    " indentation estimate. So just select the correct subrange of lines
    " [1:-2]
    let @a=join(split(@a, "\n")[1:-2], "\n")
    call RunTmuxPythonReg()
    if a:restore_cursor
        call winrestview(l:winview)
    endif
endfunction

function! RunTmuxPythonAllCellsAbove()
    " Executes all the cells above the current line. That is, everything from
    " the beginning of the file to the closest ## above the current line
    call DefaultVars()

    " Ask the user for confirmation, this could lead to huge execution
    if confirm("Execute all cells above?", "&Yes\n&No") != 1
        return
    endif

    let l:cursor_pos = getpos(".")

    " Creates a range from the first line to the closest ## above the current
    " line (?##? searches backward for ##)
    let l:pat = ':1,?' . b:cellmode_cell_delimiter . '?y a'
    silent exe l:pat

    let @a=join(split(@a, "\n")[:-2], "\n")
    call RunTmuxPythonReg()
    call setpos(".", l:cursor_pos)
endfunction

function! RunTmuxPythonChunk() range
    call DefaultVars()
    " Yank current selection to register a
    silent normal! gv"ay
    call RunTmuxPythonReg()
endfunction

function! RunTmuxPythonLine()
    call DefaultVars()
    " Yank current selection to register a
    silent normal! "ayy
    call RunTmuxPythonReg()
endfunction

" Returns:
"   1 if the var is set, 0 otherwise
function! InitVariable(var, value)
    if !exists(a:var)
        execute 'let ' . a:var . ' = ' . "'" . a:value . "'"
        return 1
    endif
    return 0
endfunction

function! MoveCellWise(upwards = 0)", was_visual)
    " Find cell delimiters, moving via search (for delimiters).
    " If there are exceptions, move to TOP (0), or BOTTOM ($).

    call DefaultVars()
    let xx = b:cellmode_cell_delimiter . '.*\n.'
    " let so=&scrolloff | set so=10

    " Move INTO cell if currently on delim
    "if getline(".") =~ xx && !a:upwards
    "    " NB: we must move entire folds (whence gj, gk) because if we're
    "    " inside a fold then vim search won't find the above delimiter. Of
    "    " course, this still does not work when we're on the very last fold.
    "    normal! gj
    "endif

    " Find match above
    "try
    "    exec ':?'.xx
    "catch
    "    silent 0
    "endtry
    "let g:line1=line('.')

    " Find match below
    "try
    "    exec ':/'.xx
    "catch
    "    silent $
    "endtry
    "let g:line2=line('.')

    " Re-select visual
    "if a:was_visual
    "    normal! gv
    "endif

    " Goto match
    if a:upwards
        "call setpos('.', [0, g:line1, 0, 0])
        call search(xx, 'bcesW')  " Move to top of current cell
        call search(xx, 'beW')
    else
        "call setpos('.', [0, g:line2, 0, 0])
        call search(xx, 'esW')
    endif

    " Manual scrolloff
    "mark a
    "normal! 10j
    "normal! 'a
    "normal! 10k
    "normal! 'a

    " Always scroll: center, then down 25%
    "normal! zz
    "exe "normal! " . &lines/4. "\<C-e>"

    " Restore setting
    "if l:wpscn | set wrapscan | endif
    "let &so=so
endfunction

function! FoldCreate()
    if &foldmethod != 'manual'
        set foldmethod=manual
    endif
    call DefaultVars()
    let xx = b:cellmode_cell_delimiter
    let l1 = search(xx, 'bnW')
    let l2 = search(xx, 'cnW')
    if l2 == 0 | let l2 = line('$') | endif
    " Check if there is space to fold
    if  l2 - l1 > 2
        execute ":".(l1+1).",".(l2-1)."fold"
    else
        return -1
    endif
endfunction

function! FoldAll()
    "if &foldmethod != 'manual'
    "    set foldmethod=manual
    "endif
    call DefaultVars()
    let xx = b:cellmode_cell_delimiter
    let pos = getcurpos()
    "let fl = &foldlevel
    normal! zR
    keepjumps normal! gg

    let is_on_last_line = line(".") == line("$")
    while !is_on_last_line
        "if !foldlevel(".")
        "    call FoldCreate()
        "    normal! j
        "else
        "    let line_tmp = getline(".")
        "    norm gj
        "    " Fix corner case (gj doesnt move to bottom when on last fold)
        "    if getline(".") == line_tmp
        "        silent $
        "    endif
        "endif
        call FoldCreate()
        normal! 2j
        let is_on_last_line = line(".") == line("$")
    endwhile

    " Restore cursor pos
    call setpos('.', pos)
    "let &foldlevel=fl+1
endfunction

command! FoldAll :call FoldAll()

call InitVariable("g:cellmode_default_mappings", 1)

if g:cellmode_default_mappings
    vnoremap <silent> <C-c> :call RunTmuxPythonChunk()<CR>
    noremap <silent> <C-b> :call RunTmuxPythonCell(0)<CR>
    noremap <silent> <C-g> :call RunTmuxPythonCell(1)<CR>
    nnoremap <silent> zf<CR> :call FoldCreate()<CR>
endif
