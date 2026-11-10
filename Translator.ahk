#Requires AutoHotkey v2.0
#SingleInstance Force        ; Replace the old instance on re-launch to avoid double hotkey popups
FileEncoding "UTF-8"

#Include I18n.ahk
#Include Json.ahk
#Include Dict.ahk
#Include Engines.ahk
#Include HyMT.ahk
#Include InputWin.ahk
#Include Dialogs.ahk
#Include Bookmarks.ahk
#Include BookmarkWin.ahk
#Include ModelWin.ahk
#Include SpeedTest.ahk
#Include Wizard.ahk
#Include Settings.ahk

SetWorkingDir(AppDir())          ; config.ini and secret.txt are relative paths; a shortcut or autostart can launch from any folder

; Write uncaught exceptions to error.log (fixed path in the script folder) and still show the default error dialog, for diagnosis
OnError(LogError)

;=====================================================================
; Selection translation helper
; Select English -> Ctrl+Shift+X -> a word shows dictionary definitions (default: ECDICT), a sentence shows "source + translation" (default: Hy-MT2)
; Engines can be switched in Settings or the tray: ECDICT / Hy-MT2 local model / Microsoft / DeepL. Failures show the reason (only ECDICT can auto-switch)
; Key techniques: ClipboardAll backup/restore / Chinese detection / SetTimer background dispatch (main thread stays responsive) / token check to discard stale results
;=====================================================================

global cfg := Map()
global busy := false
global token := 0
global popupHwnd := 0
global myGui := 0   ; Reuse a single popup instance
global c := Map()   ; Fixed set of controls in the content area (only text and visibility are updated, never added or removed)
global selX := 0, selY := 0      ; Selection anchor locked at trigger time: where the selection ended
global selStartX := 0, selStartY := 0   ; ... and where it started (see PlacePopup)
global dragEndX := 0, dragEndY := 0, lastDragTime := 0, mouseDown := false
global dragStartX := 0, dragStartY := 0, pressX := 0, pressY := 0
global pinned := false, paused := false
global barCtrl := 0            ; Title bar control handle (for WM_LBUTTONDOWN dragging)
global pinCtrl := 0            ; Pin control handle (for the pinned-state visual feedback)
global lastFg := 0             ; Foreground window at trigger time; focus is returned to it after the popup shows
global selEdits := Map()       ; All selectable read-only text boxes in the popup: handle -> control
global selActive := 0          ; The text box the mouse was just released on
global labelCtrl := 0, labelText := ""   ; Engine name on the left of the title bar (briefly shows "Copied" after copy-on-select)
global starCtrl := 0           ; Favorite star on the title bar (only on popups with a successful translation)
global starSrc := ""           ; Source text for the star (what gets bookmarked is this text)

;=========================== Config ====================================
; The settings file. SELTR_CONFIG=<path> in the environment points the program at another file; the automated
; tests use it so that they never touch the user's real config.ini.
ConfigFile() {
    static path := EnvGet("SELTR_CONFIG") != "" ? EnvGet("SELTR_CONFIG") : "config.ini"
    return path
}

LoadConfig() {
    global cfg
    ini := ConfigFile()
    cfg["api_url"]        := IniValue(ini, "API", "api_url",        "https://api-free.deepl.com/v2/translate")
    cfg["target_lang"]    := IniValue(ini, "Lang", "target_lang",  "ZH")
    cfg["source_lang"]    := IniValue(ini, "Lang", "source_lang",  "")
    cfg["input_target"]   := IniValue(ini, "Lang", "input_target", "")   ; input window "Translate to": "" = automatic
    cfg["trigger_hotkey"] := IniValue(ini, "Hotkey", "trigger",    "^+x")
    cfg["win_pos"]        := IniValue(ini, "Behavior", "window_position", "cursor")
    cfg["show_copy"]      := IniValue(ini, "Behavior", "show_copy_button", "1")
    cfg["show_tips"]      := IniValue(ini, "Behavior", "show_tray_tips", "1")
    cfg["copy_on_select"] := IniValue(ini, "Behavior", "copy_on_select", "1")
    cfg["max_chars"]      := IniValue(ini, "Behavior", "max_chars", "5000")
    cfg["net_timeout"]    := IniValue(ini, "Behavior", "network_timeout", "10000")
    cfg["engine_word"]    := IniValue(ini, "Engine", "word", "ecdict")
    cfg["engine_sentence"] := IniValue(ini, "Engine", "sentence", "hy")
    cfg["ecdict_fallback"] := IniValue(ini, "Engine", "ecdict_fallback", "none")
    local fbOk := false
    for fid in ECDICT_FALLBACK_IDS
        if (fid = cfg["ecdict_fallback"])
            fbOk := true
    if !fbOk
        cfg["ecdict_fallback"] := "none"
    cfg["hy_mode"]        := IniValue(ini, "Hy", "load_mode", "idle")
    cfg["hy_idle"]        := IniValue(ini, "Hy", "idle_minutes", "10")
    cfg["hy_server"]      := IniValue(ini, "Hy", "server", "llama\llama-server.exe")
    cfg["hy_model"]       := IniValue(ini, "Hy", "model", "models\Hy-MT2-1.8B-Q6_K.gguf")
    cfg["hy_port"]        := IniValue(ini, "Hy", "port", "18080")
    cfg["hy_gpu_layers"]  := IniValue(ini, "Hy", "gpu_layers", "99")
    cfg["hy_device"]      := IniValue(ini, "Hy", "device", "")           ; "" = engine decides, "cpu", or an id such as Vulkan0 (see SpeedTest.ahk)
    cfg["hy_device_name"] := IniValue(ini, "Hy", "device_name", "")
    cfg["ms_region"]      := IniValue(ini, "Microsoft", "region", "")
    cfg["dict_phonetic"]  := IniValue(ini, "Dict", "show_phonetic", "1")
    cfg["dict_forms"]     := IniValue(ini, "Dict", "show_forms", "1")
    cfg["dict_domain"]    := IniValue(ini, "Dict", "show_domain", "0")
    cfg["dict_max"]       := IniValue(ini, "Dict", "max_senses", "0")
    cfg["ui_lang"]        := IniValue(ini, "UI", "language", "auto")
    I18nInit(cfg["ui_lang"])
}
IniValue(file, sec, key, dflt) {
    v := IniRead(file, sec, key, "")
    return (v = "") ? dflt : v
}

; First run: generate a full default config so users can read and edit it directly
EnsureConfig() {
    if FileExist(ConfigFile())
        return
    FileAppend("; Selection Translator config / 选中翻译助手 配置文件`n"
        "`n"
        "; API keys are NOT stored here: DeepL key -> secret.txt, Microsoft key -> secret_microsoft.txt`n"
        "; API Key 请单独写在 secret.txt（DeepL）和 secret_microsoft.txt（Microsoft），本文件不存 Key`n"
        "[UI]`n"
        "language=auto`n"
        "`n"
        "[API]`n"
        "api_url=https://api-free.deepl.com/v2/translate`n"
        "`n"
        "[Lang]`n"
        "target_lang=ZH`n"
        "source_lang=`n"
        "`n"
        "[Hotkey]`n"
        "trigger=^+x`n"
        "`n"
        "[Behavior]`n"
        "window_position=cursor`n"
        "show_copy_button=1`n"
        "show_tray_tips=1`n"
        "copy_on_select=1`n"
        "max_chars=5000`n"
        "network_timeout=10000`n"
        "`n"
        "[Engine]`n"
        "word=ecdict`n"
        "sentence=hy`n"
        "ecdict_fallback=none`n"
        "`n"
        "[Hy]`n"
        "load_mode=idle`n"
        "idle_minutes=10`n"
        "server=llama\llama-server.exe`n"
        "model=models\Hy-MT2-1.8B-Q6_K.gguf`n"
        "port=18080`n"
        "gpu_layers=99`n"
        "`n"
        "[Microsoft]`n"
        "region=`n"
        "`n"
        "[Dict]`n"
        "show_phonetic=1`n"
        "show_forms=1`n"
        "show_domain=0`n"
        "max_senses=0`n", ConfigFile(), "UTF-8")
}

;=========================== Hotkeys ====================================
g_reg := ""
RegisterHotkey() {
    global cfg, g_reg
    if (g_reg != "")
        try Hotkey(g_reg, "OFF")
    try {
        Hotkey(cfg["trigger_hotkey"], OnTranslate, "On")   ; "On" is needed: re-registering a hotkey that is currently Off would leave it Off
        g_reg := cfg["trigger_hotkey"]
    } catch as e {
        Notice(Tr("app.name"), Tr("hotkey.invalid"), cfg["trigger_hotkey"] "`n" e.Message)
    }
}

;=========================== Trigger =================================
OnTranslate(*) {
    global busy, token, cfg, selX, selY, lastFg, forceAnchor
    if (busy || paused)
        return
    if InputWinActive() {         ; Input window is in front: don't grab text, just return focus to the input box
        inputEdit.Focus()
        return
    }
    ResolveAnchor(&selX, &selY)   ; Lock the selection anchor first, so it still works if the mouse moves before the request finishes
    local saved := ClipboardAll()
    A_Clipboard := ""
    SendInput("^c")
    if (!ClipWait(0.5)) {         ; No text selected -> open the input translation window
        A_Clipboard := saved
        ShowInputWin()
        return
    }
    sel := A_Clipboard
    A_Clipboard := saved
    sel := Trim(sel)
    if (sel = "") {
        ShowInputWin()
        return
    }
    forceAnchor := false

    if (RegExMatch(sel, "i)^(https?://|[\d.:\-/\s]+$)"))     ; URLs and bare numbers are not worth a popup
        return

    ; Same decision as the input window (InputPlan): direction from the languages in Settings; English 1-4 words -> word engine,
    ; everything else -> sentence engine. Returns 0 if there is nothing translatable.
    local plan := InputPlan(sel)
    if !plan
        return
    if (plan["tgt"] = "" && !plan["isWord"] && StrLen(sel) < 3 && !RegExMatch(sel, "[^\x00-\x7F]"))
        return
    local text := plan["text"]
    local hint := ""
    local m := Integer(cfg["max_chars"])
    if (StrLen(text) > m) {
        hint := Tr("hint.truncated", m)
        text := SubStr(text, 1, m)
    }

    lastFg := DllCall("GetForegroundWindow", "ptr")
    StartTranslate(plan["engine"], text, plan["isWord"], hint, plan["tgt"])
}

; Start one translation (shared by the hotkey and the input window). tgt non-empty = reverse translation, target language is tgt
StartTranslate(engine, text, isWord, hint := "", tgt := "") {
    global busy, token
    token += 1
    ; ECDICT is a local lookup (<1ms), so show the result directly without going through "Translating..."
    if (engine = "ecdict") {
        ShowEngineResult(engine, text, isWord, token, hint, tgt)
        return
    }
    busy := true
    ShowBusy(engine = "hy" && !HyIsRunning()
        ? Tr("busy.loading_model")
        : Tr("busy.translating_with", EngineName(engine)))
    local tok := token
    SetTimer(() => ShowEngineResult(engine, text, isWord, tok, hint, tgt), -1)
}

;=========================== Translation ====================================
; Call the engine in the timer thread and show the result. The whole body is in try/catch: errors go to the popup and don't crash the resident process.
; Only show the result if the token is still the latest (results from old requests are discarded on arrival).
; prev non-empty = automatic switch after ECDICT failed; prev holds the ECDICT failure reason.
ShowEngineResult(engine, text, isWord, tok, hint, tgt := "", prev := "") {
    global cfg, busy
    local res := 0
    local label := EngineName(engine) . (tgt != "" ? " · " . Tr("label.to_lang", LangDisplay(tgt)) : "") . (prev != "" ? " · " . Tr("label.auto_switch") : "")
    try {
        res := RunEngine(engine, text, isWord, tgt)
    } catch as e {
        if (tok != TokenNow())
            return
        local fb := (engine = "ecdict") ? cfg["ecdict_fallback"] : "none"
        if (fb != "none") {
            local why := Tr("err.engine_failed", EngineName(engine), e.Message)
            busy := true
            ShowBusy(Tr("busy.switching", EngineName(engine), EngineName(fb)))
            SetTimer(() => ShowEngineResult(fb, text, isWord, tok, hint, tgt, why), -1)
            return
        }
        local msg := Tr("err.engine_failed", EngineName(engine), e.Message)
        ShowError(prev != "" ? prev . "`n" . msg : msg, label)
        return
    }
    if (tok != TokenNow())
        return
    try {
        if (res["kind"] = "dict")
            ShowDict(text, res["entry"], label)
        else
            ShowResult(text, res["text"], hint, label)
    } catch as e {
        ShowError(Tr("err.show_result", e.Message), label)
    }
}
TokenNow() {
    global token
    return token
}
;=========================== Popup (rebuild + remember position) ==============
; Destroy and rebuild the popup on every content update, restoring the original "window grows with content" UI (no gaps).
; When pinned: remember the current position before rebuilding and restore it afterwards, without following the selection or jumping.
global remX := 0, remY := 0
ShowBusy(msg := "") {
    global myGui
    if (msg = "")
        msg := Tr("busy.translating")
    RebuildPopup()
    local g := myGui
    g.SetFont("s10 c808080")
    g.Add("Text", "x14 w340", msg)
    DoShow()
}
; System balloon notifications (TrayTip) all go through here; can be turned off entirely in Settings
Notify(args*) {
    global cfg
    if (cfg["show_tips"] = "1")
        TrayTip(args*)
}
ShowError(msg, label := "") {
    global busy, myGui
    busy := false
    RebuildPopup(label)
    local g := myGui
    g.SetFont("s10 ccc0000")
    g.Add("Text", "x14 w340", msg)
    DoShow()
    Notify(Tr("notify.translate_failed"), SubStr(msg, 1, 250), 3)
}
ShowResult(source, translated, hint := "", label := "") {
    global busy, cfg, myGui
    busy := false
    RebuildPopup(label, source)
    local g := myGui
    if (hint != "") {
        g.SetFont("s8 c808080")
        g.Add("Text", "x14 w340", hint)
    }
    g.SetFont("s10 c808080")
    g.Add("Text", "x14 w340", Tr("popup.source"))
    g.SetFont("s10 c333333")
    ; Use Text instead of Edit: auto-wrap, correct newline rendering, no scrollbar; the window grows with the content so all of it stays visible
    g.Add("Text", "x14 w340", source)
    g.SetFont("s10 c808080")
    g.Add("Text", "x14 w340", Tr("popup.translation"))
    ; The translation uses a read-only edit box: looks the same as text (no border, same background) but can be selected with the mouse
    g.SetFont("s10 c0055aa")
    SelEdit(g, "x11", 346, translated, "s10")
    if (cfg["show_copy"] = "1") {
        local dstCopy := translated
        g.Add("Button", "x14 w130 h30", Tr("popup.copy_translation")).OnEvent("Click",
            (*) => A_Clipboard := dstCopy)
    }
    DoShow()
}
; Selecting text in the translation / definition boxes and releasing the mouse auto-copies it to the clipboard (can be turned off in Settings).
; The popup doesn't take focus, so Ctrl+C can't be used; instead this listens for left-button release (WM_LBUTTONUP sent to these read-only boxes).
OnSelRelease(wParam, lParam, msg, hwnd) {
    global selEdits, selActive, cfg
    if (cfg["copy_on_select"] != "1" || !selEdits.Has(hwnd))
        return
    selActive := selEdits[hwnd]
    SetTimer(CopySelection, -40)          ; Wait for the text box to finish handling this release so the selection is final
}
CopySelection() {
    global selActive
    if (selActive != 0)
        CopyEditSel(selActive)
}
; Get the selected text in a text box: returns [start, end] (0-based start, end exclusive), or 0 if nothing is selected
EditSelRange(ed) {
    local s := Buffer(4, 0), e := Buffer(4, 0)
    try {
        SendMessage(0xB0, s, e, ed)              ; EM_GETSEL
        local a := NumGet(s, "UInt"), b := NumGet(e, "UInt")
        if (b > a)
            return [a, b]
    }
    return 0
}
; Copy the selected text of one text box to the clipboard; returns whether anything was copied
CopyEditSel(ed) {
    global selEdits, labelCtrl
    local r := EditSelRange(ed)
    if !r
        return false                              ; Nothing selected (just a click)
    try {
        A_Clipboard := SubStr(ed.Value, r[1] + 1, r[2] - r[1])
        for h, other in selEdits                  ; Clear leftover highlights in other boxes so it doesn't look like two selections
            if (other != ed)
                try SendMessage(0xB1, 0, 0, other)   ; EM_SETSEL 0,0
        if (labelCtrl != 0) {
            labelCtrl.Text := Tr("popup.copied")
            SetTimer(RestoreLabel, -1200)
        }
        return true
    }
    return false
}
; A click elsewhere in the popup (blank area, title bar, buttons, other text boxes) clears the selection highlight, matching normal window behavior.
; A click inside a text box is handled by the box itself (click to deselect, select again)
OnPopupClick(wParam, lParam, msg, hwnd) {
    global selEdits, popupHwnd
    if (selEdits.Count = 0 || popupHwnd = 0)
        return
    if (DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != popupHwnd)
        return
    for h, e in selEdits
        if (h != hwnd)
            try SendMessage(0xB1, 0, 0, e)
}
; When there's a selection in the popup and the mouse is over it, Ctrl+C copies the selected text (the popup doesn't take focus, otherwise Ctrl+C would go to another program)
PopupSelEdit() {
    global selEdits
    for h, e in selEdits
        if EditSelRange(e)
            return e
    return 0
}
PopupSelHot(*) {
    global popupHwnd, selEdits
    if (popupHwnd = 0 || selEdits.Count = 0)
        return false
    local mx, my
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    return TopLevelAt(mx, my) = popupHwnd && PopupSelEdit() != 0
}
CopyPopupHotkey(*) {
    local e := PopupSelEdit()
    if (e != 0)
        CopyEditSel(e)
}
RestoreLabel() {
    global labelCtrl, labelText
    if (labelCtrl != 0)
        try labelCtrl.Text := labelText
}
; RRGGBB hex of the default window background (button face color), so the input box matches the popup background
SysFaceHex() {
    local c := DllCall("GetSysColor", "int", 15, "uint")      ; COLOR_BTNFACE，BGR
    return Format("{:02X}{:02X}{:02X}", c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)
}
; Measure the size of a text (logical pixels): create a temporary text control with the same font, measure it, then destroy it.
; width = 0 means no width limit (single line, measure the natural text width). Returns [width, height]
MeasureText(text, spec, name, width := 0) {
    local m := Gui()
    m.SetFont(spec, name)
    local t := m.Add("Text", width ? "w" . width : "", text)
    local w := 0, h := 0
    t.GetPos(, , &w, &h)
    m.Destroy()
    return [w, h]
}
; Selectable read-only text box that looks like normal text (no border, same background, same font color; the font color comes from the current g font settings,
; spec / name must match the SetFont used before the call, for height measurement). w = control width (including about 3 px of padding on each side);
; single = true: one line, width is the natural text width. The selection highlight is kept after focus is lost (+0x100)
SelEdit(g, pos, w, text, spec, name := "Microsoft YaHei", single := false) {
    global selEdits
    local t := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "`r`n")
    local sz, opt := ""
    if single {
        sz := MeasureText(text, spec, name)
        w := sz[1] + 10
    } else {
        sz := MeasureText(text, spec, name, w - 6)
        opt := " Multi"
    }
    local e := g.Add("Edit", pos . " w" . w . " h" . (sz[2] + 2) . opt
        . " ReadOnly -VScroll -Tabstop -E0x200 +0x100 Background" . SysFaceHex(), t)
    selEdits[e.Hwnd] := e
    return e
}
; Dictionary result: word + phonetic, one line per sense as "part-of-speech abbreviation | definition", inflected forms at the end
ShowDict(query, e, label := "") {
    global busy, cfg, myGui
    busy := false
    RebuildPopup(label, query)
    local g := myGui
    local maxN := IsInteger(cfg["dict_max"]) ? Integer(cfg["dict_max"]) : 0
    local showDomain := (cfg["dict_domain"] = "1")
    local senses := DictSenses(e, showDomain, maxN)
    local phon := (cfg["dict_phonetic"] = "1" && e["phonetic"] != "") ? "/" . e["phonetic"] . "/" : ""
    local copyTxt := e["word"] . (phon != "" ? "  " . phon : "")

    ; Show a hint when the match only succeeded after lemmatization (apples -> apple)
    if (StrLower(query) != StrLower(e["word"])) {
        g.SetFont("s8 norm c808080")
        g.Add("Text", "x14 w340", query . " → " . e["word"])
    }
    g.SetFont("s13 bold c222222")
    if (phon != "" && StrLen(e["word"]) <= 16) {
        SelEdit(g, "x11", 0, e["word"], "s13 bold", "Microsoft YaHei", true)
        g.SetFont("s10 norm c808080", "Segoe UI")   ; Microsoft YaHei renders the IPA stress mark ˈ incorrectly, so phonetics use Segoe UI
        SelEdit(g, "x+7 yp+5", 0, phon, "s10 norm", "Segoe UI", true)
    } else {
        SelEdit(g, "x11", 346, e["word"], "s13 bold")
        if (phon != "") {
            g.SetFont("s10 norm c808080", "Segoe UI")
            SelEdit(g, "x11 y+2", 346, phon, "s10 norm", "Segoe UI")
        }
    }
    g.SetFont(, "Microsoft YaHei")
    DictAddRows(g, senses, &copyTxt)

    ; If a variant form (e.g. ran) only has a note like "past tense of run", add the base form's senses and inflections
    local formsSrc := e["exchange"]
    if (e["lemma"] != "" && e["lemma"] != StrLower(e["word"]) && !DictHasPos(senses)) {
        local base := 0
        try base := DictFind(e["lemma"])
        if (base) {
            g.SetFont("s9 norm c808080")
            g.Add("Text", "x14 y+10 w340", Tr("dict.lemma", base["word"]))
            copyTxt .= "`n" . Tr("dict.lemma", base["word"])
            DictAddRows(g, DictSenses(base, showDomain, maxN), &copyTxt)
            formsSrc := base["exchange"]
        }
    }
    if (cfg["dict_forms"] = "1") {
        local forms := DictForms(formsSrc)
        if (forms != "") {
            g.SetFont("s9 norm c808080")
            SelEdit(g, "x11 y+10", 346, forms, "s9 norm")
            copyTxt .= "`n" . forms
        }
    }
    if (cfg["show_copy"] = "1") {
        g.SetFont("s10 norm")
        local dstCopy := copyTxt
        g.Add("Button", "x14 y+10 w130 h30", Tr("popup.copy_senses")).OnEvent("Click",
            (*) => A_Clipboard := dstCopy)
    }
    DoShow()
}
DictHasPos(senses) {
    for ln in senses
        if (ln["kind"] = "pos")
            return true
    return false
}
; One line per sense: left column = part-of-speech abbreviation (bold orange-brown) / domain label (gray); right column = definition (dark blue, word-wrapped)
DictAddRows(g, senses, &copyTxt) {
    for ln in senses {
        local text := StrReplace(ln["text"], ", ", "；")
        if (ln["kind"] = "plain") {
            g.SetFont("s10 norm c0055aa")
            SelEdit(g, "x11 y+6", 346, text, "s10 norm")
            copyTxt .= "`n" . text
            continue
        }
        if (ln["kind"] = "pos")
            g.SetFont("s10 bold cB35C00")
        else
            g.SetFont("s9 norm c909090")
        g.Add("Text", "x14 y+6 w54", ln["tag"])
        g.SetFont("s10 norm c0055aa")
        SelEdit(g, "x67 yp", 290, text, "s10 norm")
        copyTxt .= "`n" . ln["tag"] . " " . text
    }
}
; Destroy the old popup (remember its position first), then build a new one from scratch
RebuildPopup(label := "", star := "") {
    global myGui, remX, remY, popupHwnd
    if (myGui != 0) {
        myGui.GetPos(&remX, &remY)
        try myGui.Destroy()
        myGui := 0
        popupHwnd := 0
    }
    myGui := BuildGui(label, star)
    myGui.OnEvent("Close", (*) => DestroyGui())
}
DestroyGui() {
    global myGui, busy, popupHwnd, starCtrl, starSrc, selEdits, selActive, labelCtrl
    starCtrl := 0, starSrc := "", selEdits := Map(), selActive := 0, labelCtrl := 0
    if (myGui != 0) {
        try myGui.Destroy()
        myGui := 0
        popupHwnd := 0
    }
    busy := false
}
BuildGui(label := "", star := "") {
    global popupHwnd, barCtrl, pinCtrl, starCtrl, starSrc, selEdits, selActive, labelCtrl, labelText
    selEdits := Map(), selActive := 0, labelCtrl := 0, labelText := label
    local g := Gui("+AlwaysOnTop +ToolWindow +Owner -Caption +Border", Tr("popup.title"))
    g.MarginX := 14
    g.MarginY := 10
    g.MarginTop := 30          ; Leave room at the top for the title bar
    g.SetFont("s10 q5", "Microsoft YaHei")
    ; Title bar: the whole bar is draggable (on WM_LBUTTONDOWN send WM_NCLBUTTONDOWN+HTCAPTION for native system drag)
    barCtrl := g.Add("Text", "x-1 y-1 w382 h22 Background5489C8", "")
    ; Small engine name on the left of the title bar shows which engine was used
    if (label != "") {
        g.SetFont("s8 cE6EEF8")
        labelCtrl := g.Add("Text", "x8 y3 w200 h16 Background5489C8", label)
        g.SetFont("s10 cDefault")
    }
    ; Favorite star (successful translations only): hollow = not favorited, solid yellow = favorited; right-click to choose the bookmark list
    starCtrl := 0, starSrc := ""
    if (star != "") {
        starSrc := star
        starCtrl := g.Add("Text", "x302 y0 w24 h20 Center Background5489C8 cFFFFFF", "☆")
        starCtrl.OnEvent("Click", (*) => StarClick())
        starCtrl.OnEvent("ContextMenu", (*) => StarMenu())
    }
    ; Pin (a pinned popup isn't closed by clicking outside; turns gold when pinned) + ✕ close
    pinCtrl :=g.Add("Text", "x328 y0 w24 h20 Center Background5489C8 cFFFFFF", "📌")
    pinCtrl.OnEvent("Click", (*) => TogglePin())
    g.Add("Text", "x354 y0 w26 h20 Center Background5489C8 cFFFFFF", "✕").OnEvent("Click", (*) => DestroyGui())
    popupHwnd := g.Hwnd
    SetPinLook()               ; Color the pin to match the current pinned state
    SetStarLook()
    ; WS_EX_NOACTIVATE (0x08000000): the popup doesn't take focus when shown
    DllCall("SetWindowLongPtr", "ptr", popupHwnd, "int", -20,
        "ptr", DllCall("GetWindowLongPtr", "ptr", popupHwnd, "int", -20, "ptr") | 0x08000000)
    return g
}
; Title bar pressed -> hand off to the native system drag (WParam=HTCAPTION)
DragBar(hwnd) {
    local x, y
    CoordMode("Mouse", "Screen")
    MouseGetPos(&x, &y)
    lParam := (y << 16) | (x & 0xFFFF)
    PostMessage(0x00A1, 0x0002, lParam, , "ahk_id " hwnd)
}
OnGuiLButtonDown(wParam, lParam, msg, hwnd) {
    global myGui, barCtrl
    if (myGui = 0 || barCtrl = 0)
        return
    if (DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != myGui.Hwnd)
        return    ; Click is on the settings window or another window, unrelated to the popup
    ; OnMessage returns the main window's hwnd, not the control; convert the message coordinates (client area) to screen and compare them with the title bar rectangle
    local x := lParam & 0xFFFF
    local y := (lParam >> 16) & 0xFFFF
    local pt := Buffer(8)
    NumPut("Int", x, pt, 0)
    NumPut("Int", y, pt, 4)
    DllCall("ClientToScreen", "ptr", hwnd, "ptr", pt)
    local sx := NumGet(pt, 0, "Int"), sy := NumGet(pt, 4, "Int")
    local r := Buffer(16)
    DllCall("GetWindowRect", "ptr", barCtrl.Hwnd, "ptr", r)
    local BL := NumGet(r, 0, "Int"), BT := NumGet(r, 4, "Int")
    local BR := NumGet(r, 8, "Int"), BB := NumGet(r, 12, "Int")
    if (sx >= BL && sx <= BR && sy >= BT && sy <= BB)
        DragBar(myGui.Hwnd)
}
TogglePin() {
    global pinned
    pinned := !pinned
    SetPinLook()
    Notify(pinned ? Tr("notify.pinned") : Tr("notify.unpinned"))
}
; Pin feedback: white = not pinned, gold = pinned (changing the foreground color with SetFont at runtime works reliably)
SetPinLook() {
    global pinCtrl, pinned
    if (pinCtrl = 0)
        return
    pinCtrl.SetFont(pinned ? "cFFD700" : "cFFFFFF")
}
; Star look: favorited = gold ★, not favorited = white ☆ (silently ignored if the popup has already been destroyed)
SetStarLook() {
    global starCtrl, starSrc
    if (starCtrl = 0)
        return
    try {
        local on := BmIsMarked(starSrc)
        starCtrl.Text := on ? "★" : "☆"
        starCtrl.SetFont(on ? "cFFD700" : "cFFFFFF")
    }
}
RefreshStar() => SetStarLook()
; Left click: not favorited -> add to the default bookmark list; favorited -> remove after confirmation
StarClick() {
    global starSrc
    if (starSrc = "")
        return
    local text := starSrc
    try {
        local f := BmFind(text)
        if f {
            if !Confirm(Tr("bm.unmark.title"), Tr("bm.unmark.heading"), Tr("bm.unmark.msg", BmDisplayName(f["list"]["name"])), "", Tr("bm.unmark.title"), true, Map("center", popupHwnd))
                return
            BmRemove(text)
        } else
            BmAdd(text)
    } catch as e
        Notice(Tr("bm.title"), Tr("bm.err.save"), e.Message, Map("center", popupHwnd))
    BmRefreshUI()
}
; Right click: list all bookmark lists. Not favorited = add to the chosen list; favorited = move to the chosen list (the current one is checked)
StarMenu() {
    global starSrc, uiModal, bm
    if (starSrc = "")
        return
    local cur := BmFind(starSrc)
    local starMenu := Menu()
    for l in bm["lists"] {
        starMenu.Add(StrReplace(BmListLabel(l), "&", "&&"), StarPick.Bind(l["name"]))
        if (cur && cur["list"] = l)
            starMenu.Check(StrReplace(BmListLabel(l), "&", "&&"))
    }
    uiModal := true
    starMenu.Show()
    uiModal := false
}
StarPick(name, *) {
    global starSrc
    try {
        if BmIsMarked(starSrc)
            BmMove([starSrc], name)
        else
            BmAdd(starSrc, name)
    } catch as e
        Notice(Tr("bm.title"), Tr("bm.err.save"), e.Message, Map("center", popupHwnd))
    BmRefreshUI()
}
; Places the popup beside the selection, trying right > below > left > above and keeping off the selected text.
; All values are logical pixels: (sx, sy) = where the drag started, (ex, ey) = where it ended, L/T/R/B = work area.
; The text itself is not visible to the program, so the selection is estimated from those two points and a typical line height.
PlacePopup(gw, gh, sx, sy, ex, ey, L, T, R, B) {
    static GAP := 15, LINE_GAP := 6, HALF_LINE := 14, HALF_WORD := 40, EDGE := 4
    local multi := Abs(ey - sy) > HALF_LINE
    local lastX := (ey >= sy) ? ex : sx, lastY := Max(sy, ey)     ; end of the lowest selected line
    local selL := Min(sx, ex), selR := multi ? lastX : Max(sx, ex)
    if (!multi && Abs(ex - sx) < 5)                               ; double-click: the word extends on both sides of the pointer
        selL -= HALF_WORD, selR += HALF_WORD
    local selT := Min(sy, ey) - HALF_LINE, selB := lastY + HALF_LINE
    slideY(y0) => Max(T + EDGE, Min(y0, B - gh - EDGE))
    local alignX := Max(L + EDGE, Min(lastX, R - gw - EDGE))

    if (selR + GAP + gw <= R - EDGE) {
        local y := lastY - HALF_LINE
        ; Beside one line the popup may slide up freely; beside several lines that would cover the lines above
        if !multi
            return Map("x", selR + GAP, "y", slideY(y), "side", "right")
        if (y + gh <= B - EDGE)
            return Map("x", selR + GAP, "y", y, "side", "right")
    }
    if (selB + LINE_GAP + gh <= B - EDGE)
        return Map("x", alignX, "y", selB + LINE_GAP, "side", "below")
    if (selL - GAP - gw >= L + EDGE)
        return Map("x", selL - GAP - gw, "y", slideY(selT), "side", "left")
    if (selT - LINE_GAP - gh >= T + EDGE)
        return Map("x", alignX, "y", selT - LINE_GAP - gh, "side", "above")
    return Map("x", alignX, "y", slideY(selB + LINE_GAP), "side", "none")    ; too large to avoid the text
}

DoShow() {
    global myGui, cfg, selX, selY, selStartX, selStartY, lastFg, pinned, remX, remY, forceAnchor
    ; Pinned: restore the original position after rebuilding (AutoSize is irrelevant; content is rebuilt on demand, so no resize is needed)
    if (pinned && remX != 0) {
        myGui.Show("x" remX " y" remY)
        RestoreFocus()
        return
    }
    ; AHK GUI coordinates are logical pixels (virtualized under system scaling), while mouse and work-area coordinates are physical pixels.
    ; Convert everything to logical space before computing, so the popup sits right next to the selection without going off-screen at 125%/150% scaling.
    local scale := A_ScreenDPI / 96.0
    ; Lay out off-screen first to get the real window size, to avoid a flicker at the wrong position
    myGui.Show("x-2400 y-2400 w380")
    myGui.GetPos(&dx, &dy, &gw, &gh)
    GetWorkArea(selX, selY, &L, &T, &R, &B)
    local lax := Round(selX / scale)
    local lay := Round(selY / scale)
    local Ll := Round(L / scale), Tl := Round(T / scale)
    local Rl := Round(R / scale), Bl := Round(B / scale)
    local x, y
    if (cfg["win_pos"] = "center" && !forceAnchor) {
        x := Ll + (Rl - Ll - gw) // 2
        y := Tl + (Bl - Tl - gh) // 2
    } else {
        if forceAnchor {                 ; Input and bookmark windows: stick to the point they computed
            x := lax + 15
            y := lay + 15
            if (x + gw > Rl)
                x := Rl - gw - 4
            if (x < Ll)
                x := Ll + 4
            if (y + gh > Bl)
                y := Bl - gh - 4
            if (y < Tl)
                y := Tl + 4
        } else {
            local p := PlacePopup(gw, gh, Round(selStartX / scale), Round(selStartY / scale), lax, lay, Ll, Tl, Rl, Bl)
            x := p["x"], y := p["y"]
        }
    }
    myGui.Move(x, y)
    ; This AHK build's Gui.Show always steals focus, so return focus to the window that was in front at trigger time
    RestoreFocus()
}
; After the popup shows, return focus to the previous window; if it was the input window, also put keyboard focus back in the input box
; (otherwise focus stays on the "Translate" button and the next typed characters don't reach the input box)
RestoreFocus() {
    global myGui, lastFg, inputGui, inputEdit
    if (lastFg != 0 && lastFg != myGui.Hwnd)
        DllCall("SetForegroundWindow", "ptr", lastFg)
    if (inputGui != 0 && lastFg = inputGui.Hwnd)
        inputEdit.Focus()
}
; Anchor = last left-button release point (end of the drag selection, roughly the right end of the selection, valid for 10 seconds); otherwise the current mouse position
ResolveAnchor(&ax, &ay) {
    global dragEndX, dragEndY, dragStartX, dragStartY, lastDragTime, selStartX, selStartY
    if (lastDragTime != 0 && A_TickCount - lastDragTime < 10000) {
        ax := dragEndX
        ay := dragEndY
        selStartX := dragStartX, selStartY := dragStartY
        return
    }
    MouseGetPos(&ax, &ay)
    selStartX := ax, selStartY := ay
}
GetWorkArea(x, y, &L, &T, &R, &B) {
    ; This AHK build has no MonitorFromPoint/MonitorGet, so loop over the work areas to find the monitor that contains the point
    n := MonitorGetCount()
    loop n {
        MonitorGetWorkArea(A_Index, &ML, &MT, &MR, &MB)
        if (x >= ML && x < MR && y >= MT && y < MB) {
            L := ML, T := MT, R := MR, B := MB
            return
        }
    }
    MonitorGetWorkArea(1, &L, &T, &R, &B)
}
; Lightweight resident polling: record the coordinates of the left-button release (the end of the drag selection), polling every 50 ms to get as close as possible to the real release point
TrackMouse() {
    global mouseDown, dragEndX, dragEndY, dragStartX, dragStartY, pressX, pressY, lastDragTime, popupHwnd
    MouseGetPos(&mx, &my)
    local down := GetKeyState("LButton", "P")
    if (down && !mouseDown) {
        mouseDown := true
        pressX := mx, pressY := my
        ; The position captured at press time may be off due to DPI or fast movement,
        ; so wait ~120 ms for the mouse to settle, then decide again with fresh coordinates (carrying the popup handle, to avoid closing a new popup by mistake)
        local expect := popupHwnd
        SetTimer(() => CheckOutsideNow(expect), -120)
    } else if (!down && mouseDown) {
        mouseDown := false
        dragStartX := pressX, dragStartY := pressY
        dragEndX := mx
        dragEndY := my
        lastDragTime := A_TickCount
    }
}
; Delayed re-check: the position after the press settles is the real click point
CheckOutsideNow(expect) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    try
        CloseIfOutside(mx, my, expect)
}
; Close when the press is outside the popup (not while busy, not when pinned; clicks inside or on the edge don't close it)
CloseIfOutside(x, y, expect := 0) {
    global popupHwnd, pinned, busy, uiModal
    if (pinned || busy || uiModal || popupHwnd = 0)
        return
    if (expect != 0 && popupHwnd != expect)
        return        ; The popup was already replaced by a new one; ignore this stale click
    ; Cursor is on the popup or one of its child controls -> a click inside the popup, never close
    if (PointInPopup(x, y) || PointInInput(x, y) || PointInBm(x, y))
        return        ; Click is inside the popup, the input window, or the bookmark window: don't close
    local r := Buffer(16)
    if !DllCall("GetWindowRect", "ptr", popupHwnd, "ptr", r)
        return
    ; Expand the rectangle by 12 px tolerance to absorb DPI coordinate conversion and sampling error at click time, so clicking the popup edge doesn't close it
    local L := NumGet(r, 0, "Int") - 12, T := NumGet(r, 4, "Int") - 12
    local RR := NumGet(r, 8, "Int") + 12, BB := NumGet(r, 12, "Int") + 12
    if (x < L || x > RR || y < T || y > BB)
        DestroyGui()
}
; Whether the top-level window at this point (including child controls) is the popup
PointInPopup(x, y) {
    global popupHwnd
    return popupHwnd != 0 && TopLevelAt(x, y) = popupHwnd
}

;=========================== Tray ====================================
; A fresh install (no config.ini yet) gets the setup guide once. SELTR_NO_WIZARD=1 suppresses it (automated tests).
global firstRun := !FileExist(ConfigFile()) && EnvGet("SELTR_NO_WIZARD") = ""
EnsureConfig()
LoadConfig()          ; Also initializes the UI language from [UI] language
ModelsMigrateAndRepoint()   ; engines from older versions get their own llama\<id>\ folder
BmLoad()

HyInit()

; Tray: quick-switch word and sentence engines from submenus (written to config.ini immediately); the current engine is checked
global wordMenu := Menu(), sentMenu := Menu()
for id in ENGINE_WORD_IDS
    wordMenu.Add(EngineName(id), SetEngine.Bind("word", id))
for id in ENGINE_SENTENCE_IDS
    sentMenu.Add(EngineName(id), SetEngine.Bind("sentence", id))

; Build the tray menu (called at startup and once after switching the UI language)
BuildTrayMenu() {
    global paused
    local mnu := A_TrayMenu
    mnu.Delete()
    mnu.Add(Tr("tray.input"), (*) => ShowInputWin())
    mnu.Add(Tr("tray.bookmarks"), (*) => ShowBookmarks())
    mnu.Add(Tr("tray.settings"), (*) => ShowSettings())
    mnu.Add(Tr("tray.wizard"), (*) => ShowWizard())
    mnu.Add(Tr("tray.word_engine"), wordMenu)
    mnu.Add(Tr("tray.sentence_engine"), sentMenu)
    mnu.Add()
    mnu.Add(Tr("tray.pause"), (*) => TogglePause())
    mnu.Add(Tr("tray.reload"), (*) => ReloadAll())
    mnu.Add(Tr("tray.exit"), (*) => ExitApp())
    mnu.Default := Tr("tray.settings")          ; Double-clicking the tray icon opens Settings
    if paused
        mnu.Check(Tr("tray.pause"))
    UpdateEngineMenus()
}
BuildTrayMenu()

SetEngine(kind, id, *) {
    IniWriteMany(ConfigFile(), [["Engine", kind, id]])
    LoadConfig()
    UpdateEngineMenus()
    Notify(Tr(kind = "word" ? "notify.word_engine_set" : "notify.sentence_engine_set", EngineName(id)))
}
UpdateEngineMenus() {
    global cfg, wordMenu, sentMenu
    for id in ENGINE_WORD_IDS
        (cfg["engine_word"] = id) ? wordMenu.Check(EngineName(id)) : wordMenu.Uncheck(EngineName(id))
    for id in ENGINE_SENTENCE_IDS
        (cfg["engine_sentence"] = id) ? sentMenu.Check(EngineName(id)) : sentMenu.Uncheck(EngineName(id))
}

TogglePause() {
    global paused
    paused := !paused
    if (paused)
        A_TrayMenu.Check(Tr("tray.pause"))
    else
        A_TrayMenu.Uncheck(Tr("tray.pause"))
    Notify(paused ? Tr("notify.paused") : Tr("notify.resumed"))
}

ReloadAll() {
    global cfg
    LoadConfig()
    RegisterHotkey()
    BuildTrayMenu()
    if (cfg["hy_mode"] = "startup")
        SetTimer(HyPreload, -100)
    Notify(Tr("notify.reloaded"))
}
RegisterHotkey()
SetTimer(TrackMouse, 50)
OnMessage(0x0201, OnGuiLButtonDown)
OnMessage(0x0202, OnSelRelease)               ; WM_LBUTTONUP: auto-copy after selecting text in the translation
OnMessage(0x0201, OnPopupClick)               ; WM_LBUTTONDOWN: clear the selection highlight when clicking elsewhere in the popup
HotIf(PopupSelHot)
Hotkey("$^c", CopyPopupHotkey)                ; Ctrl+C copies the selection when there is one in the popup and the mouse is over it
HotIf()
OnMessage(0x8003, (*) => (PopupSelHot() ? CopyPopupHotkey() : 0))   ; WM_APP+3: for automated tests, same as pressing the Ctrl+C above (script-synthesized keys don't trigger hook hotkeys)
OnMessage(0x8001, (*) => ShowBookmarks())     ; WM_APP+1: for automated tests, opens the bookmark window (tray menu items can't be clicked by a script)
OnMessage(0x8002, (*) => CheckOutsideNow(0))  ; WM_APP+2: for automated tests, triggers the "is the click outside the popup" check (script-synthesized clicks are not physical presses, so TrackMouse can't see them)
if (bmLoadNote != "")
    SetTimer(() => Notice(Tr("bm.title"), Tr("bm.err.load_heading"), bmLoadNote), -600)

Notify(Tr("notify.started", cfg["trigger_hotkey"]), "", 2)
if firstRun
    SetTimer(ShowWizard, -800)

; OnError callback: must be a named function, not a closure (AHK v2 restriction). (e, *) absorbs the extra arguments.
LogError(e, *) {
    try
        FileAppend("[" . A_Now . "] " . e.Message . " @ " . e.File . ":" . e.Line . "`n"
            , A_ScriptDir . "\error.log")
    return false    ; Return 0: still show the default error dialog; returning non-zero only logs without showing a dialog
}