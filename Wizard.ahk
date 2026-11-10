#Include %A_LineFile%\..\ModelWin.ahk
;=====================================================================
; Wizard.ahk - first-run setup guide. Shown once on a fresh install (no config.ini yet) and
; reachable later from the tray menu ("Setup guide...").
;
;   1. Language      the very first question; applied immediately so the rest is in that language
;   2. Sentences     local model (opens the engine and model windows) / online engine / dictionary only
;   3. How it works  what the hotkey does
;   4. Done
;
; Closing the window at any point counts as finished: it will not come back by itself.
;=====================================================================

global wizGui := 0, wizPage := 1, wizCtl := Map()
global wizChoice := "local"        ; "local" | "online" | "none"
global wizOnline := "deepl"        ; "deepl" | "microsoft"

ShowWizard(*) {
    global wizGui, wizPage, wizChoice, wizOnline
    if (wizGui != 0) {
        wizGui.Show()
        return
    }
    wizPage := 1
    wizChoice := "local"
    wizOnline := "deepl"
    WizBuild()
}

; (Re)build the window for the current page
WizBuild() {
    global wizGui, wizPage, wizCtl, wizChoice, wizOnline, cfg, I18N_LANG
    local pos := ""
    if (wizGui != 0) {
        local x := 0, y := 0
        wizGui.GetPos(&x, &y)
        pos := " x" . x . " y" . y
        try wizGui.Destroy()
    }
    local g := Gui("+AlwaysOnTop", Tr("wiz.title"))
    g.SetFont("s10", "Microsoft YaHei")
    g.MarginX := 24, g.MarginY := 20
    wizCtl := Map()
    local last := (wizPage = 4)

    g.SetFont("s9 norm c808080")
    g.Add("Text", "x24 y16 w472", (wizPage = 1) ? "" : Tr("wiz.step", wizPage - 1, 3))
    g.SetFont("s14 bold cDefault")

    switch wizPage {
        case 1:
            ; Both languages on purpose: the user has not chosen one yet
            g.Add("Text", "x24 y+2 w472", "Welcome  /  欢迎")
            g.SetFont("s10 norm c555555")
            g.Add("Text", "x24 y+10 w472", "Choose the language of the interface.`n请选择界面语言。")
            g.SetFont("s11 norm cDefault")
            wizCtl["en"] := g.Add("Radio", "x40 y+18 w440", "English")
            wizCtl["zh"] := g.Add("Radio", "x40 y+10 w440", "简体中文")
            wizCtl[I18N_LANG = "zh" ? "zh" : "en"].Value := 1
            g.SetFont("s9 norm c808080")
            g.Add("Text", "x24 y+16 w472", "You can change it later in Settings.  /  以后可以在设置里修改。")
        case 2:
            g.Add("Text", "x24 y+2 w472", Tr("wiz.sent.title"))
            g.SetFont("s10 norm c555555")
            g.Add("Text", "x24 y+8 w472", Tr("wiz.sent.intro"))
            g.SetFont("s10 norm cDefault")
            ; The three radios must be consecutive controls, otherwise Windows treats them as separate groups.
            ; Each carries its explanation on a second line.
            wizCtl["local"] := g.Add("Radio", "x40 y+14 w450 h52", Tr("wiz.sent.local") . "`n" . WizLocalNote())
            wizCtl["online"] := g.Add("Radio", "x40 y+6 w450 h52", Tr("wiz.sent.online") . "`n" . Tr("wiz.sent.online_note"))
            wizCtl["none"] := g.Add("Radio", "x40 y+6 w450 h52", Tr("wiz.sent.none") . "`n" . Tr("wiz.sent.none_note"))
            wizCtl[wizChoice].Value := 1
            g.Add("Text", "x40 y+12 w140", Tr("wiz.sent.online_pick"))
            wizCtl["onlinepick"] := g.Add("DropDownList", "x+0 yp-4 w260", ["DeepL", "Microsoft (" . Tr("wiz.experimental") . ")"])
            wizCtl["onlinepick"].Value := (wizOnline = "microsoft") ? 2 : 1
            wizCtl["onlinepick"].Enabled := (wizChoice = "online")
            for id in ["local", "online", "none"]
                wizCtl[id].OnEvent("Click", (*) => WizSyncChoice())
        case 3:
            g.Add("Text", "x24 y+2 w472", Tr("wiz.how.title"))
            g.SetFont("s10 norm c333333")
            g.Add("Text", "x24 y+12 w472", Tr("wiz.how.body", WizHotkeyName()))
        case 4:
            g.Add("Text", "x24 y+2 w472", Tr("wiz.done.title"))
            g.SetFont("s10 norm c333333")
            g.Add("Text", "x24 y+12 w472", WizDoneText())
    }

    ; ---- buttons ----
    g.SetFont("s10 norm cDefault")
    local btnY := "y+26"
    if (wizPage > 1) {
        wizCtl["back"] := g.Add("Button", "x24 " . btnY . " w100 h32", Tr("wiz.back"))
        wizCtl["back"].OnEvent("Click", (*) => WizGo(-1))
    }
    if (wizPage = 4 && wizChoice = "online") {
        wizCtl["settings"] := g.Add("Button", "x+10 " . (wizPage > 1 ? "yp" : btnY) . " w200 h32", Tr("wiz.open_settings"))
        wizCtl["settings"].OnEvent("Click", (*) => WizFinish(true))
    }
    wizCtl["next"] := g.Add("Button", "x376 " . (wizPage > 1 ? "yp" : btnY) . " w120 h32 Default",
        last ? Tr("wiz.finish") : (wizPage = 1 ? "Next  /  下一步" : (wizPage = 2 && wizChoice = "local" ? Tr("wiz.next_download") : Tr("wiz.next"))))
    wizCtl["next"].OnEvent("Click", (*) => WizGo(1))
    g.OnEvent("Close", (*) => WizFinish(false))
    g.OnEvent("Escape", (*) => WizFinish(false))
    wizGui := g
    g.Show("w520" . pos)
}

WizHotkeyName() {
    global cfg
    local hk := cfg.Has("trigger_hotkey") ? cfg["trigger_hotkey"] : "^+x"
    local s := ""
    for part in [["^", "Ctrl"], ["!", "Alt"], ["+", "Shift"], ["#", "Win"]]
        if InStr(hk, part[1])
            s .= part[2] . "+"
    return s . StrUpper(RegExReplace(hk, "[\^!+#]"))
}

; One line about what the local model would need on this PC
WizLocalNote() {
    try {
        local hw := DetectHardware()
        local rec := RecommendRuntime(hw, MfRuntime("cuda12")["min_nvidia_driver"])
        local md := MfModel(RecommendModel(hw, rec["id"]))
        local rt := MfRuntime(rec["id"])
        return Tr("wiz.sent.local_note", FormatBytes(MfRuntimeBytes(rt) + md["size"]))
    }
    return Tr("wiz.sent.local_note_plain")
}

; Keep the choice variables in step with the radio buttons (the window is rebuilt when paging)
WizSyncChoice() {
    global wizCtl, wizChoice
    for id in ["local", "online", "none"]
        if (wizCtl.Has(id) && wizCtl[id].Value)
            wizChoice := id
    if wizCtl.Has("onlinepick")
        wizCtl["onlinepick"].Enabled := (wizChoice = "online")
    if wizCtl.Has("next")
        wizCtl["next"].Text := (wizChoice = "local") ? Tr("wiz.next_download") : Tr("wiz.next")
}

WizDoneText() {
    global wizChoice, wizOnline
    local s := Tr("wiz.done.words") . "`n`n"
    switch wizChoice {
        case "local":
            s .= FileExist(HyServerPath()) && FileExist(HyModelPath()) ? Tr("wiz.done.local_ready") : Tr("wiz.done.local_later")
        case "online":
            s .= Tr("wiz.done.online", wizOnline = "microsoft" ? "Microsoft" : "DeepL")
        default:
            s .= Tr("wiz.done.none")
    }
    return s . "`n`n" . Tr("wiz.done.tray")
}

; dir = +1 next, -1 back
WizGo(dir) {
    global wizPage, wizCtl, wizChoice, wizOnline, wizGui
    if (dir < 0) {
        wizPage := Max(1, wizPage - 1)
        WizBuild()
        return
    }
    switch wizPage {
        case 1:
            ; Apply the language right away so every following page is in it
            local code := wizCtl["zh"].Value ? "zh" : "en"
            try IniWriteMany(ConfigFile(), [["UI", "language", code]])
            LoadConfig()
            BuildTrayMenu()
        case 2:
            wizOnline := (wizCtl["onlinepick"].Value = 2) ? "microsoft" : "deepl"
            WizSyncChoice()
            if (wizChoice = "online") {
                try IniWriteMany(ConfigFile(), [["Engine", "sentence", wizOnline]])
            } else if (wizChoice = "local") {
                try IniWriteMany(ConfigFile(), [["Engine", "sentence", "hy"]])
            }
            if (wizChoice = "local") {
                ; open the model window on top; come back to the last page when it closes
                wizGui.Opt("+Disabled")
                ShowEngineWin(Map("wizard", true, "onClose", WizEngineClosed))
                return
            }
        case 4:
            WizFinish(false)
            return
    }
    wizPage += 1
    WizBuild()
}

; The engine window closes first; the model window follows, and the wizard continues after that
WizEngineClosed() {
    ShowModelWin(Map("wizard", true, "onClose", WizModelClosed))
}

WizModelClosed() {
    global wizGui, wizPage
    if (wizGui = 0)
        return
    wizGui.Opt("-Disabled")
    wizPage := 3
    WizBuild()
}

; Close the wizard; remember that it has been shown. openSettings = also open the Settings window.
WizFinish(openSettings) {
    global wizGui
    try IniWriteMany(ConfigFile(), [["Setup", "completed", "1"]])
    if (wizGui != 0) {
        try wizGui.Destroy()
        wizGui := 0
    }
    if openSettings
        ShowSettings()
}
