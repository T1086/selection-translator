#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Unified-style confirm / notice / input windows (#Include by Translator.ahk; replace the system MsgBox / InputBox)
;   Ask(...)      general: top color bar + title + description + item preview + a row of buttons; returns the value of the clicked button (Esc / close = "")
;   Confirm(...)  two buttons: Cancel / Confirm (dangerous actions in red, others in blue); returns whether confirmed
;   Notice(...)   a single "OK" button, used to show errors
;   AskName(...)  enter a line of text (e.g. a bookmark name) with validation; returns the text, or "" on cancel
; Opened from the bookmark window: the dialog is centered over it, owned by it (always stays on top of it), and locks it until closed;
; opened from the translation popup: centered over the popup (the popup does not take focus, so it cannot be an owner).
;=====================================================================

global askDone := false, askResult := ""
global ASK_DANGER := "D9534F", ASK_PRIMARY := "5489C8"

; buttons: [Map("text", display text, "kind", "danger"|"primary"|"normal", "value", return value, "default", 1)]
; opts: Map("owner", bookmark window handle, "center", reference window handle to center on, "kind", color bar type,
;           "input", initial text (shows an input box if present), "validate", validation function(text) → error message or "")
Ask(title, heading, msg := "", items := "", buttons := "", opts := "") {
    global askDone, askResult, uiModal, ASK_DANGER, ASK_PRIMARY
    if !IsObject(items)
        items := []
    if !IsObject(opts)
        opts := Map()
    if !IsObject(buttons)
        buttons := [Map("text", Tr("dlg.ok"), "kind", "primary", "value", "ok", "default", 1)]
    local owner := opts.Has("owner") ? opts["owner"] : 0
    local center := opts.Has("center") ? opts["center"] : owner
    local accent := (opts.Has("kind") && opts["kind"] = "danger") ? ASK_DANGER : ASK_PRIMARY
    local hasInput := opts.Has("input")

    local g := Gui("+AlwaysOnTop +ToolWindow" . (owner ? " +Owner" . owner : ""), title)
    g.MarginX := 20, g.MarginY := 20
    g.SetFont("s10", "Microsoft YaHei")
    g.Add("Text", "x0 y0 w380 h5 Background" . accent, "")
    g.SetFont("s12 bold c222222")
    g.Add("Text", "x20 y22 w340", heading)
    if (msg != "") {
        g.SetFont("s10 norm c555555")
        g.Add("Text", "x20 y+8 w340", msg)
    }
    if (items.Length) {
        local txt := "", shown := Min(items.Length, 5)
        loop shown
            txt .= (A_Index > 1 ? "`n" : "") . "  " . AskShort(items[A_Index])
        if (items.Length > shown)
            txt .= "`n  " . Tr("dlg.more_items", items.Length - shown)
        g.SetFont("s9 norm c333333")
        g.Add("Text", "x20 y+12 w340 BackgroundF2F2F2", " `n" . txt . "`n ")      ; one blank line of padding at top and bottom
    }
    local edt := 0, errLbl := 0
    if hasInput {
        g.SetFont("s10 norm cDefault")
        edt := g.Add("Edit", "x20 y+12 w340", opts["input"])
        g.SetFont("s9 norm cD9534F")
        errLbl := g.Add("Text", "x20 y+4 w340 h18", "")
    }

    ; Buttons are right-aligned at the bottom; Text controls act as buttons so they can have red / blue backgrounds
    g.SetFont("s10 norm")
    local gap := 10, n := buttons.Length
    ; button width grows with the longest button text (English is longer than Chinese), but all three buttons must fit in the 340-pixel content area
    local maxLen := 0
    for b in buttons
        maxLen := Max(maxLen, StrLen(b["text"]))
    local bw := Min(Max(100, maxLen * 9 + 20), (340 - gap * (n - 1)) // n)
    local x0 := 380 - 20 - n * bw - (n - 1) * gap
    local defVal := ""
    for i, b in buttons {
        local kind := b.Has("kind") ? b["kind"] : "normal"
        local bg := kind = "danger" ? ASK_DANGER : kind = "primary" ? ASK_PRIMARY : "E6E6E6"
        local fg := kind = "normal" ? "333333" : "FFFFFF"
        local pos := (i = 1) ? "x" . x0 . " y+18" : "x+" . gap . " yp"
        local t := g.Add("Text", pos . " w" . bw . " h32 Center +0x200 Background" . bg . " c" . fg, b["text"])
        t.OnEvent("Click", AskPick.Bind(b["value"], opts, edt, errLbl))
        if (b.Has("default") && b["default"])
            defVal := b["value"]
    }
    ; invisible default button: lets Enter trigger the default action
    g.Add("Button", "x-200 y-200 w1 h1 Default").OnEvent("Click", AskPick.Bind(defVal, opts, edt, errLbl))
    g.OnEvent("Escape", AskPick.Bind("", opts, edt, errLbl))
    g.OnEvent("Close", AskPick.Bind("", opts, edt, errLbl))

    askDone := false, askResult := ""
    local savedModal := uiModal
    uiModal := true
    g.Show("x-2400 y-2400 w380")
    AskCenter(g, center)
    if owner
        try WinSetEnabled(false, "ahk_id " . owner)
    g.Show()
    loop 6 {
        WinActivate("ahk_id " . g.Hwnd)
        if WinActive("ahk_id " . g.Hwnd)
            break
        Sleep(30)
    }
    if hasInput
        edt.Focus()
    while (!askDone && WinExist("ahk_id " . g.Hwnd))
        Sleep(25)
    if owner {
        try WinSetEnabled(true, "ahk_id " . owner)
        try WinActivate("ahk_id " . owner)
    }
    try g.Destroy()
    uiModal := savedModal
    return askResult
}

AskPick(value, opts, edt, errLbl, *) {
    global askDone, askResult
    if (edt != 0 && value != "") {                 ; with an input box: validate when OK is clicked
        local text := Trim(edt.Value)
        local err := opts.Has("validate") ? opts["validate"](text) : ""
        if (err != "") {
            errLbl.Text := err
            edt.Focus()
            return
        }
        value := text
    }
    askResult := value
    askDone := true
}

; center the dialog over the reference window (or on the screen with the mouse if there is none). Gui.Move uses logical pixels; windows / work areas are physical pixels
AskCenter(g, refHwnd) {
    local sc := A_ScreenDPI / 96.0
    local cx, cy
    g.GetPos(, , &gw, &gh)
    if (refHwnd && WinExist("ahk_id " . refHwnd)) {
        WinGetPos(&rx, &ry, &rw, &rh, "ahk_id " . refHwnd)
        cx := (rx + rw / 2) / sc
        cy := (ry + rh / 2) / sc
    } else {
        local mx, my
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        GetWorkArea(mx, my, &L, &T, &R, &B)
        cx := (L + R) / 2 / sc
        cy := (T + B) / 2 / sc
    }
    g.Move(Round(cx - gw / 2), Round(cy - gh / 2))
}

AskShort(s) {
    s := RegExReplace(s, "\s+", " ")
    return StrLen(s) > 38 ? SubStr(s, 1, 38) . "…" : s
}

; dangerous actions (delete) in red, others in blue; default button: "Cancel" for dangerous actions, "Confirm" otherwise
Confirm(title, heading, msg := "", items := "", okText := "", danger := false, opts := "") {
    if !IsObject(opts)
        opts := Map()
    if (okText = "")
        okText := Tr("dlg.ok")
    opts["kind"] := danger ? "danger" : "primary"
    local btns := [
        Map("text", Tr("dlg.cancel"), "kind", "normal", "value", "", "default", danger ? 1 : 0),
        Map("text", okText, "kind", danger ? "danger" : "primary", "value", "ok", "default", danger ? 0 : 1)]
    return Ask(title, heading, msg, items, btns, opts) = "ok"
}

Notice(title, heading, msg := "", opts := "") {
    if !IsObject(opts)
        opts := Map()
    opts["kind"] := "danger"
    Ask(title, heading, msg, "", [Map("text", Tr("dlg.got_it"), "kind", "primary", "value", "ok", "default", 1)], opts)
}

; enter a line of text. validate(text) returns an error message (shown under the input box, window stays open) or ""; cancel returns ""
AskName(title, heading, msg, initial, validate, opts := "") {
    if !IsObject(opts)
        opts := Map()
    opts["input"] := initial
    opts["validate"] := validate
    local btns := [
        Map("text", Tr("dlg.cancel"), "kind", "normal", "value", ""),
        Map("text", Tr("dlg.ok"), "kind", "primary", "value", "ok", "default", 1)]
    return Ask(title, heading, msg, "", btns, opts)
}
