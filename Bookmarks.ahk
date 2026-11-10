#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Bookmark (favorites) data layer (#Include by Translator.ahk; UI is in BookmarkWin.ahk)
; Only the original text is favorited: clicking the star in the translation popup puts the original text into the default bookmark; each original text belongs to exactly one bookmark.
; Stored as bookmarks.json in the project folder (personal data, not tracked by git):
;   {"version":1,"default":"默认收藏","lists":[{"name":"默认收藏","items":[{"text":"apple","ts":"20260930231900"}]}]}
; Writing: write to .tmp first, then replace, keeping the previous copy as .bak; a corrupted file found on load is renamed and kept (.corrupt-timestamp), and the data starts empty again.
;=====================================================================

global BM_BUILTIN := "默认收藏"            ; built-in bookmark: cannot be deleted or renamed
global bm := 0                            ; Map("default", name, "lists", [Map("name", name, "items", [Map("text", …, "ts", …)])])
global bmFile := ""                       ; test-only: overrides the file path
global bmLoadNote := ""                   ; message shown on load (e.g. a corrupted file was renamed), displayed by the UI layer

BmPath() {
    global bmFile
    if (bmFile != "")
        return bmFile
    local env := EnvGet("SELTR_BOOKMARKS")   ; for end-to-end tests, to avoid touching real data
    if (env != "")
        return env
    local dir := AppDir()
    return dir . "\bookmarks.json"
}

; The built-in bookmark is always named BM_BUILTIN in the file (kept for compatibility with old data); the UI shows it in the current language
BmDisplayName(name) => (name = BM_BUILTIN) ? Tr("bm.builtin") : name

BmEmpty() =>Map("default", BM_BUILTIN, "lists", [Map("name", BM_BUILTIN, "items", [])])

; Normalize: ignore case, trim leading/trailing whitespace, collapse runs of whitespace into one space
BmKey(text) => StrLower(Trim(RegExReplace(text, "\s+", " ")))

BmLoad() {
    global bm, bmLoadNote
    bmLoadNote := ""
    local path := BmPath()
    bm := BmEmpty()
    if !FileExist(path)
        return
    try {
        local data := JsonParse(FileRead(path, "UTF-8"))
        bm := BmValidate(data)
    } catch as e {
        local bak := path . ".corrupt-" . A_Now
        try FileMove(path, bak, 1)
        bmLoadNote := Tr("bm.err.load_note", e.Message, bak, path . ".bak")
        bm := BmEmpty()
    }
}

; Check structure and normalize: the built-in bookmark must exist (placed first), names must be unique, the default bookmark must be valid, original texts must be globally unique
BmValidate(data) {
    global BM_BUILTIN
    if !(data is Map) || !data.Has("lists") || !(data["lists"] is Array)
        throw Error(Tr("bm.err.bad_structure"))
    local out := BmEmpty()
    local seenName := Map(BM_BUILTIN, out["lists"][1]), seenKey := Map()
    for l in data["lists"] {
        if !(l is Map) || !l.Has("name") || !l.Has("items") || !(l["items"] is Array)
            throw Error(Tr("bm.err.bad_list"))
        local name := String(l["name"])
        local target := seenName.Has(name) ? seenName[name] : 0
        if !target {
            target := Map("name", name, "items", [])
            out["lists"].Push(target)
            seenName[name] := target
        }
        for it in l["items"] {
            if !(it is Map) || !it.Has("text")
                throw Error(Tr("bm.err.bad_item"))
            local text := String(it["text"])
            local k := BmKey(text)
            if (k = "" || seenKey.Has(k))
                continue
            seenKey[k] := true
            target["items"].Push(Map("text", text, "ts", it.Has("ts") ? String(it["ts"]) : ""))
        }
    }
    local def := data.Has("default") ? String(data["default"]) : BM_BUILTIN
    out["default"] := seenName.Has(def) ? def : BM_BUILTIN
    return out
}

BmSave() {
    global bm
    local path := BmPath()
    local s := '{"version":1,"default":' . JsonStr(bm["default"]) . ',"lists":['
    for i, l in bm["lists"] {
        s .= (i > 1 ? ",`n" : "`n") . ' {"name":' . JsonStr(l["name"]) . ',"items":['
        for j, it in l["items"]
            s .= (j > 1 ? ",`n" : "`n") . '  {"text":' . JsonStr(it["text"]) . ',"ts":' . JsonStr(it["ts"]) . '}'
        s .= (l["items"].Length ? "`n " : "") . ']}'
    }
    s .= "`n]}`n"
    local tmp := path . ".tmp"
    local f := FileOpen(tmp, "w", "UTF-8-RAW")
    if !f
        throw Error(Tr("bm.err.write", tmp))
    f.Write(s)
    f.Close()
    if FileExist(path)
        try FileCopy(path, path . ".bak", 1)
    FileMove(tmp, path, 1)
}

BmFindList(name) {
    global bm
    for l in bm["lists"]
        if (l["name"] = name)
            return l
    return 0
}

; Returns Map("list", bookmark, "index", position, "item", entry); returns 0 if not favorited
BmFind(text) {
    global bm
    local k := BmKey(text)
    if (k = "")
        return 0
    for l in bm["lists"]
        for i, it in l["items"]
            if (BmKey(it["text"]) = k)
                return Map("list", l, "index", i, "item", it)
    return 0
}

BmIsMarked(text) => BmFind(text) != 0

; Favorite into the given bookmark (default = default bookmark). Does not add duplicates; returns false if already favorited
BmAdd(text, listName := "") {
    global bm
    text := Trim(text, " `t`r`n")
    if (text = "" || BmIsMarked(text))
        return false
    local l := BmFindList(listName != "" ? listName : bm["default"])
    if !l
        l := BmFindList(bm["default"])
    l["items"].Push(Map("text", text, "ts", A_Now))
    BmSave()
    return true
}

BmRemove(text) {
    local f := BmFind(text)
    if !f
        return false
    f["list"]["items"].RemoveAt(f["index"])
    BmSave()
    return true
}

; Move several original texts (an array) to the target bookmark; returns the number actually moved
BmMove(texts, targetName) {
    local target := BmFindList(targetName)
    if !target
        throw Error(Tr("bm.err.not_found", BmDisplayName(targetName)))
    local n := 0
    for t in texts {
        local f := BmFind(t)
        if (!f || f["list"] = target)
            continue
        f["list"]["items"].RemoveAt(f["index"])
        target["items"].Push(f["item"])
        n += 1
    }
    if n
        BmSave()
    return n
}

BmRemoveMany(texts) {
    local n := 0
    for t in texts {
        local f := BmFind(t)
        if !f
            continue
        f["list"]["items"].RemoveAt(f["index"])
        n += 1
    }
    if n
        BmSave()
    return n
}

; Name check: returns an error message, or "" if valid
BmNameError(name, except := "") {
    name := Trim(name)
    if (name = "")
        return Tr("bm.err.name_empty")
    if (StrLen(name) > 30)
        return Tr("bm.err.name_long")
    local l := BmFindList(name)
    if (l && name != except)
        return Tr("bm.err.name_exists", name)
    return ""
}

BmNewList(name) {
    global bm
    name := Trim(name)
    local err := BmNameError(name)
    if (err != "")
        throw Error(err)
    bm["lists"].Push(Map("name", name, "items", []))
    BmSave()
}

BmRenameList(old, new) {
    global bm, BM_BUILTIN
    new := Trim(new)
    if (old = BM_BUILTIN)
        throw Error(Tr("bm.err.builtin_rename", BmDisplayName(BM_BUILTIN)))
    local err := BmNameError(new, old)
    if (err != "")
        throw Error(err)
    local l := BmFindList(old)
    if !l
        throw Error(Tr("bm.err.not_found", BmDisplayName(old)))
    l["name"] := new
    if (bm["default"] = old)
        bm["default"] := new
    BmSave()
}

; Delete a bookmark; if moveToDefault is true, its contents are merged into the built-in bookmark, otherwise they are deleted with it
BmDeleteList(name, moveToDefault) {
    global bm, BM_BUILTIN
    if (name = BM_BUILTIN)
        throw Error(Tr("bm.err.builtin_delete", BmDisplayName(BM_BUILTIN)))
    local l := BmFindList(name)
    if !l
        throw Error(Tr("bm.err.not_found", BmDisplayName(name)))
    if moveToDefault {
        local dst := BmFindList(BM_BUILTIN)
        for it in l["items"]
            dst["items"].Push(it)
    }
    for i, x in bm["lists"]
        if (x = l) {
            bm["lists"].RemoveAt(i)
            break
        }
    if (bm["default"] = name)
        bm["default"] := BM_BUILTIN
    BmSave()
}

BmSetDefault(name) {
    global bm
    if !BmFindList(name)
        throw Error(Tr("bm.err.not_found", BmDisplayName(name)))
    bm["default"] := name
    BmSave()
}

BmCount() {
    global bm
    local n := 0
    for l in bm["lists"]
        n += l["items"].Length
    return n
}
