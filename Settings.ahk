#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Settings window (#Include by Translator.ahk; opened from the tray menu "Settings…" or by double-clicking the tray icon)
; Created when opened and destroyed when closed, so it uses no resources otherwise. Save = write back to config.ini and apply immediately.
; API keys are never shown in the UI: DeepL → secret.txt, Microsoft → secret_microsoft.txt (the buttons open them in Notepad).
;=====================================================================

global setGui := 0
global setHyStat := 0       ; status text on the Hy-MT2 tab (refreshed after a model download)
global setHyEng := 0, setHyMod := 0, setHyDev := 0, setHyDevRow := []   ; engine / model in use, shown on the same tab

; [code, key in the language file]: the display name follows the current UI language
global SET_LANGS := [
    ["ZH", "lang.zh"], ["EN", "lang.en"], ["JA", "lang.ja"], ["KO", "lang.ko"],
    ["FR", "lang.fr"], ["DE", "lang.de"], ["ES", "lang.es"], ["RU", "lang.ru"]]
global SET_API_FREE := "https://api-free.deepl.com/v2/translate"
global SET_API_PRO  := "https://api.deepl.com/v2/translate"
global SET_HY_MODES := [["idle", "settings.hy.mode_idle"],
    ["startup", "settings.hy.mode_startup"], ["first", "settings.hy.mode_first"]]
; UI language options: [value in config.ini, text shown in the dropdown]; language names are written in their own language, the rest follow the UI language
SetUiLangItems() => [["auto", Tr("settings.ui_lang_auto")], ["zh", "简体中文"], ["en", "English"]]

ShowSettings(*) {
    global setGui, setHyStat, setHyEng, setHyMod, setHyDev, setHyDevRow, cfg, g_reg, ENGINE_WORD_IDS, ENGINE_SENTENCE_IDS, ECDICT_FALLBACK_IDS, SET_HY_MODES
    if (setGui != 0) {
        setGui.Show()
        return
    }
    ; Pause trigger hotkeys while the settings window is open; otherwise the Hotkey control cannot capture the current key combination (the global hotkey would intercept it)
    if (g_reg != "")
        try Hotkey(g_reg, "Off")

    local g := Gui("+AlwaysOnTop", Tr("settings.title"))
    g.SetFont("s10", "Microsoft YaHei")
    g.MarginX := 16, g.MarginY := 14
    local c := Map()
    local tab := g.Add("Tab3", "w500 h445", [Tr("settings.tab.general"), Tr("settings.tab.engines"), Tr("settings.tab.dict"), "Hy-MT2", "Microsoft", "DeepL"])

    ;---------------- General ----------------
    tab.UseTab(1)
    g.Add("Text", "x36 y60 w120", Tr("settings.hotkey"))
    c["hk"] := g.Add("Hotkey", "x160 y57 w200", HotkeyForControl(cfg["trigger_hotkey"]))
    SetHint(g, "x160 y+4 w320", Tr("settings.hotkey_hint"))
    g.Add("Text", "x36 y+14 w120", Tr("settings.ui_lang"))
    local uiItems := []
    for it in SetUiLangItems()
        uiItems.Push(it[2])
    c["uilang"] := g.Add("DropDownList", "x160 yp-3 w200", uiItems)
    c["uilang"].Value := 1
    for i, it in SetUiLangItems()
        if (it[1] = cfg["ui_lang"])
            c["uilang"].Value := i
    g.Add("Text", "x36 y+14 w120", Tr("settings.position"))
    c["pos"] := g.Add("DropDownList", "x160 yp-3 w200", [Tr("settings.position_near"), Tr("settings.position_center")])
    c["pos"].Value := (cfg["win_pos"] = "center") ? 2 : 1
    g.Add("Text", "x36 y+14 w120", Tr("settings.target_lang"))
    c["tgt"] := g.Add("DropDownList", "x160 yp-3 w200", LangNames(false))
    c["tgt"].Value := LangIndex(cfg["target_lang"], false)
    g.Add("Text", "x36 y+14 w120", Tr("settings.source_lang"))
    c["src"] := g.Add("DropDownList", "x160 yp-3 w200", LangNames(true))
    c["src"].Value := LangIndex(cfg["source_lang"], true)
    g.Add("Text", "x36 y+14 w120", Tr("settings.max_chars"))
    c["maxc"] := g.Add("Edit", "x160 yp-3 w90 Number", cfg["max_chars"])
    g.Add("Text", "x36 y+14 w120", Tr("settings.timeout"))
    c["tmo"] := g.Add("Edit", "x160 yp-3 w90 Number", cfg["net_timeout"])
    SetHint(g, "x+8 yp+4", Tr("settings.timeout_unit"))
    c["copy"] := g.Add("CheckBox", "x36 y+18 w450", Tr("settings.show_copy"))
    c["copy"].Value := (cfg["show_copy"] = "1")
    c["tips"] := g.Add("CheckBox", "x36 y+10 w450", Tr("settings.show_tips"))
    c["tips"].Value := (cfg["show_tips"] = "1")
    c["cos"] := g.Add("CheckBox", "x36 y+10 w450", Tr("settings.copy_on_select"))
    c["cos"].Value := (cfg["copy_on_select"] = "1")

    ;---------------- Engine ----------------
    tab.UseTab(2)
    g.Add("Text", "x36 y60 w120", Tr("settings.word_engine"))
    c["ew"] := g.Add("DropDownList", "x160 yp-3 w200", EngineNames(ENGINE_WORD_IDS))
    c["ew"].Value := IndexOf(ENGINE_WORD_IDS, cfg["engine_word"])
    g.Add("Text", "x36 y+16 w120", Tr("settings.sentence_engine"))
    c["es"] := g.Add("DropDownList", "x160 yp-3 w200", EngineNames(ENGINE_SENTENCE_IDS))
    c["es"].Value := IndexOf(ENGINE_SENTENCE_IDS, cfg["engine_sentence"])
    g.Add("Text", "x36 y+16 w120", Tr("settings.fallback"))
    c["fb"] := g.Add("DropDownList", "x160 yp-3 w200", FallbackNames())
    c["fb"].Value := IndexOf(ECDICT_FALLBACK_IDS, cfg["ecdict_fallback"])
    SetHint(g, "x36 y+22 w440", Tr("settings.engine_hint"))

    ;---------------- Dictionary ----------------
    tab.UseTab(3)
    c["phon"] := g.Add("CheckBox", "x36 y60 w450", Tr("settings.dict.phonetic"))
    c["phon"].Value := (cfg["dict_phonetic"] = "1")
    c["forms"] := g.Add("CheckBox", "x36 y+14 w450", Tr("settings.dict.forms"))
    c["forms"].Value := (cfg["dict_forms"] = "1")
    c["domain"] := g.Add("CheckBox", "x36 y+14 w450", Tr("settings.dict.domain"))
    c["domain"].Value := (cfg["dict_domain"] = "1")
    g.Add("Text", "x36 y+18 w120", Tr("settings.dict.max_senses"))
    c["max"] := g.Add("Edit", "x160 yp-3 w70 Number")
    g.Add("UpDown", "Range0-50", IsInteger(cfg["dict_max"]) ? Integer(cfg["dict_max"]) : 0)
    SetHint(g, "x+8 yp+4", Tr("settings.dict.max_hint"))
    SetHint(g, "x36 y+22 w440", Tr("settings.dict.note") . "`n"
        . (DictAvailable()
            ? Tr("settings.dict.ready", FormatThousands(DictCount()))
            : Tr("settings.dict.missing")))

    ;---------------- Hy-MT2 ----------------
    tab.UseTab(4)
    g.Add("Text", "x36 y60 w120", Tr("settings.hy.load_mode"))
    local modeNames := []
    for m in SET_HY_MODES
        modeNames.Push(Tr(m[2]))
    c["hymode"] := g.Add("DropDownList", "x160 yp-3 w300", modeNames)
    c["hymode"].Value := 1
    for i, m in SET_HY_MODES
        if (m[1] = cfg["hy_mode"])
            c["hymode"].Value := i
    g.Add("Text", "x36 y+16 w120", Tr("settings.hy.idle_time"))
    c["hyidle"] := g.Add("Edit", "x160 yp-3 w70 Number")
    g.Add("UpDown", "Range1-240", IsInteger(cfg["hy_idle"]) ? Integer(cfg["hy_idle"]) : 10)
    SetHint(g, "x+8 yp+4", Tr("settings.hy.idle_hint"))
    g.Add("Text", "x36 y+20 w120", Tr("settings.hy.status"))
    c["hystat"] := g.Add("Text", "x160 yp w320", HyStatusText())
    g.Add("Button", "x160 y+10 w110 h30", Tr("settings.hy.load_now")).OnEvent("Click", (*) => HyLoadNow(c))
    g.Add("Button", "x+10 yp w110 h30", Tr("settings.hy.unload")).OnEvent("Click", (*) => (HyStop(), c["hystat"].Value := HyStatusText()))
    setHyStat := c["hystat"]
    g.Add("Text", "x36 y+26 w120", Tr("settings.hy.engine"))
    setHyEng := g.Add("Text", "x160 yp w200 h40", HyEngineText())
    g.Add("Button", "x+8 yp-6 w104 h30", Tr("settings.hy.manage_btn")).OnEvent("Click", (*) => ShowEngineWin())
    g.Add("Text", "x36 y+22 w120", Tr("settings.hy.model"))
    setHyMod := g.Add("Text", "x160 yp w200 h40", HyModelText())
    g.Add("Button", "x+8 yp-6 w104 h30", Tr("settings.hy.manage_btn")).OnEvent("Click", (*) => ShowModelWin())
    ; Compute device row: only for the Vulkan engine (the one that can see several devices); shown and hidden by SettingsRefreshHy
    local devLbl := g.Add("Text", "x36 y+22 w120", Tr("settings.hy.device"))
    setHyDev := g.Add("Text", "x160 yp w200 h40", HyDeviceText())
    local devBtn := g.Add("Button", "x+8 yp-6 w104 h30", Tr("settings.hy.test_btn"))
    devBtn.OnEvent("Click", (*) => ShowSpeedWin())
    setHyDevRow := [devLbl, setHyDev, devBtn]
    SettingsShowDeviceRow()
    SetHint(g, "x36 y+16 w440", Tr("settings.hy.note"))

    ;---------------- Microsoft ----------------
    tab.UseTab(5)
    g.Add("Button", "x36 y60 w260 h30", Tr("settings.ms.edit_key")).OnEvent("Click", (*) => OpenSecret("secret_microsoft.txt"))
    g.Add("Text", "x36 y+18 w120", Tr("settings.ms.region"))
    c["msregion"] := g.Add("Edit", "x160 yp-3 w200", cfg["ms_region"])
    SetHint(g, "x36 y+18 w440", Tr("settings.ms.note"))

    ;---------------- DeepL ----------------
    tab.UseTab(6)
    g.Add("Text", "x36 y60 w120", Tr("settings.deepl.plan"))
    local apiItems := [Tr("settings.deepl.free"), Tr("settings.deepl.pro")]
    local apiSel := (cfg["api_url"] = SET_API_PRO) ? 2 : 1
    if (cfg["api_url"] != SET_API_FREE && cfg["api_url"] != SET_API_PRO) {
        apiItems.Push(Tr("settings.deepl.custom", cfg["api_url"]))
        apiSel := 3
    }
    c["api"] := g.Add("DropDownList", "x160 yp-3 w300", apiItems)
    c["api"].Value := apiSel
    g.Add("Button", "x36 y+20 w260 h30", Tr("settings.deepl.edit_key")).OnEvent("Click", (*) => OpenSecret())
    SetHint(g, "x36 y+14 w440", Tr("settings.deepl.note"))

    ;---------------- Bottom buttons ----------------
    tab.UseTab()
    g.Add("Button", "x16 y475 w120 h30", Tr("settings.reset")).OnEvent("Click", (*) => ResetSettings(c))
    g.Add("Button", "x324 y475 w92 h30 Default", Tr("settings.save")).OnEvent("Click", (*) => SaveSettings(c))
    g.Add("Button", "x424 y475 w92 h30", Tr("dlg.cancel")).OnEvent("Click", (*) => CloseSettings())
    g.OnEvent("Close", (*) => CloseSettings())
    g.OnEvent("Escape", (*) => CloseSettings())
    setGui := g
    g.Show("w532")
}

SetHint(g, opt, text) {
    g.SetFont("s8 c808080")
    local t := g.Add("Text", opt, text)
    g.SetFont("s10 cDefault")
    return t
}

FallbackNames() {
    global ECDICT_FALLBACK_IDS
    local out := []
    for id in ECDICT_FALLBACK_IDS
        out.Push(id = "none" ? Tr("settings.fallback_none") : EngineName(id))
    return out
}

EngineNames(ids) {
    local out := []
    for id in ids
        out.Push(EngineName(id))
    return out
}
IndexOf(arr, v) {
    for i, x in arr
        if (x = v)
            return i
    return 1
}

; The compute-device row (and its speed-test button) is only useful with the Vulkan engine
SettingsShowDeviceRow() {
    global setHyDevRow
    for ctl in setHyDevRow
        try ctl.Visible := (EngineInUse() = "vulkan")
}

; Called by the model window after it installed something
SettingsRefreshHy() {
    global setGui, setHyStat, setHyEng, setHyMod, setHyDev
    if (setGui != 0 && setHyStat != 0) {
        try setHyStat.Value := HyStatusText()
        try setHyEng.Value := HyEngineText()
        try setHyMod.Value := HyModelText()
        try setHyDev.Value := HyDeviceText()
        SettingsShowDeviceRow()
    }
}

HyLoadNow(c) {
    c["hystat"].Value := Tr("settings.hy.loading")
    try {
        HyEnsure()
        c["hystat"].Value := HyStatusText()
    } catch as e {
        c["hystat"].Value := Tr("settings.hy.load_failed")
        MsgBox(Tr("settings.hy.load_failed_msg", e.Message), Tr("settings.msg_title"), 0x10)
    }
}

CloseSettings() {
    global setGui, g_reg, setHyStat, setHyEng, setHyMod, setHyDev, setHyDevRow
    if (setGui != 0) {
        try setGui.Destroy()
        setGui := 0
        setHyStat := 0, setHyEng := 0, setHyMod := 0, setHyDev := 0, setHyDevRow := []
    }
    if (g_reg != "")
        try Hotkey(g_reg, "On")
}

SaveSettings(c) {
    global cfg, g_reg, SET_API_FREE, SET_API_PRO, SET_HY_MODES, ENGINE_WORD_IDS, ENGINE_SENTENCE_IDS, ECDICT_FALLBACK_IDS
    ; Hotkey: if the control is empty (an unmodified Win-key hotkey control cannot display it), keep the original value
    local hk := c["hk"].Value
    if (hk = "")
        hk := cfg["trigger_hotkey"]
    if !RegExMatch(hk, "[\^!+#]") {
        MsgBox(Tr("settings.err.modifier"), Tr("settings.msg_title"), 0x30)
        return
    }
    local maxc := c["maxc"].Value, tmo := c["tmo"].Value
    if (!IsInteger(maxc) || maxc < 100 || !IsInteger(tmo) || tmo < 1000) {
        MsgBox(Tr("settings.err.limits"), Tr("settings.msg_title"), 0x30)
        return
    }
    ; Register the new hotkey first; if that fails, keep the old hotkey and do not save
    if (hk != g_reg) {
        try {
            Hotkey(hk, OnTranslate, "Off")
        } catch as e {
            MsgBox(Tr("settings.err.hotkey", hk, e.Message), Tr("settings.msg_title"), 0x10)
            return
        }
        if (g_reg != "")
            try Hotkey(g_reg, "Off")
        g_reg := hk
    }
    local api := (c["api"].Value = 1) ? SET_API_FREE : (c["api"].Value = 2) ? SET_API_PRO : cfg["api_url"]
    local uiLang := SetUiLangItems()[c["uilang"].Value][1]
    IniWriteMany(ConfigFile(), [
        ["UI", "language", uiLang],
        ["API", "api_url", api],
        ["Lang", "target_lang", LangCode(c["tgt"].Value, false)],
        ["Lang", "source_lang", LangCode(c["src"].Value, true)],
        ["Hotkey", "trigger", hk],
        ["Behavior", "window_position", c["pos"].Value = 2 ? "center" : "cursor"],
        ["Behavior", "show_copy_button", c["copy"].Value ? "1" : "0"],
        ["Behavior", "show_tray_tips", c["tips"].Value ? "1" : "0"],
        ["Behavior", "copy_on_select", c["cos"].Value ? "1" : "0"],
        ["Behavior", "max_chars", maxc],
        ["Behavior", "network_timeout", tmo],
        ["Engine", "word", ENGINE_WORD_IDS[c["ew"].Value]],
        ["Engine", "sentence", ENGINE_SENTENCE_IDS[c["es"].Value]],
        ["Engine", "ecdict_fallback", ECDICT_FALLBACK_IDS[c["fb"].Value]],
        ["Hy", "load_mode", SET_HY_MODES[c["hymode"].Value][1]],
        ["Hy", "idle_minutes", IsInteger(c["hyidle"].Value) && c["hyidle"].Value > 0 ? c["hyidle"].Value : "10"],
        ["Microsoft", "region", Trim(c["msregion"].Value)],
        ["Dict", "show_phonetic", c["phon"].Value ? "1" : "0"],
        ["Dict", "show_forms", c["forms"].Value ? "1" : "0"],
        ["Dict", "show_domain", c["domain"].Value ? "1" : "0"],
        ["Dict", "max_senses", IsInteger(c["max"].Value) ? c["max"].Value : "0"]])
    LoadConfig()                ; also switch the UI language per the new [UI] language value
    BuildTrayMenu()             ; refresh the tray menu text for the new language
    CloseSettings()     ; re-enables g_reg (i.e. the new hotkey)
    if (cfg["hy_mode"] = "startup")
        SetTimer(HyPreload, -100)
    Notify(Tr("notify.settings_saved"))
}

; Only resets the values on screen; they are written when Save is clicked (the Microsoft section is not reset, to avoid accidental deletion)
ResetSettings(c) {
    c["hk"].Value := "^+X"
    c["uilang"].Value := 1
    c["pos"].Value := 1
    c["copy"].Value := 1
    c["tips"].Value := 1
    c["cos"].Value := 1
    c["tgt"].Value := LangIndex("ZH", false)
    c["src"].Value := LangIndex("", true)
    c["maxc"].Value := 5000
    c["tmo"].Value := 10000
    c["ew"].Value := 1          ; ECDICT
    c["es"].Value := 1          ; Hy-MT2
    c["fb"].Value := 1          ; no switch
    c["phon"].Value := 1, c["forms"].Value := 1, c["domain"].Value := 0
    c["max"].Value := 0
    c["hymode"].Value := 1
    c["hyidle"].Value := 10
    c["api"].Value := 1
}

OpenSecret(file := "secret.txt") {
    local path := AppDir() . "\" . file
    if !FileExist(path)
        FileAppend("", path, "UTF-8-RAW")
    Run('notepad.exe "' . path . '"')
}

; The Hotkey control does not support the Win key: hotkeys containing # are not pre-filled (an empty value on save = keep the original hotkey)
HotkeyForControl(hk) => InStr(hk, "#") ? "" : hk

LangNames(withAuto) {
    global SET_LANGS
    local out := withAuto ? [Tr("settings.lang_auto")] : []
    for l in SET_LANGS
        out.Push(Tr(l[2]) . " (" . l[1] . ")")
    return out
}
LangIndex(code, withAuto) {
    global SET_LANGS
    if (withAuto && code = "")
        return 1
    for i, l in SET_LANGS
        if (l[1] = code)
            return i + (withAuto ? 1 : 0)
    return 1
}
LangCode(index, withAuto) {
    global SET_LANGS
    if (withAuto) {
        if (index <= 1)
            return ""
        index -= 1
    }
    return SET_LANGS[index][1]
}

FormatThousands(n) => RegExReplace(n, "\G\d+?(?=(\d{3})+$)", "$0,")

; Batch-write config.ini: replace key=value line by line, preserving comments, order and UTF-8 encoding.
; IniWrite is not used: it goes through Windows ANSI read/write, which would corrupt Chinese comments in a UTF-8 file.
IniWriteMany(file, items) {
    local txt := FileExist(file) ? FileRead(file, "UTF-8") : ""
    local eol := InStr(txt, "`r`n") ? "`r`n" : "`n"
    local lines := StrSplit(StrReplace(txt, "`r`n", "`n"), "`n")
    for it in items {
        local sec := it[1], key := it[2], val := it[3]
        local cur := "", secEnd := 0, done := false
        for i, ln in lines {
            if RegExMatch(ln, "^\s*\[(.+?)\]\s*$", &m) {
                cur := m[1]
                continue
            }
            if (cur = sec) {
                if RegExMatch(ln, "^\s*\Q" . key . "\E\s*=") {
                    lines[i] := key . "=" . val
                    done := true
                    break
                }
                if (Trim(ln) != "")
                    secEnd := i
            }
        }
        if done
            continue
        if (secEnd > 0) {
            lines.InsertAt(secEnd + 1, key . "=" . val)
        } else {
            ; Section not present: append to the end of the file
            while (lines.Length && Trim(lines[lines.Length]) = "")
                lines.Pop()
            lines.Push("", "[" . sec . "]", key . "=" . val, "")
        }
    }
    local out := ""
    for i, ln in lines
        out .= ln . (i < lines.Length ? eol : "")
    local f := FileOpen(file, "w", "UTF-8")    ; written with a BOM, matching the original file
    f.Write(out)
    f.Close()
}
