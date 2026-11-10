#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Bookmark window (#Include by Translator.ahk; opened from the tray menu "Bookmarks…")
; Top: bookmark dropdown + New / Rename / Delete bookmark / Set as default; search box + Select all;
; List: multi-select checkbox on the left, original text, yellow star on the right (click → unfavorite after confirmation); double-click a row = re-translate with the current engine;
; Bottom: Move to… / Delete (applies to the checked rows, both require confirmation). Data is described in Bookmarks.ahk.
;=====================================================================

global bmGui := 0, bmDdl := 0, bmSearch := 0, bmAll := 0, bmLv := 0
global bmCountTxt := 0, bmBtnMove := 0, bmBtnDel := 0, bmBtnRename := 0, bmBtnDelList := 0, bmBtnDefault := 0
global bmCur := ""            ; name of the bookmark currently shown
global bmRows := []           ; original texts, one per list row
global uiModal := false       ; true while a confirm box or menu is open; clicks do not close the translation popup in this state

; options for the confirm/notice boxes: owned by the bookmark window, centered over it
BmOpts() {
    global bmGui
    return Map("owner", bmGui != 0 ? bmGui.Hwnd : 0)
}
BmFail(heading, msg) => Notice(Tr("bm.title"), heading, msg, BmOpts())

ShowBookmarks(*) {
    global bmGui, bmDdl, bmSearch, bmAll, bmLv, bmCountTxt, bmBtnMove, bmBtnDel
    global bmBtnRename, bmBtnDelList, bmBtnDefault, bmCur, bm
    if (bmGui != 0) {
        bmGui.Show()
        WinActivate("ahk_id " . bmGui.Hwnd)
        return
    }
    bmCur := bm["default"]
    local g := Gui("+AlwaysOnTop +OwnDialogs", Tr("bm.title"))
    g.MarginX := 14, g.MarginY := 12
    g.SetFont("s10", "Microsoft YaHei")

    g.Add("Text", "x14 y16 w76", Tr("bm.title"))
    bmDdl := g.Add("DropDownList", "x92 y12 w150")
    bmDdl.OnEvent("Change", (*) => BmOnPickList())
    g.SetFont("s9")
    g.Add("Button", "x246 y11 w52 h28", Tr("bm.new")).OnEvent("Click", (*) => BmDoNew())
    bmBtnRename := g.Add("Button", "x302 y11 w66 h28", Tr("bm.rename"))
    bmBtnRename.OnEvent("Click", (*) => BmDoRename())
    bmBtnDelList := g.Add("Button", "x372 y11 w92 h28", Tr("bm.delete_list"))
    bmBtnDelList.OnEvent("Click", (*) => BmDoDeleteList())
    bmBtnDefault := g.Add("Button", "x468 y11 w86 h28", Tr("bm.set_default"))
    bmBtnDefault.OnEvent("Click", (*) => BmDoSetDefault())
    g.SetFont("s10")

    bmAll := g.Add("CheckBox", "x14 y52 w70 h26", Tr("bm.select_all"))
    bmAll.OnEvent("Click", (ctl, *) => BmSelectAll(ctl.Value))
    bmSearch := g.Add("Edit", "x92 y50 w462 h28")
    SendMessage(0x1501, 1, StrPtr(Tr("bm.search")), bmSearch)      ; EM_SETCUEBANNER
    bmSearch.OnEvent("Change", (*) => BmRefresh())

    bmLv := g.Add("ListView", "x14 y86 w540 r11 Checked -Hdr -Multi", [Tr("popup.source"), "★"])
    bmLv.ModifyCol(1, 472)
    bmLv.ModifyCol(2, 40)
    ; Note: do not register ItemCheck / ItemSelect events on this ListView; once registered, NM_CLICK and DoubleClick are no longer received
    ; (verified by testing). The checked count is synced by the 150 ms polling below instead.
    bmLv.OnEvent("DoubleClick", (*) => BmOnDoubleClick())
    bmLv.OnNotify(-2, BmOnClick)                             ; NM_CLICK: check whether the click landed on the star column
    bmLv.OnNotify(-12, BmOnCustomDraw)                       ; NM_CUSTOMDRAW: paint the star column yellow

    g.SetFont("s9 c808080")
    bmCountTxt := g.Add("Text", "x14 y+12 w150 h24 +0x200", "")
    g.SetFont("s9 cDefault")
    bmBtnMove := g.Add("Button", "x312 yp-3 w100 h28", Tr("bm.move_to"))
    bmBtnMove.OnEvent("Click", (*) => BmDoMove())
    bmBtnDel := g.Add("Button", "x416 yp w66 h28", Tr("bm.delete"))
    bmBtnDel.OnEvent("Click", (*) => BmDoDelete())
    g.Add("Button", "x486 yp w68 h28", Tr("bm.close")).OnEvent("Click", (*) => CloseBookmarks())
    g.SetFont("s10 cDefault")
    g.OnEvent("Close", (*) => CloseBookmarks())
    g.OnEvent("Escape", (*) => CloseBookmarks())
    bmGui := g
    BmRefresh()
    SetTimer(BmPoll, 150)

    ; Show horizontally centered, slightly above middle of the current screen (the right side is kept for the re-translation result popup)
    g.Show("x-2400 y-2400 w568")
    g.GetPos(, , &gw, &gh)
    local mx, my
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    GetWorkArea(mx, my, &L, &T, &R, &B)
    local sc := A_ScreenDPI / 96.0
    local wl := Round((R - L) / sc), hl := Round((B - T) / sc)
    g.Move(Round(L / sc) + Max(20, (wl - gw) // 3), Round(T / sc) + Max(20, (hl - gh) // 4))
    loop 6 {
        WinActivate("ahk_id " . g.Hwnd)
        if WinActive("ahk_id " . g.Hwnd)
            break
        Sleep(50)
    }
}

CloseBookmarks() {
    global bmGui, forceAnchor, pinned
    if (bmGui = 0)
        return
    SetTimer(BmPoll, 0)
    try bmGui.Destroy()
    bmGui := 0
    forceAnchor := false
    if !pinned
        DestroyGui()
}

; Called after data changes from various places: refreshes the stars on the translation popup and the bookmark window (if open)
BmRefreshUI() {
    global bmGui
    RefreshStar()
    if (bmGui != 0)
        BmRefresh()
}

BmListLabel(l) => BmDisplayName(l["name"]) . (l["name"] = bm["default"] ? Tr("bm.default_suffix") : "")

; Refill the dropdown and list (keeps the current bookmark and search text)
BmRefresh() {
    global bm, bmGui, bmDdl, bmSearch, bmLv, bmRows, bmCur, bmBtnRename, bmBtnDelList, bmBtnDefault, BM_BUILTIN
    if (bmGui = 0)
        return
    if !BmFindList(bmCur)
        bmCur := bm["default"]
    local names := [], pick := 1
    for i, l in bm["lists"] {
        names.Push(BmListLabel(l))
        if (l["name"] = bmCur)
            pick := i
    }
    bmDdl.Delete()
    bmDdl.Add(names)
    bmDdl.Choose(pick)

    bmLv.Opt("-Redraw")
    bmLv.Delete()
    bmRows := []
    local q := Trim(bmSearch.Value), items := BmFindList(bmCur)["items"]
    local k := items.Length
    while (k >= 1) {                                   ; most recently favorited first
        local t := items[k]["text"]
        if (q = "" || InStr(t, q)) {
            bmLv.Add("", RegExReplace(t, "\s+", " "), "★")
            bmRows.Push(t)
        }
        k -= 1
    }
    bmLv.Opt("+Redraw")
    bmBtnRename.Enabled := (bmCur != BM_BUILTIN)
    bmBtnDelList.Enabled := (bmCur != BM_BUILTIN)
    bmBtnDefault.Enabled := (bmCur != bm["default"])
    bmGui.Title := Tr("bm.window_title", BmDisplayName(bmCur), items.Length)
    BmUpdateSel()
}

; Polling: when the checked state changes, update "N selected", button enabled states, and the select-all box
global bmPollSig := ""
BmPoll() {
    global bmGui, bmLv, bmPollSig
    if (bmGui = 0)
        return
    local sig := "", row := 0
    while (row := bmLv.GetNext(row, "Checked"))
        sig .= row . ","
    if (sig != bmPollSig) {
        bmPollSig := sig
        BmUpdateSel()
    }
}

BmOnPickList() {
    global bm, bmDdl, bmCur
    if (bmDdl.Value >= 1 && bmDdl.Value <= bm["lists"].Length) {
        bmCur := bm["lists"][bmDdl.Value]["name"]
        BmRefresh()
    }
}

BmCheckedTexts() {
    global bmLv, bmRows
    local out := [], row := 0
    while (row := bmLv.GetNext(row, "Checked"))
        out.Push(bmRows[row])
    return out
}

BmUpdateSel() {
    global bmLv, bmCountTxt, bmBtnMove, bmBtnDel, bmAll
    local n := BmCheckedTexts().Length, total := bmLv.GetCount()
    bmCountTxt.Text := n ? Tr("bm.selected", n) : Tr("bm.total", total)
    bmBtnMove.Enabled := n > 0
    bmBtnDel.Enabled := n > 0
    bmAll.Value := (total > 0 && n = total) ? 1 : 0
}

BmSelectAll(on) {
    global bmLv
    bmLv.Modify(0, on ? "+Check" : "-Check")
    BmUpdateSel()
}

; row / column under the cursor (0-based) / whether the click is on the checkbox
BmHit(&row, &col, &onCheck) {
    global bmLv
    local pt := Buffer(8), hti := Buffer(24, 0)
    DllCall("GetCursorPos", "ptr", pt)
    DllCall("ScreenToClient", "ptr", bmLv.Hwnd, "ptr", pt)
    NumPut("Int", NumGet(pt, 0, "Int"), hti, 0)
    NumPut("Int", NumGet(pt, 4, "Int"), hti, 4)
    SendMessage(0x1039, 0, hti, bmLv)                  ; LVM_SUBITEMHITTEST
    row := NumGet(hti, 12, "Int") + 1
    col := NumGet(hti, 16, "Int")
    onCheck := (NumGet(hti, 8, "UInt") & 0x8) != 0     ; LVHT_ONITEMSTATEICON
    if (row < 1)
        row := 0
}

BmOnClick(ctrl, lParam) {
    local row, col, onCheck
    BmHit(&row, &col, &onCheck)
    if (row && col = 1 && !onCheck)
        SetTimer(() => BmStarClicked(row), -1)          ; a confirm box cannot be shown inside the notify callback
}

BmOnDoubleClick() {
    local row, col, onCheck
    BmHit(&row, &col, &onCheck)
    if (row && col = 0 && !onCheck)
        BmRetranslate(row)
}

; paint the star column gold-yellow
BmOnCustomDraw(ctrl, lParam) {
    local stage := NumGet(lParam, 24, "UInt")
    if (stage = 0x1)                    ; CDDS_PREPAINT
        return 0x20                     ; CDRF_NOTIFYITEMDRAW
    if (stage = 0x10001)                ; CDDS_ITEMPREPAINT
        return 0x20                     ; CDRF_NOTIFYSUBITEMDRAW
    if (stage = 0x30001 && NumGet(lParam, 88, "Int") = 1) {   ; sub-item prepaint, column 2
        NumPut("UInt", 0x0007C1FF, lParam, 80)                ; clrText = RGB(255,193,7)
        return 0x2                      ; CDRF_NEWFONT
    }
    return 0
}

BmStarClicked(row) {
    global bmRows, bmCur
    if (row > bmRows.Length)
        return
    local text := bmRows[row]
    if !Confirm(Tr("bm.unmark.title"), Tr("bm.unmark.heading"), Tr("bm.unmark.msg", BmDisplayName(bmCur)), "", Tr("bm.unmark.title"), true, BmOpts())
        return
    try BmRemove(text)
    catch as e
        BmFail(Tr("bm.err.save"), e.Message)
    BmRefreshUI()
}

; re-translate with the current engine; the result popup appears to the right of the bookmark window (the stars are now yellow)
BmRetranslate(row) {
    global bmRows, bmGui, busy, cfg, selX, selY, lastFg, forceAnchor
    if (busy || row > bmRows.Length)
        return
    local plan := InputPlan(bmRows[row])
    if !plan
        return
    local x, y, w, h, sc := A_ScreenDPI / 96.0, off := Round(15 * A_ScreenDPI / 96.0)
    WinGetPos(&x, &y, &w, &h, "ahk_id " . bmGui.Hwnd)
    selX := x + w - off + Round(6 * sc)
    selY := y - off + Round(30 * sc)
    forceAnchor := true
    lastFg := bmGui.Hwnd
    local hint := "", m := Integer(cfg["max_chars"])
    if (StrLen(plan["text"]) > m) {
        hint := Tr("hint.truncated", m)
        plan["text"] := SubStr(plan["text"], 1, m)
    }
    StartTranslate(plan["engine"], plan["text"], plan["isWord"], hint, plan["tgt"])
}

BmDoDelete() {
    global bmCur
    local texts := BmCheckedTexts()
    if !texts.Length
        return
    if !Confirm(Tr("bm.delete"), Tr("bm.delete_items.heading", texts.Length), Tr("bm.delete_items.msg", BmDisplayName(bmCur)), "", Tr("bm.delete"), true, BmOpts())
        return
    try BmRemoveMany(texts)
    catch as e
        BmFail(Tr("bm.err.save"), e.Message)
    BmRefreshUI()
}

BmDoMove() {
    global bm, bmCur, uiModal
    local texts := BmCheckedTexts()
    if !texts.Length
        return
    local pickMenu := Menu()
    for l in bm["lists"] {
        if (l["name"] = bmCur)
            continue
        pickMenu.Add(StrReplace(BmListLabel(l), "&", "&&"), BmPickTarget.Bind(l["name"], texts))
    }
    pickMenu.Add()
    pickMenu.Add(Tr("bm.new_list_menu"), BmPickTarget.Bind("", texts))
    uiModal := true
    pickMenu.Show()
    uiModal := false
}

BmPickTarget(name, texts, *) {
    global bmCur
    if (name = "") {
        name := AskName(Tr("bm.new_list"), Tr("bm.new_list"), Tr("bm.name_prompt"), "", (t) => BmNameError(t), BmOpts())
        if (name = "")
            return
        try BmNewList(name)
        catch as e {
            BmFail(Tr("bm.err.new"), e.Message)
            return
        }
    }
    if !Confirm(Tr("bm.move"), Tr("bm.move.heading", texts.Length), Tr("bm.move.msg", BmDisplayName(bmCur), BmDisplayName(name)), "", Tr("bm.move"), false, BmOpts())
        return
    try BmMove(texts, name)
    catch as e
        BmFail(Tr("bm.err.move"), e.Message)
    BmRefreshUI()
}

BmDoNew() {
    global bmCur
    local name := AskName(Tr("bm.new_list"), Tr("bm.new_list"), Tr("bm.name_prompt"), "", (t) => BmNameError(t), BmOpts())
    if (name = "")
        return
    try {
        BmNewList(name)
        bmCur := name
    } catch as e
        BmFail(Tr("bm.err.new"), e.Message)
    BmRefreshUI()
}

BmDoRename() {
    global bmCur
    local cur := bmCur
    local name := AskName(Tr("bm.rename_title"), Tr("bm.rename.heading", BmDisplayName(cur)), Tr("bm.rename.prompt"), cur, (t) => BmNameError(t, cur), BmOpts())
    if (name = "" || name = cur)
        return
    try {
        BmRenameList(cur, name)
        bmCur := name
    } catch as e
        BmFail(Tr("bm.err.rename"), e.Message)
    BmRefreshUI()
}

BmDoSetDefault() {
    global bmCur
    try BmSetDefault(bmCur)
    catch as e
        BmFail(Tr("bm.err.set_default"), e.Message)
    BmRefreshUI()
}

BmDoDeleteList() {
    global bmCur, bm
    local l := BmFindList(bmCur)
    if !l
        return
    local n := l["items"].Length, moveIt := false
    if (n = 0) {
        if !Confirm(Tr("bm.delete_list"), Tr("bm.delete_list.heading", BmDisplayName(bmCur)), Tr("bm.delete_list.empty"), "", Tr("bm.delete"), true, BmOpts())
            return
    } else {
        local opts := BmOpts()
        opts["kind"] := "danger"
        local r := Ask(Tr("bm.delete_list"), Tr("bm.delete_list.heading", BmDisplayName(bmCur)), Tr("bm.delete_list.has_items", n), "",
            [Map("text", Tr("dlg.cancel"), "kind", "normal", "value", "", "default", 1),
             Map("text", Tr("bm.delete_list.merge"), "kind", "primary", "value", "move"),
             Map("text", Tr("bm.delete_list.with_items"), "kind", "danger", "value", "del")], opts)
        if (r = "")
            return
        moveIt := (r = "move")
    }
    try {
        BmDeleteList(bmCur, moveIt)
        bmCur := bm["default"]
    } catch as e
        BmFail(Tr("bm.err.delete_list"), e.Message)
    BmRefreshUI()
}

; point inside the bookmark window (including child controls)
PointInBm(x, y) {
    global bmGui
    return bmGui != 0 && TopLevelAt(x, y) = bmGui.Hwnd
}
