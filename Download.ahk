#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Download.ahk - resumable downloads with SHA-256 verification and zip extraction.
; Included by Models.ahk (and by the download unit test).
;
; Everything runs through tools that ship with Windows 10 1803+ (curl.exe, tar.exe)
; and the built-in CNG hashing API, so nothing extra has to be installed.
; The UI thread is never blocked: a DlJob is advanced by a timer.
;
;   job := DlJob(steps, onUpdate)       steps = [Map(url, dest, size, sha256, extractTo?, provides?)]
;   job.Start()                         begin; onUpdate(job) is called on every state change
;   job.Cancel()                        stop; partial downloads are kept so they can be resumed
;
; job.state: "idle" | "downloading" | "verifying" | "extracting" | "done" | "error" | "cancelled"
;=====================================================================

; curl is restricted to HTTPS (also across redirects). Tests widen this to allow file:// URLs.
global DL_PROTO := "=https"
; Hosts a manifest URL may point to. Redirects (CDNs) are allowed by curl, but the entry point is checked.
global DL_ALLOWED_HOSTS := ["github.com", "huggingface.co"]
global DL_SKIP_HOST_CHECK := false     ; tests only

;---------------------------------------------------------------------
; SHA-256 (Windows CNG)
;---------------------------------------------------------------------
class Sha256 {
    alg := 0
    hash := 0
    obj := 0

    __New() {
        local alg := 0, objLen := 0, cb := 0, h := 0
        if DllCall("bcrypt\BCryptOpenAlgorithmProvider", "ptr*", &alg, "wstr", "SHA256", "ptr", 0, "uint", 0, "uint")
            throw Error("BCryptOpenAlgorithmProvider failed")
        this.alg := alg
        DllCall("bcrypt\BCryptGetProperty", "ptr", alg, "wstr", "ObjectLength", "uint*", &objLen, "uint", 4, "uint*", &cb, "uint", 0)
        this.obj := Buffer(objLen)
        if DllCall("bcrypt\BCryptCreateHash", "ptr", alg, "ptr*", &h, "ptr", this.obj, "uint", objLen, "ptr", 0, "uint", 0, "uint", 0, "uint")
            throw Error("BCryptCreateHash failed")
        this.hash := h
    }

    Update(buf, n) {
        DllCall("bcrypt\BCryptHashData", "ptr", this.hash, "ptr", buf, "uint", n, "uint", 0)
    }

    ; Returns the digest as 64 lower-case hex characters and releases the handles.
    Final() {
        local out := Buffer(32), hex := ""
        DllCall("bcrypt\BCryptFinishHash", "ptr", this.hash, "ptr", out, "uint", 32, "uint", 0)
        loop 32
            hex .= Format("{:02x}", NumGet(out, A_Index - 1, "UChar"))
        this.Close()
        return hex
    }

    Close() {
        if this.hash {
            DllCall("bcrypt\BCryptDestroyHash", "ptr", this.hash)
            this.hash := 0
        }
        if this.alg {
            DllCall("bcrypt\BCryptCloseAlgorithmProvider", "ptr", this.alg, "uint", 0)
            this.alg := 0
        }
    }

    __Delete() => this.Close()
}

Sha256Text(str) {
    local h := Sha256(), n := StrPut(str, "UTF-8") - 1, b := Buffer(n + 1)
    StrPut(str, b, "UTF-8")
    h.Update(b, n)
    return h.Final()
}

; Blocking hash of a whole file (tests and small files only; DlJob hashes in slices).
Sha256File(path) {
    local f := FileOpen(path, "r"), h := Sha256(), buf := Buffer(1 << 20), n
    while ((n := f.RawRead(buf, buf.Size)) > 0)
        h.Update(buf, n)
    f.Close()
    return h.Final()
}

;---------------------------------------------------------------------
; Child processes (hidden window + exit code)
;---------------------------------------------------------------------
; Runs `cmd /s /c "<line>"` hidden. Returns Map(pid, handle). The process handle is opened right away
; so the exit code can still be read after the process has ended.
DlSpawn(line) {
    local pid := 0
    Run(A_ComSpec . ' /s /c "' . line . '"', , "Hide", &pid)
    local h := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")   ; PROCESS_QUERY_LIMITED_INFORMATION
    return Map("pid", pid, "handle", h)
}

; Returns true once the process has ended and stores its exit code in `code`.
DlFinished(p, &code) {
    code := -1
    if !p["handle"]
        return !ProcessExist(p["pid"])
    local c := 259
    DllCall("GetExitCodeProcess", "ptr", p["handle"], "uint*", &c)
    if (c = 259)                       ; STILL_ACTIVE
        return false
    code := c
    DllCall("CloseHandle", "ptr", p["handle"])
    p["handle"] := 0
    return true
}

DlKill(p) {
    try ProcessClose(p["pid"])
    ; also stop the curl/tar child that cmd.exe started
    try {
        for c in ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE ParentProcessId = " . p["pid"])
            try ProcessClose(c.ProcessId)
    }
    if p["handle"] {
        DllCall("CloseHandle", "ptr", p["handle"])
        p["handle"] := 0
    }
}

DlHostOk(url) {
    global DL_ALLOWED_HOSTS, DL_SKIP_HOST_CHECK
    if DL_SKIP_HOST_CHECK
        return true
    if !RegExMatch(url, "i)^https://([^/:?#]+)", &m)
        return false
    local host := StrLower(m[1])
    for allowed in DL_ALLOWED_HOSTS
        if (host = allowed || SubStr(host, -(StrLen(allowed) + 1)) = "." . allowed)
            return true
    return false
}

;---------------------------------------------------------------------
; Job
;---------------------------------------------------------------------
class DlJob {
    steps := []
    onUpdate := 0
    state := "idle"
    index := 0              ; 1-based index of the current step
    err := ""
    proc := 0
    hasher := 0
    file := 0
    hashed := 0
    startTick := 0
    startBytes := 0
    bytes := 0              ; bytes of the current step already on disk
    total := 0              ; total bytes of the current step
    timer := 0
    errFile := ""
    verifyPath := ""
    buf := 0

    __New(steps, onUpdate := 0) {
        this.steps := steps
        this.onUpdate := onUpdate
        this.timer := ObjBindMethod(this, "Tick")
        this.errFile := A_Temp . "\seltr_dl_err_" . A_TickCount . ".txt"
    }

    Start() {
        this.index := 0
        this.err := ""
        this.NextStep()
        SetTimer(this.timer, 200)
    }

    Cancel() {
        if (this.state = "done" || this.state = "error" || this.state = "cancelled")
            return
        SetTimer(this.timer, 0)
        if this.proc
            DlKill(this.proc)
        this.proc := 0
        this.CloseHash()
        this.SetState("cancelled")
    }

    ; Overall progress over all steps, 0..100
    Percent() {
        local done := 0, all := 0
        for i, s in this.steps {
            all += s["size"]
            if (i < this.index)
                done += s["size"]
            else if (i = this.index)
                done += (this.state = "verifying") ? s["size"] : this.bytes
        }
        return all ? Min(100, Round(done * 100 / all)) : 0
    }

    ; Download speed in bytes per second (current step)
    Speed() {
        local dt := (A_TickCount - this.startTick) / 1000
        return dt > 1 ? Max(0, (this.bytes - this.startBytes) / dt) : 0
    }

    SetState(s) {
        this.state := s
        if this.onUpdate
            this.onUpdate.Call(this)
    }

    Fail(msg) {
        SetTimer(this.timer, 0)
        this.CloseHash()
        this.proc := 0
        this.err := msg
        this.SetState("error")
    }

    CloseHash() {
        if this.file {
            try this.file.Close()
            this.file := 0
        }
        if this.hasher {
            try this.hasher.Close()
            this.hasher := 0
        }
    }

    Step() => this.steps[this.index]

    NextStep() {
        this.index += 1
        if (this.index > this.steps.Length) {
            SetTimer(this.timer, 0)
            this.SetState("done")
            return
        }
        local s := this.Step()
        this.total := s["size"]
        if !DlHostOk(s["url"]) {
            this.Fail(Tr("dl.err.host", s["url"]))
            return
        }
        try DirCreate(RegExReplace(s["dest"], "\\[^\\]+$"))
        catch as e {
            this.Fail(Tr("dl.err.mkdir", e.Message))
            return
        }
        local part := s["dest"] . ".part"
        ; The finished file may already be there: go straight to verification.
        if FileExist(s["dest"]) && FileGetSize(s["dest"]) = s["size"] {
            this.bytes := s["size"]
            this.BeginVerify(s["dest"])
            return
        }
        local have := FileExist(part) ? FileGetSize(part) : 0
        if (have > s["size"]) {
            try FileDelete(part)
            have := 0
        }
        this.bytes := have
        this.startBytes := have
        this.startTick := A_TickCount
        if (have = s["size"]) {
            this.BeginVerify(part)
            return
        }
        ; -C - resumes a partial file; --fail turns HTTP errors into an exit code
        local line := '"curl.exe" -L --fail --silent --show-error --retry 3 --retry-delay 2 -C - '
            . '--proto "' . DL_PROTO . '" --proto-redir "' . DL_PROTO . '" '
            . '-o "' . part . '" "' . s["url"] . '" 2> "' . this.errFile . '"'
        try FileDelete(this.errFile)
        this.proc := DlSpawn(line)
        this.SetState("downloading")
    }

    BeginVerify(path) {
        this.verifyPath := path
        try {
            this.file := FileOpen(path, "r")
            this.hasher := Sha256()
        } catch as e {
            this.Fail(Tr("dl.err.open", path, e.Message))
            return
        }
        this.hashed := 0
        this.buf := Buffer(8 << 20)
        this.SetState("verifying")
    }

    Tick() {
        local s := this.Step()
        switch this.state {
            case "downloading":
                local part := s["dest"] . ".part"
                this.bytes := FileExist(part) ? FileGetSize(part) : 0
                local code := 0
                if DlFinished(this.proc, &code) {
                    this.proc := 0
                    if (code != 0 && this.bytes < s["size"]) {
                        local why := ""
                        try why := Trim(FileRead(this.errFile))
                        this.Fail(Tr("dl.err.curl", code, why))
                        return
                    }
                    if (this.bytes != s["size"]) {
                        this.Fail(Tr("dl.err.size", this.bytes, s["size"]))
                        return
                    }
                    this.BeginVerify(part)
                    return
                }
                if this.onUpdate
                    this.onUpdate.Call(this)
            case "verifying":
                ; hash in 8 MB slices so the UI stays responsive
                local t0 := A_TickCount, n := 0
                while (A_TickCount - t0 < 60) {
                    n := this.file.RawRead(this.buf, this.buf.Size)
                    if (n <= 0)
                        break
                    this.hasher.Update(this.buf, n)
                    this.hashed += n
                }
                if (n > 0) {
                    this.bytes := this.hashed
                    if this.onUpdate
                        this.onUpdate.Call(this)
                    return
                }
                local digest := this.hasher.Final()
                this.hasher := 0
                this.file.Close()
                this.file := 0
                if (StrLower(digest) != StrLower(s["sha256"])) {
                    try FileDelete(this.verifyPath)
                    this.Fail(Tr("dl.err.hash", s["name"]))
                    return
                }
                if (this.verifyPath != s["dest"]) {
                    try {
                        FileMove(this.verifyPath, s["dest"], 1)
                    } catch as e {
                        this.Fail(Tr("dl.err.move", e.Message))
                        return
                    }
                }
                if s.Has("extractTo") && s["extractTo"] != "" {
                    local dir := s["extractTo"]
                    try DirCreate(dir)
                    this.proc := DlSpawn('"tar.exe" -xf "' . s["dest"] . '" -C "' . dir . '" 2> "' . this.errFile . '"')
                    this.SetState("extracting")
                    return
                }
                this.NextStep()
            case "extracting":
                local code := 0
                if !DlFinished(this.proc, &code)
                    return
                this.proc := 0
                if (code != 0) {
                    local why := ""
                    try why := Trim(FileRead(this.errFile))
                    this.Fail(Tr("dl.err.extract", why))
                    return
                }
                if s.Has("provides") && s["provides"] != "" && !FileExist(s["extractTo"] . "\" . s["provides"]) {
                    this.Fail(Tr("dl.err.provides", s["provides"]))
                    return
                }
                ; the archive is no longer needed
                try FileDelete(s["dest"])
                this.NextStep()
        }
    }
}
