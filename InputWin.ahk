#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Input translation window (#Include by Translator.ahk)
; With no text selected, press the trigger hotkey (or tray "Input translation…") → the input window opens; Enter translates.
; Direction is detected automatically from the languages in Settings (InputPlan). After selecting text, pressing the hotkey uses the same logic.
; The result reuses the existing popup (placed right below the input window), so single words still show dictionary senses and the engines can still be chosen.
;=====================================================================

global inputGui := 0, inputEdit := 0, inputTarget := 0
global forceAnchor := false     ; when true, the popup does not use "screen center" mode and always sticks to the input window

; Direction follows the languages in Settings instead of a fixed Chinese/English pair:
;   text already in the target language -> reverse direction (to the source language if one is set; otherwise EN, or ZH when the target is EN)
;   anything else                       -> the target language
; The language of the text is guessed from its script (see DetectLang).
LangDisplay(code) => Tr("lang." . StrLower(code))

ReverseLang(tgt, src) => (src != "" && src != tgt) ? src : (tgt = "EN" ? "ZH" : "EN")

; Decides engine and direction; returns 0 if the input contains nothing to translate
; force = fixed target language chosen in the input window: no direction is guessed
InputPlan(text, force := "") {
    global cfg
    local lang := DetectLang(text)
    if (lang = "")
        return 0
    local tgt := StrUpper(cfg["target_lang"]), src := StrUpper(cfg["source_lang"])
    ; A Latin text without clear evidence counts as English only for an English target with no other Latin source
    local isTarget := (force = "") && ((lang = tgt) || (lang = "LATIN" && tgt = "EN" && !IsLatinLang(src)))
    local rev := isTarget ? ReverseLang(tgt, src) : ""
    local final := (force != "") ? force : (rev != "") ? rev : tgt

    local latin := (lang = "LATIN" || IsLatinLang(lang))
    local english := (lang = "LATIN" || lang = "EN")
    local word := DictCleanWord(text)
    local isWord := latin && IsWordLike(word) && ((force != "") ? english : (rev = "" || (final = "ZH" && english)))
    local engine := isWord ? cfg["engine_word"] : cfg["engine_sentence"]
    ; ECDICT only knows English -> Chinese
    if (engine = "ecdict" && !(final = "ZH" && english && (force != "" || rev != "" || src = "" || src = "EN")))
        engine := cfg["engine_sentence"]
    return Map("engine", engine, "isWord", isWord, "text", isWord ? word : text, "tgt", (force != "") ? force : rev)
}

InputTargetChanged() {
    global inputEdit, inputTarget, cfg
    cfg["input_target"] := LangCode(inputTarget.Value, true)
    IniWriteMany(ConfigFile(), [["Lang", "input_target", cfg["input_target"]]])
    inputEdit.Focus()
}

InputWinActive(*) => (inputGui != 0 && WinActive("ahk_id " . inputGui.Hwnd))

ShowInputWin(*) {
    global inputGui, inputEdit, inputTarget, cfg, SET_LANGS
    if (inputGui != 0) {
        WinActivate("ahk_id " . inputGui.Hwnd)
        inputEdit.Focus()
        return
    }
    local g := Gui("+AlwaysOnTop", Tr("input.title"))
    g.MarginX := 14, g.MarginY := 12
    g.SetFont("s10", "Microsoft YaHei")
    ; -WantReturn: Enter does not insert a newline but triggers the default button "Translate"
    inputEdit := g.Add("Edit", "x14 y12 w352 r4 -WantReturn")
    ; "Translate to": Auto follows the languages in Settings, any other choice is a fixed target; remembered in config.ini
    local tgtCode := StrUpper(cfg["target_lang"])
    local items := [Tr("input.auto", LangDisplay(tgtCode), LangDisplay(ReverseLang(tgtCode, StrUpper(cfg["source_lang"]))))]
    for l in SET_LANGS
        items.Push(Tr(l[2]))
    local lbl := g.Add("Text", "x14 y+10", Tr("input.target"))
    local lw := 0
    lbl.GetPos(, , &lw)
    inputTarget := g.Add("DropDownList", "x+6 yp-3 w" . (352 - lw - 6), items)
    inputTarget.Value := LangIndex(cfg["input_target"], true)
    inputTarget.OnEvent("Change", (*) => InputTargetChanged())
    g.SetFont("s8 c808080")
    g.Add("Text", "x14 y+10 w262 h32", Tr("input.hint"))
    g.SetFont("s10 cDefault")
    g.Add("Button", "x286 yp-4 w80 h30 Default", Tr("input.translate")).OnEvent("Click", InputTranslate)
    g.OnEvent("Close", (*) => CloseInputWin())
    g.OnEvent("Escape", (*) => CloseInputWin())
    inputGui := g

    ; Show horizontally centered on the current screen, 1/4 from the top (leaves room below for the result popup); Gui coordinates are logical pixels, the work area is physical pixels
    g.Show("x-2400 y-2400 w380")
    g.GetPos(, , &gw, &gh)
    local mx, my
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    GetWorkArea(mx, my, &L, &T, &R, &B)
    local sc := A_ScreenDPI / 96.0
    g.Move(Round(L / sc) + (Round((R - L) / sc) - gw) // 2, Round(T / sc) + Round((B - T) / sc * 0.25))
    ; the foreground lock may make the first activation fail; retry briefly
    loop 6 {
        WinActivate("ahk_id " . g.Hwnd)
        if WinActive("ahk_id " . g.Hwnd)
            break
        Sleep(50)
    }
    inputEdit.Focus()
}

CloseInputWin() {
    global inputGui, inputEdit, inputTarget, token, pinned, forceAnchor
    if (inputGui = 0)
        return
    token += 1                       ; discard results still on the way
    try inputGui.Destroy()
    inputGui := 0, inputEdit := 0, inputTarget := 0, forceAnchor := false
    if !pinned
        DestroyGui()
}

; The "Translate" button is the default button, so pressing Enter in the input box reaches here (Enter during IME composition is consumed by the IME and does not get here).
; Holding Shift or Ctrl inserts a newline instead, so no keyboard-hook hotkey is needed.
InputTranslate(*) {
    global inputGui, inputEdit, busy, token, cfg, selX, selY, lastFg, forceAnchor
    if (inputGui = 0)
        return
    if (GetKeyState("Shift") || GetKeyState("Ctrl")) {
        InputNewline()
        return
    }
    if busy
        return
    inputEdit.Focus()                ; after the default button fires, focus stays on the button; return it to the input box first so typing can continue during translation
    local text := Trim(inputEdit.Value, " `t`r`n")
    if (text = "")
        return
    ; The result popup sticks right below the input window, left-aligned, and clicking the input window will not close it.
    ; selX/selY are physical-pixel anchors; DoShow converts them to logical pixels and adds 15, so subtract the physical-pixel equivalent of 15 logical pixels here.
    ; (Gui.GetPos returns x/y in physical pixels but w/h in logical pixels, which is easy to get wrong, so WinGetPos is used uniformly here.)
    local x, y, w, h, off := Round(15 * A_ScreenDPI / 96.0)
    WinGetPos(&x, &y, &w, &h, "ahk_id " . inputGui.Hwnd)
    selX := x - off
    selY := y + h - off + 6          ; 6-pixel gap from the input window
    forceAnchor := true
    lastFg := inputGui.Hwnd          ; after the popup shows, return focus to the input box so typing can continue

    local plan := InputPlan(text, LangCode(inputTarget.Value, true))
    if !plan {
        token += 1
        ShowError(Tr("input.need_text"))
        return
    }
    local hint := ""
    local m := Integer(cfg["max_chars"])
    if (StrLen(plan["text"]) > m) {
        hint := Tr("hint.truncated", m)
        plan["text"] := SubStr(plan["text"], 1, m)
    }
    StartTranslate(plan["engine"], plan["text"], plan["isWord"], hint, plan["tgt"])
}

; Inserts a newline at the cursor. After the default button fires, focus is on the button, so focus must go back to the input box;
; giving the input box focus selects all its content, so the cursor position is saved first and restored after the newline is inserted.
InputNewline() {
    global inputEdit
    local startPos := Buffer(4, 0), endPos := Buffer(4, 0)
    SendMessage(0xB0, startPos, endPos, inputEdit)        ; EM_GETSEL
    local s := NumGet(startPos, "UInt")
    inputEdit.Focus()
    SendMessage(0xB1, s, NumGet(endPos, "UInt"), inputEdit)   ; EM_SETSEL: restore the original selection
    EditPaste("`r`n", inputEdit)                          ; replace the selection (if there is none, insert at the cursor)
}

; top-level window handle at screen coordinates (x, y) (0 = none).
; WindowFromPoint takes a POINT by value (x in the low 32 bits, y in the high 32 bits, combined into one int64);
; passing a buffer pointer returns 0, so an int64 must be passed here.
TopLevelAt(x, y) {
    local pt := Buffer(8)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    local w := DllCall("WindowFromPoint", "int64", NumGet(pt, 0, "Int64"), "ptr")
    return w ? DllCall("GetAncestor", "ptr", w, "uint", 2, "ptr") : 0     ; GA_ROOT
}

; point inside the input window (including child controls)
PointInInput(x, y) {
    global inputGui
    return inputGui != 0 && TopLevelAt(x, y) = inputGui.Hwnd
}
