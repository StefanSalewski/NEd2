# nim c --gc:arc ned.nim
import gintro/[gtk4, gdk4, gobject, glib, gio, gtksource5, pango]

from OS import paramCount, paramStr, extractFilename, findExe, splitFile, parentDir, removeFile
import osproc
import strutils
import net

const
  NSPort = Port(6000)
  MaxErrorTags = 16
  ErrorTagName = "error"

const menuData = """
  <interface>
    <menu id="menuModel">
      <section>
        <item>
          <attribute name="label">Save As...</attribute>
          <attribute name="action">win.safe-as</attribute>
        </item>
        <item>
          <attribute name="label">check</attribute>
          <attribute name="action">win.check</attribute>
        </item>
        <submenu>
          <attribute name="label">Submenu</attribute>
          <item>
            <attribute name="label">Submenu Item</attribute>
            <attribute name="action">win.submenu-item</attribute>
          </item>
        </submenu>
        <item>
          <attribute name="label">Toggle Menu Item</attribute>
          <attribute name="action">win.toggle-menu-item</attribute>
        </item>
      </section>
      <section>
        <item>
          <attribute name="label">Radio 1</attribute>
          <attribute name="action">win.radio</attribute>
          <attribute name="target">1</attribute>
        </item>
        <item>
          <attribute name="label">Radio 2</attribute>
          <attribute name="action">win.radio</attribute>
          <attribute name="target">2</attribute>
        </item>
        <item>
          <attribute name="label">Radio 3</attribute>
          <attribute name="action">win.radio</attribute>
          <attribute name="target">3</attribute>
        </item>
      </section>
    </menu>
  </interface>"""

# do cleanup work, closing files or saving documents
proc shutdown(app: Application) =
  echo "shutdown"



proc handleLocalOptions(app: Application; vd: VariantDict): int =
  echo "handle-local-options"

proc nameLost(app: Application): bool =
  echo "name-lost"

type
  NimViewError = tuple
    gs: string
    line, col, id: int

type
  NedWindow = ref object of gtk4.ApplicationWindow
    filePath: string
    gFile: GFile
    buffer: gtksource5.Buffer

  NimView = ref object of gtksource5.View
    errors: seq[NimViewError]

proc setErrorAttr(view: NimView) =
  var attrs = newMarkAttributes()
  var color = RGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.3)
  attrs.background = color
  attrs.iconName = "list-remove"
  view.setMarkAttributes(ErrorTagName, attrs, priority = 1)

var thread: system.Thread[NedWindow]
#var channel: system.Channel[StatusMsg]
var nsProcess: Process # nimsuggest

# https://developer.gnome.org/gtk4/unstable/GtkFileChooser.html#gtk-file-chooser-set-file
proc prepareFileChooser(chooser: FileChooserDialog; existingFile: GFile) =
  let documentIsNew = (existingFile == nil)
  if documentIsNew:
      let defaultFileForSaving = newGFileForPath ("./out.txt")
      # the user just created a new document
      discard chooser.setCurrentFolder(defaultFileForSaving)
      chooser.setCurrentName("Untitled document")
  else:
      # the user edited an existing document
      discard chooser.setFile(existing_file)
    
proc fileChooserResponseCb(d: FileChooserDialog; id: int; w: NedWindow) =
  if ResponseType(id) == ResponseType.accept:
    let file = d.file
    echo file.getPath
    w.gFile = file
  d.destroy

proc saveAsCb(action: gio.SimpleAction; parameter: glib.Variant; w: NedWindow) =
  echo("Save As")
  let dialog = newFileChooserDialog("Save File", w, FileChooserAction.save)
  prepareFileChooser(FileChooserDialog(dialog), w.gfile)
  discard dialog.addButton("Save", ResponseType.accept.ord)
  discard dialog.addButton("Cancel", ResponseType.cancel.ord)
  dialog.connect("response", fileChooserResponseCb, w)
  dialog.show

proc saveFile(b: Button; w: NedWindow) =
  let buffer = w.buffer
  let startIter = buffer.getStartIter
  let endIter = buffer.getEndIter
  let text = buffer.getText(startIter, endIter, includeHiddenChars = true)
  let gfile: GFile = newGFileForPath(w.filePath) # never fails
  let res = gfile.replaceContents(text, etag = nil, makeBackup = false, FileCreateFlags({}))
  #  buffer.modified = false
  echo "saveFile"

proc initSuggest(win: NedWindow; path: string) =
  if nsProcess.isNil and path.endsWith(".nim"):
    let file: GFile = newGFileForPath(path)
    if queryExists(file, nil):
      #open(channel)
      let nimBinPath = findExe("nim")
      doAssert(nimBinPath.len > 0, "we need nim executable!")
      let nimsuggestBinPath = findExe("nimsuggest")
      doAssert(nimsuggestBinPath.len > 0, "we need nimsuggest executable!")
      let nimPath = nimBinPath.splitFile.dir.parentDir
      nsProcess = startProcess(nimsuggestBinPath, nimPath,
                         ["--v2", "--threads:on", "--port:" & $NSPort, $path],
                         options = {poStdErrToStdOut, poUsePath})
      #createThread[NedWindow](thread, showData, win)

proc removeMarks(view: NimView) =
  echo "removeMarks"
  let buffer = gtksource5.Buffer(view.buffer)
  #let buffer = view.buffer
  let startIter = buffer.getStartIter
  let endIter = buffer.getEndIter
  buffer.removeTagByName(ErrorTagName, startIter, endIter)
  for i in 0 .. MaxErrorTags:
    buffer.removeTagByName($i, startIter, endIter)
  buffer.removeSourceMarks(startIter, endIter)
  view.showLinemarks = false

## returns dirtypath or "" for failure
proc saveDirty(filepath: string; text: string): string =
  var stream: FileIOStream
  let filename = filepath.splitFile[1] & "XXXXXX.nim"
  let gfile = newGFileTmp(filename, stream)
  if gfile.isNil:
    return
  if gfile.replaceContents(text, etag = nil, makeBackup = false, {FileCreateFlag.private}):
    result = gfile.path

# return errorID > 0 when new error position, or 0 for old position
proc addError(v: NimView, s: string; line, col: int): int =
  echo "addError"
  for el in mitems(v.errors):
    if el.line == line and el.col == col:
      el.gs &= ("\n" & s)
      return 0
  let i = system.int(v.errors.len) + 1
  if i > MaxErrorTags: return 0
  var el: NimViewError
  el.gs = s
  el.line = line
  el.col = col
  el.id = i
  v.errors.add(el)
  return i

proc setErrorMark(view: NimView; ln, cn: int) =
  echo "setErrorMark", ln, " ", cn
  var iter: TextIter
  let buffer = gtksource5.Buffer(view.getBuffer)
  discard buffer.getIterAtLineIndex(iter, ln.cint, cn.cint)
  discard iter.backwardLine
  if ln > 0:
    discard iter.forwardLine
  buffer.removeSourceMarks(iter, iter)
  echo "AAA"
  discard buffer.createSourceMark("", ErrorTagName, iter)
  echo "HA"

proc jumpto(view: NimView; line, column: int) =
  var iter: TextIter
  let buffer = view.buffer
  discard buffer.getIterAtLineIndex(iter, line, column)
  buffer.placeCursor(iter)
  view.scrollToMark(buffer.insert, withinMargin = 0.25, useAlign = false, xalign = 0, yalign = 0)

proc advanceErrorWord(ch: gunichar, userdata: pointer): gboolean {.cdecl.} = gboolean(not unicharIsalnum(ch))

# can not remember why we did it in this way...
proc setErrorTag(view: NimView; ln, cn, id: int) =
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>setErrorTag"
  var startIter, endIter, iter: TextIter
  let buffer = view.buffer
  discard buffer.getIterAtLineIndex(startIter, ln.cint, cn.cint)
  let tag: TextTag = buffer.tagTable.lookup(ErrorTagName)
  assert(tag != nil)
  discard startiter.backwardChar # separate adjanced error tags
  if startIter.hasTag(tag):
    discard startIter.forwardToTagToggle(tag) # same as forwardChar?
  discard startiter.forwardChar
  endIter = startIter
  iter = startIter
  discard iter.forwardToLineEnd
  discard endIter.forwardChar # check
  discard endIter.forwardFindChar(advanceErrorWord, userData = nil, limit = iter)
  buffer.applyTag(tag, startIter, endIter)
  buffer.applyTagByName($id, startIter, endIter)

proc checkCb(action: gio.SimpleAction; parameter: glib.Variant; app: gtk4.Application) =
  if nsProcess.isNil: return
  var ln, cn: int
  var nerrors, nwarnings: int
  let win = NedWindow(getActiveWindow(app))
  #let win = (getActiveWindow(app))
  let h = ScrolledWindow(win.getChild)
  let view = NimView(h.getChild)
  let buffer = view.getbuffer
  if not win.filePath.endsWith(".nim"):
    #showmsg(win, "File is still unsaved or has no .nim suffix -- action ignored.")
    return
  let startIter = buffer.getStartIter
  let endIter = buffer.getEndIter
  removeMarks(view)
  view.errors.setLen(0)
  let text = buffer.getText(startIter, endIter, includeHiddenChars = true)
  let dirtypath = saveDirty(win.filepath, text)
  if dirtyPath.len == 0: return
  var line = newStringOfCap(240)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  socket.send("chk " & win.filePath & ";" & dirtypath & ":1:1\c\L")
  var last: string
  var com, sk, sym, sig, path, lin, col, doc, percent: string
  while true:
    var isError: bool
    socket.readLine(line)
    if line.len == 0:
      break
    if line == "\c\l":
      echo "\c\l"
      continue
    if line == last:
      # echo "line == last" # occurs!
      continue
    #if line == "\c\l" or line == last: continue
    (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t') # sym is empty
    #echo com, sk, sym, sig, path, lin, col, doc, percent
    if path != win.filePath: continue
    if doc[0] == '"':
      # echo "quoted doc" # occurs
      doc = doc[1 .. ^2]
    # echo "find \\'", doc.find("\\'") # occurs
    doc = doc.replace("\\'", "'")
    # echo "find \\x0A", doc.find("\\x0A") # occurs
    doc = doc.replace("\\x0A", "\n")
    #log(win, line, LogLevel.debug)
    var show: bool
    if sig == "Error":
      isError = true
      show = true
    else:
      if  nwarnings > MaxErrorTags div 2: continue
      isError = false
      show = sig == "Hint" or sig == "Warning"
    if show:
      last = line
      cn = col.parseInt
      ln = lin.parseInt
      if cn < 0 or ln <= 0:
        echo "cn < 0 or ln < 0" # should really not occur
        continue
      ln -= 1
      var id = view.addError(doc, ln, cn)
      if id > 0:
        if isError:
          inc(nerrors)
          setErrorMark(view, ln, cn)
          if nerrors == 1:
            #buffer.signalHandlerBlock(buffer.handlerID) # without showmsg() is overwritten
            jumpto(view, ln, cn)
            discard
            #buffer.signalHandlerUnblock(buffer.handlerID)
        else:
          inc(nwarnings)
        setErrorTag(view, ln, cn, id)
  socket.close
  view.setShowLinemarks(nerrors > 0)
  dirtypath.removeFile
  #showmsg(win, "Errors: " & $nerrors & ", Hints/Warnings: " & $nwarnings)

proc showErrorTooltip(view: NimView; x, y: int; keyboardMode: bool; tooltip: Tooltip): bool =
  var bx, by, trailing: int
  var iter: TextIter
  if keyboardMode: return false
  view.windowToBufferCoords(TextWindowType.widget, x, y, bx, by)
  let table: TextTagTable = view.buffer.tagTable
  var tag: TextTag = table.lookup(ErrorTagName)
  assert(tag != nil)
  discard view.getIterAtPosition(iter, trailing, bx, by)
  if iter.hasTag(tag):
    for e in view.errors:
      tag = table.lookup($e.id)
      if tag != nil:
        if iter.hasTag(tag):
          tooltip.text = e.gs
          return true
  return false

proc toIntVal(i: int): Value =
  let gtype = typeFromName("gint")
  discard init(result, gtype)
  setInt(result, i)


# create the GUI. Currently only one single text window
proc activateOrOpen(app: Application) =
  let window: NedWindow = newApplicationWindow(NedWindow, app)
  window.title = "Plain GTK4 Nim Editor"
  window.defaultSize = (800, 600)
  let scrolledWindow = newScrolledWindow()
  let buffer = newBuffer()
  let view: NimView = newViewWithBuffer(NimView, buffer)
  setErrorAttr(view)
  let tt = newTextTag(ErrorTagName)
  tt.setProperty("underline", toIntVal(pango.Underline.error.ord))
  discard add(buffer.getTagTable, tt)
  for i in 0 .. MaxErrorTags:
    discard add(buffer.getTagTable, newTextTag($i))
  let menubutton = newMenuButton()
  let actionGroup: gio.SimpleActionGroup = newSimpleActionGroup()
  var action: SimpleAction
  action = newSimpleAction("safe-as")
  discard action.connect("activate", saveAsCb, window)
  actionGroup.addAction(action)
  action = newSimpleAction("check")
  action.connect("activate", checkCb, app)
  setAccelsForAction(app, "win.check", "<Control>E")
  actionGroup.addAction(action)
  connect(view, "query-tooltip", showErrorTooltip)
  let header = newHeaderBar() 
  window.setTitlebar(header)
  let fileOpenButton = newButton("Open")
  let fileSaveButton = newButton("Save")
  fileSaveButton.connect("clicked", saveFile, window)
  header.packStart(fileOpenButton)
  header.packEnd(fileSaveButton)
  window.insertActionGroup("win", actionGroup)
  var builder = newBuilderFromString(menuData)
  var menuModel: gio.MenuModel = builder.getMenuModel("menuModel")
  var menu = newPopoverMenuFromModel(menuModel)
  menuButton.setPopover(menu)
  menuButton.setIconName("open-menu-symbolic") 
  header.packEnd(menuButton) 
  let cssProvider = newCssProvider()
  let data = "textview {font-size: 16pt;}"
  cssProvider.loadFromData(data)
  let styleContext = view.getStyleContext
  assert styleContext != nil
  addProvider(styleContext, cssProvider, STYLE_PROVIDER_PRIORITY_USER)
  window.setChild(scrolledWindow)
  scrolledWindow.setChild(view)
  show(window)

# set up and initialize the application
proc startup(app: Application) =
  echo "startup"
  activateOrOpen(app)

# program launch without file arguments, so open a default initial window
proc activate(app: Application) =
  let window: NedWindow = NedWindow(app.getActiveWindow)
  assert(window != nil)
  let h = ScrolledWindow(window.getChild)
  let view: NimView = NimView(h.getChild)
  let buffer: Buffer = Buffer(view.getBuffer)
  window.setTitle("New Document")
  window.buffer = buffer
  window.filePath = ""

# launch with file arguments, display file content
proc open(app: Application; files: seq[GFile]; hint: string) =
  var
    contents: string
    etagOut: string
    length: uint64

  let window: NedWindow = NedWindow(app.getActiveWindow)
  assert(window != nil)
  let h = ScrolledWindow(window.getChild)
  let view: NimView = NimView(h.getChild)
  let buffer: Buffer = Buffer(view.getBuffer)
  if files.len > 0:
    window.gfile = files[0]
    if loadContents(files[0], cancellable = nil, contents, length, etagOut):
      assert length.int == contents.len
      var langManager = getDefaultLanguageManager()
      var styleManager = getDefaultStyleSchemeManager()
      # stylemanager.appendSearchPath("/home/salewski/gtksourceview/data/styles")
      var scheme = stylemanager.getScheme("nimdark1")
      # var langPath = langManager.searchPath
      # langPath.add("/home/salewski/gtksourceview/data/language-specs/")
      # langManager.setSearchPath(langPath)
      var lang = guessLanguage(langManager, files[0].path, nil)
      window.setTitle(files[0].path.extractFilename)
      window.buffer = buffer
      window.filePath = files[0].path
      setLanguage(buffer, lang)
      buffer.setHighlightSyntax
      buffer.setStyleScheme(scheme)
      buffer.setText(contents, contents.len)
      initSuggest(window, window.filePath)

proc commandLine(app: Application; cl: ApplicationCommandLine): int =
  echo "command-line"

# TextCharPredicate* = proc (ch: gunichar; userData: pointer): gboolean {.cdecl.}

proc main =
  let app = newApplication("org.gtk.example", {ApplicationFlag.handlesOpen})#, handlesCommandLine})
  app.connect("startup", startup)
  app.connect("activate", activate)
  app.connect("command-line", commandLine)
  # app.connect("handle_local_options", handleLocalOptions)
  app.connect("open", open)
  app.connect("name-lost", nameLost)
  app.connect("shutdown", shutdown)
  let argLen = paramCount() + 1
  var argStr = newSeq[string](argLen)
  for i in 0 ..< argLen:
    argStr[i] = paramStr(i)
  discard run(app, argLen, argStr) # we have to pass an argString to support open signal handling files setProperty setErrorTag tag add

main()
# 450 lines
