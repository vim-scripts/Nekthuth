""" Author: Frank Duncan (frank@nekthuth.com) Copyright 2008
""" Version: 0.1
""" 
""" License:  GPLv2 (Note that the lisp component is licensed under LLGPL)
"""
""" This program is free software; you can redistribute it and/or
""" modify it under the terms of the GNU General Public
""" License as published by the Free Software Foundation; either
""" version 2 of the License, or (at your option) any later version.
"""
""" This program is distributed in the hope that it will be useful,
""" but WITHOUT ANY WARRANTY; without even the implied warranty of
""" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
""" General Public License for more details.
"""
""" You should have received a copy of the GNU Library General Public
""" License along with this library; if not, write to the
""" Free Software Foundation, Inc., 59 Temple Place - Suite 330,
""" Boston, MA 02111-1307, USA.

if exists("g:nekthuth_disable")
  finish
endif

if !exists("g:nekthuth_remote_port")
  let g:nekthuth_remote_port = 8532
endif

if v:version < 700
  echoerr "Could not initialize nekthuth, need version > 7"
  finish
elseif !has("python3") 
  echoerr "Could not initialize nekthuth, not compiled with +python3"
  finish
endif

if exists("g:nekthuth_defined")
  finish
endif
let g:nekthuth_defined = 1

if("" == $NEKTHUTH_HOME)
  let g:nekthuth_home = $HOME . "/.nekthuth/"
else
  let g:nekthuth_home = $NEKTHUTH_HOME
endif

" This must match the version on the lisp side
let g:nekthuth_version = "0.4"

let g:plaintex_delimiters = 1

if !exists("g:nekthuth_updatetime")
  let g:nekthuth_updatetime = 500
endif

let &updatetime = g:nekthuth_updatetime

autocmd BufDelete,BufUnload,BufWipeout Nekthuth.Interpreter python3 closeNekthuth()
autocmd VimLeave * python3 closeNekthuth()
au CursorHold,CursorHoldI * python3 cursorHoldDump()
au CursorMoved,CursorMovedI * python3 dumpLispMovement()
au BufEnter *.lisp python3 refreshSyntax()
au BufEnter Nekthuth.Interpreter python3 refreshSyntax()
au BufUnload *.lisp python3 removeBufferFromSyntaxList()
au BufUnload Nekthuth.Interpreter python3 removeBufferFromSyntaxList()
command! -nargs=0 -count=0 NekthuthSexp python3 sendSexp(getRelativeCount(<count>))
command! -nargs=0 -count=0 NekthuthMacroExpand python3 macroExpand(getRelativeCount(<count>))
command! -nargs=0 NekthuthTopSexp python3 sendSexp(100)
command! -nargs=0 NekthuthClose python3 closeNekthuth()
command! -nargs=0 NekthuthOpen python3 openNekthuth()
command! -nargs=? NekthuthRemote python3 remoteNekthuth('<args>')
command! -nargs=0 NekthuthInterrupt python3 sendInterrupt()
command! -nargs=0 NekthuthSourceLocation python3 openSourceLocation()

function! NekthuthOmni(findstart, base)
  execute "python3 omnifunc(" . a:findstart . ", \"" . a:base . "\")"
  return l:retn
endfunction

hi link lispAtom Special

set omnifunc=NekthuthOmni

if !exists("g:nekthuth_sbcl")
  let g:nekthuth_sbcl = "/usr/bin/sbcl"
endif

if !exists("g:lisp_debug")
  let g:lisp_debug = "N"
endif

python3 << EOF
import threading,time,vim,os,sys,locale,re,socket,subprocess

interpBuffer = None
debugBuffer = None
vertical = True

consoleBuffers = []

sock = None
input = None
output = None
lock = threading.Lock()
errorMsgs = []

debugMode = (vim.eval("g:lisp_debug") == "Y")

plugins = {}

class Sender(threading.Thread):
  started = False

  def run (self):
    global lock,plugins,errorMsgs,debugMode
    while not output.closed:
      cmdChar = output.read(1)

      if cmdChar == '': 
        print("Lisp closed!")
        print()
        output.close()
      elif cmdChar == '\n':
        pass
      elif cmdChar == 'A':
        msg = output.readline()
        if 'GO\n' == msg:
          self.started = True
        elif 'STOP\n' == msg:
          closeNekthuth()
          print("Failed to start up nekthuth.  Either the asdf package is not installed or the incorrect version (expected " + vim.eval("g:nekthuth_version") + ")", file=sys.stderr)
        elif 'THREAD\n' == msg:
          closeNekthuth()
          print("Failed to start up nekthuth.  SBCL not compiled with thread options.", file=sys.stderr)
        elif msg.startswith('VERSION'):
          ver = msg.replace('VERSION', '')
          if ver.rstrip() != vim.eval ("g:nekthuth_version"):
            closeNekthuth()
            output.close()
            print(("Failed to start up nekthuth.  Version was incorrect, vim plugin version is " +
                                  vim.eval ("g:nekthuth_version") +
                                  " but lisp package version " + ver), file=sys.stderr)

      elif (self.started and cmdChar in plugins):
        plugin = plugins[cmdChar]
        if ('bell' in plugin and plugin['bell'] and 'waitingForResponse' in plugin and plugin['waitingForResponse']):
          print("Response from lisp waiting")

        incomingSize = int(output.read(6))
        lock.acquire()
        plugin['msg'].append(output.read (incomingSize))
        lock.release()
      else:
        if debugMode:
          errorMsgs.append(cmdChar + ')' + output.readline())
        else:
          output.readline()


def lispSend(cmdChar, msg):
  global input
  openNekthuth()
  input.write(cmdChar)
  input.write("%06d" % len(msg))
  input.write(msg)
  input.flush()

def getBufferNum():
  global interpBuffer
  return vim.eval("bufwinnr('" + interpBuffer.name + "')")

def bufferSend(msg):
  global interpBuffer
  if interpBuffer == None:
    return
  if type('') == type(msg):
    for line in msg.strip("\n").split("\n"):
      interpBuffer.append(line)
  elif type([]) == type(msg):
    for str in msg:
      for line in str.strip("\n").split("\n"):
        interpBuffer.append(line)

  curwinnum = vim.eval("winnr()")
  bufwinnum = getBufferNum()
  vim.command (bufwinnum + "wincmd w")
  vim.current.window.cursor = (len(interpBuffer), 0);
  vim.command ("redraw")
  vim.command (curwinnum + "wincmd w")

def lispSendReceive(cmdChar, msg):
  global plugins,lock
  lock.acquire()
  if not cmdChar in plugins:
    plugins[cmdChar] = {}
  plugins[cmdChar]['msg'] = []
  lock.release()

  lispSend(cmdChar, msg)

  waits = 0
  while (plugins[cmdChar]['msg'] == []):
    time.sleep(0.2)
    waits += 1
    if waits > 50:
      raise Exception('Waited more than 10 seconds, and no response, something is wrong')

  lock.acquire()
  retn = plugins[cmdChar]['msg'][0]
  lock.release()
  return retn

# bell is if you want the user to be pinged that lisp has a response ready
def registerReceiver(cmdChar, callback, bell):
  global plugins,lock
  if not cmdChar in plugins:
    lock.acquire()
    plugins[cmdChar] = {'callback':callback, 'bell':bell, 'msg':[]}
    lock.release()

def openNekthuthWindow():
  global interpBuffer,vertical

  if interpBuffer == None or getBufferNum() == "-1":
    bufNum = -1

    if interpBuffer == None:
      vim.command("badd Nekthuth.Interpreter")
      bufNum = int(vim.eval("bufnr(\"Nekthuth.Interpreter\")"))
      interpBuffer = vim.buffers[bufNum]
      vim.command("call setbufvar(\"Nekthuth.Interpreter\", \"&buftype\", \"nofile\")")
      vim.command("call setbufvar(\"Nekthuth.Interpreter\", \"&swapfile\", 0)")
      vim.command("call setbufvar(\"Nekthuth.Interpreter\", \"&filetype\", \"lisp\")")
      vim.command("call setbufvar(\"Nekthuth.Interpreter\", \"&hidden\", 1)")
    else:
      bufNum = interpBuffer.number

    if vim.current.window.width > 160:
      vertical = False
      vim.command("vsplit +b\\ " + str(bufNum))
    else:
      vertical = True
      vim.command("split +b\\ " + str(bufNum))
    vim.command ("wincmd w")

def openNekthuth():
  global input,output
  if interpBuffer == None:
    if not os.path.exists(vim.eval("g:nekthuth_sbcl")):
      print("Could not open the nekthuth: path " + vim.eval("g:nekthuth_sbcl") +\
        " does not exists", file=sys.stderr)
      return
    print("Starting lisp interpreter")
    print()
    openNekthuthWindow()
    subproc = subprocess.Popen([vim.eval("g:nekthuth_sbcl"), "--noinform"], bufsize=1, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, close_fds=True, universal_newlines=True)
    (input, output) = (subproc.stdin, subproc.stdout)

    input.write('#-sb-thread (progn (format t "~%ATHREAD~%") (sb-ext:quit))\n')
    input.flush()
    input.write("(ignore-errors (asdf:oos 'asdf:load-op 'nekthuth))\n")
    input.flush()
    input.write("(declaim (optimize (speed 0) (space 0) (debug 3)))\n")
    input.flush()
    input.write('(if (ignore-errors (funcall (symbol-function (find-symbol "EXPECTED-VERSION" \'nekthuth.system)) ' + vim.eval ("g:nekthuth_version") + ')) (progn (format t "~%") (funcall (find-symbol "START-IN-VIM" \'nekthuth))) (progn (format t "~%ASTOP~%") (sb-ext:quit)))\n')
    input.flush()

    Sender().start()
  else:
    openNekthuthWindow()

def remoteNekthuth(port):
  if port == '':
    port = vim.eval("g:nekthuth_remote_port")

  global input,output,sock
  if interpBuffer == None:
    print("Starting remote connection to lisp")
    print()
    try:
      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      sock.connect(('localhost', int(port)))
    except:
      print("Could not connect to lisp!", file=sys.stderr)
      return
    input = sock.makefile("w")
    output = sock.makefile("r")

    openNekthuthWindow()

    Sender().start()
  else:
    openNekthuthWindow()

def getCurrentPos():
  col = int(vim.eval("virtcol('.')")) - 1
  line = int(vim.eval("line('.')")) - 1
  vim.command("normal! H")
  top = int(vim.eval("line('.')")) - 1

  vim.command("normal! " + str(line + 1) + "G" + str(col + 1) + "|")

  return {"top": top, "line": line, "col": col}

def gotoPos(pos):
  vim.command("normal! " + str(pos["top"] + 1) + "Gzt" + str(pos["line"] + 1) + "G" + str(pos["col"] + 1) + "|")

def gotoNextNonCommentChar():
  p = re.compile('\s')
  while True:
    prev_line = vim.eval("line('.')")
    cur_char = vim.eval("getline('.')[col('.') - 1]")
    if cur_char == '':
      break
    elif cur_char == ';':
      vim.command("normal j")
    elif cur_char == None or p.match(cur_char) != None:
      vim.command("normal W")
    else:
      break
    if cur_char == vim.eval("getline('.')[col('.') - 1]") and prev_line == vim.eval("line('.')"):
      break

def getColBackwards(pos, line):
  if pos == -1:
    return 0
  elif re.compile("^[\(\) ']$").match(line[pos]):
    return pos + 1
  else:
    return getColBackwards (pos - 1, line)

def getColForwards(pos, line):
  if pos == (len(line)):
    return len(line) - 1
  elif re.compile("^[\(\) ']$").match(line[pos]):
    return pos - 1
  else:
    return getColForwards (pos + 1, line)

# Gets the count relative to the line you are on
def getRelativeCount(count):
  curpos = getCurrentPos()
  if count == 0:
    count = 1
  elif count > int(vim.eval("line('.')")):
    count = count - int(vim.eval("line('.')")) + 1
  if vim.current.buffer[curpos["line"]][curpos["col"]] == '(':
    count = count - 1
  return count

def getSexp(count):
  curpos = getCurrentPos()
  if count > 0:
    vim.command ("normal! " + str(count) + "[(")

  parenPos = getCurrentPos()
  if vim.current.buffer[parenPos["line"]][parenPos["col"]] == '(':
    vim.command ("silent normal! \"lyab")
  else:
    firstCol = getColBackwards(parenPos["col"], vim.current.buffer[parenPos["line"]])
    lastCol = getColForwards(parenPos["col"], vim.current.buffer[parenPos["line"]]) + 1
    vim.command ("normal! |" + str(firstCol))
    vim.command ("silent normal! \"l" + str(lastCol - firstCol) + "yl")

  gotoPos (curpos)
  retn = vim.eval("@l")

  vim.command ("let @l=@_")
  return retn

def closeNekthuth():
  global input,interpBuffer,sock
  if interpBuffer != None:
    print("Closing Lisp")
    print()
    interpBuffer = None
    input.write ("Q000000")
    input.flush()
    input.close()
    vim.command ("bw Nekthuth.Interpreter")
  if sock != None:
    sock.close()

def dumpLispMovement():
  for plugin in plugins.values():
    plugin['waitingForResponse'] = False
  dumpLisp()

def dumpLisp():
  global lock,plugins,errorMsgs,debugMode
  if (debugMode and errorMsgs != []):
    bufferSend(errorMsgs)
    errorMsgs = []
  for plugin in plugins.values():
    if ('bell' in plugin and plugin['msg'] != []):
      plugin['waitingForResponse'] = False;
    if ('callback' in plugin and plugin['msg'] != []):
      lock.acquire()
      msg = plugin['msg']
      plugin['msg'] = []
      lock.release()
      plugin['callback'](msg)

def cursorHoldDump():
  for plugin in plugins.values():
    plugin['waitingForResponse'] = True
  dumpLisp()

### Functions related to the console window
def getConsoleWindowBuffer():
  global consoleBuffers

  for buf in consoleBuffers:
    if buf != None and vim.eval("bufwinnr('" + buf.name + "')") != "-1":
      return buf

  return None

def getConsoleWindowNum():
  buf = getConsoleWindowBuffer()
  if buf != None:
    return vim.eval("bufwinnr('" + buf.name + "')")
  return None

def setConsoleBuffer(buf, display):
  global consoleBuffers
  if not buf in consoleBuffers:
    consoleBuffers.append(buf)
  openNekthuth()
  if not isConsoleWindowLocked():
    prevbuf = getConsoleWindowBuffer()
    if buf != prevbuf:
      winNum = getConsoleWindowNum()
      curwinnum = vim.eval("winnr()")
      openNekthuthWindow()
      bufwinnum = getBufferNum()
      vim.command (bufwinnum + "wincmd w")

      if winNum == None:
        if vertical:
          vim.command("vsplit +b\\ " + str(buf.number))
        else:
          vim.command("split +b\\ " + str(buf.number))
      else:
        vim.command (winNum + "wincmd w")
        vim.command ("b " + str(buf.number))

      buf.vars["statusline"] = display
      vim.command (curwinnum + "wincmd w")
    return prevbuf
  else:
    print("Console window currently locked!", file=sys.stderr)

scratchnum = 0
def makeScratchLispBuffer(text, display):
  global scratchnum
  scratchname = "NekthuthScratch." + str(scratchnum)
  vim.command("badd " + scratchname)
  scratchnum += 1
  bufNum = int(vim.eval("bufnr(\"" + scratchname + "\")"))
  vim.command("call setbufvar(\"" + scratchname + "\", \"&buftype\", \"nofile\")")
  vim.command("call setbufvar(\"" + scratchname + "\", \"&swapfile\", 0)")
  vim.command("call setbufvar(\"" + scratchname + "\", \"&bufhidden\", \"delete\")")
  vim.command("call setbufvar(\"" + scratchname + "\", \"&buflisted\", 0)")
  vim.command("call setbufvar(\"" + scratchname + "\", \"&filetype\", \"lisp\")")
  buf = vim.buffers[bufNum]
  if type('') == type(text):
    for line in text.strip("\n").split("\n"):
      buf.append(line)
  elif type([]) == type(text):
    for lines in text:
      for line in lines.strip("\n").split("\n"):
        buf.append(line)
  setConsoleBuffer(buf, display)
  bufwinnum = vim.eval("bufwinnr('" + buf.name + "')")
  vim.command (bufwinnum + "wincmd w")
  vim.command("set statusline=" + display)

def isConsoleWindowOpen():
  return (getConsoleWindowBuffer() != None)

# For debug and maybe other modes requiring immediate feedback
def isConsoleWindowLocked():
  global debugBuffer

  return (debugBuffer != None and getConsoleWindowBuffer() == debugBuffer)

### Synchronous plugins
def macroExpand(count):
  expr = getSexp(count)
  makeScratchLispBuffer([expr, "", ";;;;;;;; EXPANDED TO ;;;;;;;;", "", lispSendReceive('M', expr)], "MACRO-EXPAND")

def openSourceLocation():
  curword = vim.eval("expand(\"<cword>\")")
  resp = eval(lispSendReceive('L', curword))
  if type('') == type(resp):
    print(resp, file=sys.stderr)
  else:
    (fileloc, charno) = resp
    if vim.eval("expand(\"%:p\")") != fileloc:
      vim.command ("split " + fileloc)
    vim.command (str(charno + 1) + "go")
    gotoNextNonCommentChar()

### Pure receiving plugins

### If a new buffer happen, we need to make sure to re-import all the syntax additions
### Therefore, we have to keep a master list for all syntax additions that have ever been done
allSyntaxAdditions = []
bufferSyntaxList = {}
def addSyntax(msgs):
  global allSyntaxAdditions, bufferSyntaxList
  if msgs != []:
    for key in bufferSyntaxList.keys():
      for msg in msgs:
        allSyntaxAdditions.extend(eval(msg))
        bufferSyntaxList[key].extend(eval(msg))
    for msg in msgs:
      allSyntaxAdditions.extend(eval(msg))
    refreshSyntax()

def refreshSyntax():
  global bufferSyntaxList
  filename = vim.current.buffer.name
  if filename in bufferSyntaxList:
    for syntax in bufferSyntaxList[filename]:
      vim.command("syn keyword lispLocalFunc " + syntax)
    bufferSyntaxList[filename] = []
  else:
    bufferSyntaxList[filename] = []
    vim.command("syn cluster lispAtomCluster add=lispLocalFunc")
    vim.command("syn cluster lispBaseListCluster add=lispLocalFunc")
    vim.command("hi def link lispLocalFunc Function")
    for syntax in allSyntaxAdditions:
      vim.command("syn keyword lispLocalFunc " + syntax)

def removeBufferFromSyntaxList():
  filename = vim.buffers[int(vim.eval("expand(\"<abuf>\")"))].name
  global bufferSyntaxList
  if filename in bufferSyntaxList:
    del bufferSyntaxList[filename]

registerReceiver('S', addSyntax, False)

def createDebugBuffer():
  global debugBuffer

  if debugBuffer == None:
    vim.command("badd Nekthuth.Debugger")
    bufNum = int(vim.eval("bufnr(\"Nekthuth.Debugger\")"))
    debugBuffer = vim.buffers[bufNum]
    vim.command("call setbufvar(\"Nekthuth.Debugger\", \"&buftype\", \"nofile\")")
    vim.command("call setbufvar(\"Nekthuth.Debugger\", \"&swapfile\", 0)")
    vim.command("call setbufvar(\"Nekthuth.Debugger\", \"&hidden\", 1)")

def sendDebugResponse(restart, curwinnum, prevBufNum):
  lispSend('D', restart)
  vim.command ("close") if prevBufNum == -1 else vim.command("b " + str(prevBufNum))
  vim.command (curwinnum + "wincmd w")

def debugger(msgs):
  global debugBuffer
  createDebugBuffer()

  prevBuf = setConsoleBuffer(debugBuffer, "Nekthuth Debugger")
  prevBufNum = prevBuf.number if prevBuf != None else -1

  debugResponse = 0;
  debugText = msgs[0].split("\n")

  numRestarts = int(debugText[0])

  vim.command ("set paste")

  curwinnum = vim.eval("winnr()")
  bufwinnum = vim.eval("bufwinnr('" + debugBuffer.name + "')")
  vim.command (bufwinnum + "wincmd w")
  vim.command ("%d")
  vim.command ("mapc <buffer>")

  for line in debugText[1:]:
    debugBuffer.append(line)

  vim.command ("redraw!")
  for i in range(1, numRestarts + 1):
    vim.command("map <buffer> <F" + str(i) + "> :python3 sendDebugResponse('" + str(i) + "', '" + curwinnum + "', " + str(prevBufNum) + ")<CR>")

registerReceiver('D', debugger, True)

def errorFromLisp(msgs):
  vim.eval ("input('" + msgs[0].replace("'", "''") + "')")
registerReceiver('E', errorFromLisp, False)

### Pure sending plugins
def sendInterrupt():
  lispSend('I', '')

### Asynchronous plugins
def sendSexp(count):
  global interpBuffer
  openNekthuth()
  str = getSexp(count)
  if str == "":
    return
  msgs=[]
  for line in str.strip("\n").split("\n"):
    msgs.append("> " + line)
  lispSend('R', str)
  bufferSend(msgs)
  dumpLispMovement()

def replPrinter(msgs):
  msgs.append('')
  bufferSend(msgs)
  print()
registerReceiver('R', replPrinter, True)

def omnifunc(findstart, base):
  if findstart == 1:
    curCol = int(vim.eval("col('.')"))
    curLine = int(vim.eval("line('.')"))
    vim.command ("let l:retn = " + str(getColBackwards(curCol - 2, vim.current.buffer[curLine - 1])))
  else:
    if base != '':
      vim.command ("let l:retn = " + lispSendReceive('C', '"' + base + '"'))
    else:
      vim.command ("let l:retn = []")

EOF

""" Help is a bit more complicated, and so get its own section
let s:hyperspecTagsfile = findfile('ftplugin/lisp/nekthuth/hyperspecTags', escape(&runtimepath, ' '))
command! -complete=custom,HyperSpecTags -nargs=1 Clhelp python3 showHelp('<args>')

function! HyperSpecTags(ArgLead, CmdLine, CursorPos)
  return g:hyperspecTags
endfunction

python3 << EOF
import vim,sys,re

hyperspecTags = dict([line.rstrip().split("\t") for line in open(vim.eval("s:hyperspecTagsfile"))])
helpBuffer = None

def createHelpBuffer():
  global helpBuffer,hyperspecTags

  if helpBuffer == None:
    vim.command("badd HyperSpec.Help")
    bufNum = int(vim.eval("bufnr(\"HyperSpec.Help\")"))
    helpBuffer = vim.buffers[bufNum]
    vim.command("call setbufvar(\"HyperSpec.Help\", \"&swapfile\", 0)")
    vim.command("call setbufvar(\"HyperSpec.Help\", \"&buftype\", \"nofile\")")
    vim.command("call setbufvar(\"HyperSpec.Help\", \"&lbr\", 1)")
    vim.command("call setbufvar(\"HyperSpec.Help\", \"&hidden\", 1)")

def showHelp(tagname):
  global hyperspecTags,helpBuffer
  if tagname in hyperspecTags:
    openNekthuth()
    createHelpBuffer()
    setConsoleBuffer(helpBuffer, "Nekthuth HyperSpec")
    bufwinnum = vim.eval("bufwinnr('" + helpBuffer.name + "')")
    vim.command (bufwinnum + "wincmd w")
    vim.command ("%d")
    vim.command("call setbufvar(\"HyperSpec.Help\", \"&ft\", \"help\")")

    help = lispSendReceive('H', '"' + hyperspecTags[tagname] + '"')
 
    if re.compile("^Error:").match(help):
      print(help, file=sys.stderr)
    else:
      for line in help.strip("\n").split("\n"):
        vim.current.buffer.append(line)
  else:
    print("Could not find help for: " + tagname, file=sys.stderr)

vim.vars["hyperspecTags"] = "\n".join(sorted(hyperspecTags.keys()))
EOF

for f in split(glob(g:nekthuth_home . "/vim/*.vim"), "\n")
  exec 'source' . f
endfor
