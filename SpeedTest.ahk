;=====================================================================
; SpeedTest.ahk - "Speed test" window of the local translation model.
; Lists every compute device the installed inference engine can see (plus "CPU only"), translates one fixed
; sentence on each with the engine and model currently in use, and lets the user make the fastest one the default
; ([Hy] device / device_name in config.ini). The test never touches the running translation service: it stops it
; first and uses its own temporary llama-server on port + 1.
;
;   ShowSpeedWin()   opened from Settings -> Hy-MT2
;   HyDeviceText()   one-line description of the device setting (Settings tab)
;=====================================================================

global ST := Map("gui", 0)       ; state of the open speed-test window

ST_SENTENCE := "The quick brown fox jumps over the lazy dog while the sun sets slowly behind the distant mountains."

HyDeviceText() {
    global cfg
    local d := cfg["hy_device"]
    if (d = "cpu")
        return Tr("st.cpu")
    if !HyDeviceValid(d)
        return Tr("st.auto")
    local n := cfg["hy_device_name"]
    return (n = "") ? d : n . " (" . d . ")"
}

; Devices the engine reports: [Map("id", "Vulkan0", "name", "NVIDIA GeForce RTX 4050 Laptop GPU"), ...]
StListDevices(server) {
    local out := A_Temp . "\seltr_devices_" . A_TickCount . ".txt"
    local devs := []
    try {
        SplitPath(server, , &dir)
        RunWait(A_ComSpec . ' /c ""' . server . '" --list-devices > "' . out . '" 2>&1"', dir, "Hide")
        local txt := FileRead(out, "UTF-8")
        local inList := false
        for ln in StrSplit(txt, "`n", "`r") {
            if InStr(ln, "Available devices")
                inList := true
            else if (inList && RegExMatch(ln, "^\s+(\w+):\s+(.+?)\s*(\(\d+ MiB.*)?$", &m))
                devs.Push(Map("id", m[1], "name", m[2]))
        }
    }
    try FileDelete(out)
    return devs
}

; Starts a temporary llama-server for one device, translates the test sentence three times (one warm-up) and
; returns the average generation speed in tokens per second; throws on failure or cancel
StBenchOne(device) {
    global cfg, ST, ST_SENTENCE
    local server := HyServerPath(), model := HyModelPath()
    local port := Integer(cfg["hy_port"]) + 1, key := HyRandomKey()
    local cmd := '"' . server . '" -m "' . model . '" --host 127.0.0.1 --port ' . port
        . " -c 4096 -np 1 --jinja --no-webui --api-key " . key . HyOffloadArgs(device)
    local pid := 0
    SplitPath(server, , &dir)
    Run(cmd, dir, "Hide", &pid)
    HyBindToJob(pid)
    try {
        local deadline := A_TickCount + 90000, ready := false
        while (A_TickCount < deadline) {
            Sleep(250)
            if ST["cancel"]
                throw Error("cancel")
            if !ProcessExist(pid)
                throw Error("exited")
            try ready := (HttpSend("GET", "http://127.0.0.1:" . port . "/health", Map(), "", 1500)["status"] = 200)
            if ready
                break
        }
        if !ready
            throw Error("timeout")
        local prompt := "将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：`n`n" . ST_SENTENCE
        local body := '{"messages":[{"role":"user","content":' . JsonStr(prompt) . '}],"temperature":0,"max_tokens":200,"stream":false}'
        local sum := 0, n := 0
        loop 3 {
            if ST["cancel"]
                throw Error("cancel")
            local r := HttpSend("POST", "http://127.0.0.1:" . port . "/v1/chat/completions",
                Map("Content-Type", "application/json; charset=UTF-8", "Authorization", "Bearer " . key), body, 60000)
            if (r["status"] != 200)
                throw Error("http " . r["status"])
            if (A_Index = 1)
                continue                       ; warm-up: not counted
            local v := JsonGet(JsonParse(r["text"]), "timings", "predicted_per_second")
            if !IsNumber(v)
                throw Error("no timings")
            sum += v, n += 1
        }
        return sum / n
    } finally {
        try ProcessClose(pid)
        try ProcessWaitClose(pid, 5)
    }
}

ShowSpeedWin() {
    global ST, cfg
    if (ST["gui"] != 0) {
        ST["gui"].Show()
        return
    }
    if (!FileExist(HyServerPath()) || !FileExist(HyModelPath())) {
        MsgBox(Tr("st.need_files"), Tr("st.title"), 0x30)
        return
    }
    local cands := StListDevices(HyServerPath())
    if (cands.Length = 0) {
        MsgBox(Tr("st.no_choice"), Tr("st.title"), 0x40)
        return
    }
    cands.Push(Map("id", "cpu", "name", Tr("st.cpu")))
    ST := Map("gui", 0, "ctl", Map(), "running", false, "cancel", false, "closing", false, "cands", cands, "best", 0)
    local c := ST["ctl"]

    local g := Gui("+AlwaysOnTop", Tr("st.title"))
    g.SetFont("s10", "Microsoft YaHei")
    g.MarginX := 18, g.MarginY := 14
    g.SetFont("s12 bold")
    g.Add("Text", "x18 y14 w524", Tr("st.title"))
    g.SetFont("s9 norm c555555")
    g.Add("Text", "x18 y+6 w524 h54", Tr("st.intro"))
    g.SetFont("s9 norm c333333")
    g.Add("Text", "x18 y+6 w524", Tr("st.engine", HyEngineText()))
    c["cur"] := g.Add("Text", "x18 y+4 w524", Tr("st.current", HyDeviceText()))
    g.SetFont("s10 norm cDefault")
    c["lv"] := g.Add("ListView", "x18 y+10 w524 r" . Min(Max(cands.Length, 3), 6) . " -Multi NoSortHdr",
        [Tr("st.col.device"), Tr("st.col.speed"), Tr("st.col.result")])
    for cd in cands
        c["lv"].Add("", StDeviceLabel(cd), "", "")
    c["lv"].ModifyCol(1, 350), c["lv"].ModifyCol(2, 80), c["lv"].ModifyCol(3, 85)
    g.SetFont("s9 norm c333333")
    c["status"] := g.Add("Text", "x18 y+10 w524 h40", "")
    g.SetFont("s10 norm cDefault")
    c["start"] := g.Add("Button", "x18 y+10 w120 h32", Tr("st.btn.start"))
    c["start"].OnEvent("Click", (*) => StStart())
    c["apply"] := g.Add("Button", "x+8 yp w130 h32 Disabled", Tr("st.btn.apply"))
    c["apply"].OnEvent("Click", (*) => StApply())
    c["auto"] := g.Add("Button", "x+8 yp w130 h32", Tr("st.btn.auto"))
    c["auto"].OnEvent("Click", (*) => StAuto())
    c["close"] := g.Add("Button", "x442 yp w100 h32", Tr("mgr.btn.close"))
    c["close"].OnEvent("Click", (*) => StClose())
    g.OnEvent("Close", (*) => StClose())
    g.OnEvent("Escape", (*) => StClose())
    ST["gui"] := g
    g.Show("w560")
}

; "NVIDIA GeForce RTX 4050 Laptop GPU [Vulkan0]"
StDeviceLabel(cd) => (cd["id"] = "cpu") ? cd["name"] : cd["name"] . " [" . cd["id"] . "]"

StStart() {
    global ST, busy
    if (ST["running"] || busy)
        return
    busy := true                                  ; no translation may start a second server during the test
    local c := ST["ctl"], cands := ST["cands"]
    try HyStop()                                  ; free the port and the graphics memory
    ST["running"] := true, ST["cancel"] := false, ST["best"] := 0
    c["start"].Enabled := false, c["apply"].Enabled := false, c["auto"].Enabled := false
    local bestV := 0
    for i, cd in cands {
        c["lv"].Modify(i, "", StDeviceLabel(cd), "", "")
    }
    for i, cd in cands {
        if ST["cancel"]
            break
        c["status"].Value := Tr("st.running", cd["name"], i, cands.Length)
        local v := 0
        try v := StBenchOne(cd["id"])
        if ST["cancel"]
            break
        cd["speed"] := v
        c["lv"].Modify(i, "", StDeviceLabel(cd), v > 0 ? Format("{:.0f} tok/s", v) : "-", v > 0 ? "" : Tr("st.failed"))
        if (v > bestV) {
            bestV := v
            ST["best"] := i
        }
    }
    ST["running"] := false
    busy := false
    if ST["closing"] {
        StDestroy()
        return
    }
    c["start"].Enabled := true, c["auto"].Enabled := true
    if ST["cancel"] {
        c["status"].Value := Tr("st.cancelled")
        return
    }
    if (ST["best"] = 0) {
        c["status"].Value := Tr("st.nothing")
        return
    }
    local b := cands[ST["best"]]
    c["lv"].Modify(ST["best"], "", StDeviceLabel(b), Format("{:.0f} tok/s", b["speed"]), "★ " . Tr("st.fastest"))
    c["status"].Value := Tr("st.done", b["name"], Format("{:.0f}", b["speed"]))
    c["apply"].Enabled := true
}

StApply() {
    global ST
    if (ST["running"] || ST["best"] = 0)
        return
    local b := ST["cands"][ST["best"]]
    StSave(b["id"], b["id"] = "cpu" ? "" : b["name"])
    ST["ctl"]["status"].Value := Tr("st.applied", HyDeviceText())
}

StAuto() {
    global ST
    if ST["running"]
        return
    StSave("", "")
    ST["ctl"]["status"].Value := Tr("st.reset")
}

StSave(id, name) {
    global ST
    IniWriteMany(ConfigFile(), [["Hy", "device", id], ["Hy", "device_name", name]])
    LoadConfig()
    try HyStop()                                  ; the next translation starts with the new device
    try ST["ctl"]["cur"].Value := Tr("st.current", HyDeviceText())
    try SettingsRefreshHy()
}

StClose() {
    global ST
    if ST["running"] {
        ST["cancel"] := true, ST["closing"] := true
        return
    }
    StDestroy()
}

StDestroy() {
    global ST
    try ST["gui"].Destroy()
    ST["gui"] := 0
}
