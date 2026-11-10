#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Hy-MT2 local translation model (#Included by Translator.ahk)
; Runs llama.cpp's llama-server hidden in the background (the engine and device chosen in Settings), listening on 127.0.0.1 only,
; Translates via the OpenAI-compatible /v1/chat/completions endpoint. Prompt and sampling parameters follow Tencent's official recommendations.
; Load mode (config.ini [Hy] load_mode):
;   idle    = start on first translation, stop after idle_minutes of inactivity (default)
;   startup = start with the program, stay resident
;   first   = start on first translation, then stay resident
;=====================================================================

global hyPid := 0          ; llama-server process started by this program
global hyLastUse := 0      ; Last-use time (A_TickCount), used for idle unloading
global hyApiKey := ""      ; Randomly generated on each start: stops web pages in the browser from calling the local model server cross-origin

; Relative paths are resolved against this file's directory (project root); shared by the main program and test scripts
HyDir() {
    local dir := AppDir()
    return dir
}
HyPath(p) => RegExMatch(p, "^[A-Za-z]:\\|^\\\\") ? p : HyDir() . "\" . p
HyServerPath() => HyPath(cfg["hy_server"])
HyModelPath() => HyPath(cfg["hy_model"])
HyLogPath() => HyDir() . "\hy_server.log"
HyBase() => "http://127.0.0.1:" . cfg["hy_port"]

HyIsRunning() => (hyPid != 0 && ProcessExist(hyPid))

HyHealthy() {
    try return HttpSend("GET", HyBase() . "/health", Map(), "", 1500)["status"] = 200
    return false
}

; Status text shown in the settings window
HyStatusText() {
    if !FileExist(HyServerPath())
        return Tr("hy.status.no_server", cfg["hy_server"])
    if !FileExist(HyModelPath())
        return Tr("hy.status.no_model", cfg["hy_model"])
    return HyIsRunning() ? Tr("hy.status.loaded", hyPid) : Tr("hy.status.unloaded")
}

; Device ids come from llama-server's own list (e.g. Vulkan0, CUDA0); "cpu" = no offloading; "" = let the engine decide
HyDeviceValid(d) => (d != "" && RegExMatch(d, "^\w+$"))

HyOffloadArgs(device := "<cfg>") {
    global cfg
    if (device = "<cfg>")
        device := cfg["hy_device"]
    if (device = "cpu")
        return " --device none -ngl 0"
    if HyDeviceValid(device)
        return " --device " . device . " -ngl 99"
    return " -ngl " . cfg["hy_gpu_layers"]
}

; Ensures the service is available; throws an Error with the exact cause on failure
; device: "<cfg>" = the saved device; "" = let the engine decide (used when the saved device can no longer start)
HyEnsure(device := "<cfg>") {
    global hyPid, hyLastUse, hyApiKey, cfg
    hyLastUse := A_TickCount          ; Loading counts as in use, so the idle check does not shut it down
    if HyIsRunning() {
        if HyHealthy()
            return
        HyStop()                      ; Process still exists but does not respond: restart it
    }
    local server := HyServerPath(), model := HyModelPath()
    if !FileExist(server)
        throw Error(Tr("hy.err.no_server", server))
    if !FileExist(model)
        throw Error(Tr("hy.err.no_model", model))
    HyKillOrphans()
    try FileDelete(HyLogPath())
    SplitPath(server, , &dir)
    hyApiKey := HyRandomKey()
    local cmd := '"' . server . '" -m "' . model . '" --host 127.0.0.1 --port ' . cfg["hy_port"]
        . " -c 4096 -np 1 --jinja --no-webui --api-key " . hyApiKey . HyOffloadArgs(device)
        . ' --log-file "' . HyLogPath() . '"'
    local pid := 0
    try Run(cmd, dir, "Hide", &pid)
    catch as e
        throw Error(Tr("hy.err.start", e.Message))
    hyPid := pid
    HyBindToJob(pid)
    local deadline := A_TickCount + 90000
    while (A_TickCount < deadline) {
        Sleep(300)
        if !ProcessExist(pid) {
            hyPid := 0
            ; A saved device can disappear (new driver or graphics card): fall back to automatic for this start, the setting is kept
            if (device = "<cfg>" && cfg["hy_device"] != "cpu" && HyDeviceValid(cfg["hy_device"]))
                return HyEnsure("")
            throw Error(Tr("hy.err.start_failed", HyLogReason()))
        }
        if HyHealthy() {
            hyLastUse := A_TickCount
            return
        }
    }
    HyStop()
    throw Error(Tr("hy.err.load_timeout", HyLogReason()))
}

; Picks the llama-server log lines that best explain the failure
HyLogReason() {
    local txt := ""
    try txt := FileRead(HyLogPath(), "UTF-8")
    if (txt = "")
        return Tr("hy.log.empty", HyLogPath())
    local hits := [], last := ""
    for ln in StrSplit(txt, "`n", "`r") {
        ln := Trim(ln)
        if (ln = "")
            continue
        last := ln
        if RegExMatch(ln, "i)error|fail|unable|out of memory|cannot|couldn't|bind|no cuda|driver")
            hits.Push(ln)
    }
    local out := ""
    if (hits.Length = 0)
        out := last
    else
        loop Min(hits.Length, 2)
            out .= (out = "" ? "" : "`n") . hits[hits.Length - Min(hits.Length, 2) + A_Index]
    return SubStr(out, 1, 300) . "`n" . Tr("hy.log.full")
}

HyTranslate(text, tgtOverride := "") {
    global cfg, hyLastUse
    HyEnsure()
    local tgt := EngTarget(tgtOverride)
    local prompt := (tgt = "ZH")
        ? "将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：`n`n" . text
        : "Translate the following text into " . HyLangName(tgt)
            . ". Note that you should only output the translated result without any additional explanation:`n`n" . text
    local body := '{"messages":[{"role":"user","content":' . JsonStr(prompt) . '}],'
        . '"temperature":0.7,"top_p":0.6,"top_k":20,"repeat_penalty":1.05,"max_tokens":4096,"stream":false}'
    local r := 0
    try r := HttpSend("POST", HyBase() . "/v1/chat/completions",
        Map("Content-Type", "application/json; charset=UTF-8", "Authorization", "Bearer " . hyApiKey),
        body, 120000)
    catch as e {
        if !HyIsRunning()
            throw Error(Tr("hy.err.exited", HyLogReason()))
        throw Error("Hy-MT2 " . e.Message)
    }
    hyLastUse := A_TickCount
    if (r["status"] != 200)
        throw Error(Tr("eng.http", "Hy-MT2", r["status"], ApiErrorMessage(r["text"])))
    local out := ""
    try out := JsonGet(JsonParse(r["text"]), "choices", 1, "message", "content")
    out := Trim(RegExReplace(out, "s)<think>.*?</think>"), " `t`r`n")
    if (out = "")
        throw Error(Tr("hy.err.empty"))
    return out
}

HyRandomKey() {
    local k := ""
    loop 32
        k .= Format("{:x}", Random(0, 15))
    return k
}

; Official requirement: use the full English language name in the English prompt
HyLangName(code) {
    static m := Map("EN", "English", "JA", "Japanese", "KO", "Korean", "FR", "French",
        "DE", "German", "ES", "Spanish", "RU", "Russian", "ZH", "Chinese")
    return m.Has(code) ? m[code] : code
}

; Put llama-server into a job object that terminates it when this process closes:
; Even if the translator is force-killed via Task Manager/taskkill (OnExit does not run), the OS also ends the model process, so it cannot linger and hold VRAM
HyBindToJob(pid) {
    static job := 0
    if (!job) {
        job := DllCall("CreateJobObject", "ptr", 0, "ptr", 0, "ptr")
        local info := Buffer(A_PtrSize = 8 ? 144 : 112, 0)   ; JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        NumPut("UInt", 0x2000, info, 16)                     ; LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        DllCall("SetInformationJobObject", "ptr", job, "int", 9, "ptr", info, "uint", info.Size)
    }
    local h := DllCall("OpenProcess", "uint", 0x0101, "int", 0, "uint", pid, "ptr")   ; SET_QUOTA | TERMINATE
    if (h) {
        DllCall("AssignProcessToJobObject", "ptr", job, "ptr", h)
        DllCall("CloseHandle", "ptr", h)
    }
}

HyStop() {
    global hyPid
    if (hyPid != 0)
        try ProcessClose(hyPid)
    hyPid := 0
    HyKillOrphans()
}

; Cleans up leftover llama-server processes from this program's directory (e.g. ones left running after an earlier abnormal exit)
HyKillOrphans() {
    local want := StrLower(HyServerPath())
    try {
        for p in ComObjGet("winmgmts:").ExecQuery(
            "SELECT ProcessId, ExecutablePath FROM Win32_Process WHERE Name = 'llama-server.exe'")
            if (StrLower(p.ExecutablePath) = want)
                try ProcessClose(p.ProcessId)
    }
}

; Idle check (every 30 seconds): unloads on timeout, idle mode only
HyIdleCheck() {
    global cfg, hyLastUse, busy
    if (cfg["hy_mode"] != "idle" || busy || !HyIsRunning())
        return
    local mins := IsInteger(cfg["hy_idle"]) ? Integer(cfg["hy_idle"]) : 10
    if (A_TickCount - hyLastUse > mins * 60000)
        HyStop()
}

; startup mode: preloads in the background when the program starts or settings are saved; on failure, only a tray notification is shown
HyPreload() {
    if HyIsRunning()
        return
    try HyEnsure()
    catch as e
        Notify(Tr("hy.preload_failed"), e.Message, 3)
}

HyInit() {
    HyKillOrphans()
    SetTimer(HyIdleCheck, 30000)
    if (cfg["hy_mode"] = "startup")
        SetTimer(HyPreload, -1500)
    OnExit((*) => HyStop())
}
