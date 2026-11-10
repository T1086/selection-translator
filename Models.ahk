#Include %A_LineFile%\..\I18n.ahk
#Include %A_LineFile%\..\Json.ahk
#Include %A_LineFile%\..\Download.ahk
;=====================================================================
; Models.ahk - the optional local translation model: what can be installed (manifest.json),
; what the hardware suggests, what is installed already, and how to install it.
; No GUI here (see ModelWin.ahk) so everything can be unit tested.
;
; Layout on disk (next to the program):
;   llama\<id>\          one folder per downloaded llama.cpp runtime (cuda12, vulkan, cpu)
;   llama\               an engine placed here by hand is listed as "legacy"
;   models\              GGUF model files
;   downloads\           archives while they are being downloaded / verified (removed afterwards)
;=====================================================================

global MANIFEST := 0

ModelsDir() {
    local dir := AppDir()
    return dir
}
ModelsPath(rel) => ModelsDir() . "\" . rel

; Loads manifest.json (cached). `path` is only for tests.
ManifestLoad(path := "") {
    global MANIFEST
    if (path = "" && MANIFEST)
        return MANIFEST
    local file := (path != "") ? path : ModelsPath("manifest.json")
    local m := JsonParse(FileRead(file, "UTF-8"))
    if !(m is Map) || !m.Has("runtimes") || !m.Has("models")
        throw Error("manifest.json is invalid")
    if (path = "")
        MANIFEST := m
    return m
}

MfRuntimes() => ManifestLoad()["runtimes"]
MfModels() => ManifestLoad()["models"]

MfRuntime(id) {
    for r in MfRuntimes()
        if (r["id"] = id)
            return r
    return 0
}
MfModel(id) {
    for m in MfModels()
        if (m["id"] = id)
            return m
    return 0
}

; Total download size of a runtime or model entry, in bytes
MfRuntimeBytes(r) {
    local n := 0
    for f in r["files"]
        n += f["size"]
    return n
}

FormatBytes(n) {
    if (n >= 1073741824)
        return Round(n / 1073741824, 2) . " GB"
    if (n >= 1048576)
        return Round(n / 1048576, 1) . " MB"
    return Round(n / 1024) . " KB"
}

;---------------------------------------------------------------------
; Hardware detection and recommendation
;---------------------------------------------------------------------
; WMI reports NVIDIA drivers as "32.0.15.5612"; the marketing version is 556.12 (last five digits).
ParseNvidiaDriver(wmiVersion) {
    local parts := StrSplit(wmiVersion, ".")
    if (parts.Length < 4)
        return 0
    local digits := SubStr(parts[3] . parts[4], -5)
    if !RegExMatch(digits, "^\d{5}$")
        return 0
    return Number(SubStr(digits, 1, 3) . "." . SubStr(digits, 4))
}

GpuVendor(name) {
    if RegExMatch(name, "i)basic display|virtual|remote|parsec|meta")
        return "other"
    if RegExMatch(name, "i)nvidia|geforce|rtx|gtx|quadro")
        return "nvidia"
    if RegExMatch(name, "i)\bamd\b|radeon")
        return "amd"
    if RegExMatch(name, "i)intel")
        return "intel"
    return "other"
}

; Returns Map("gpus", [Map(name, vendor, driver)], "ram_gb", n). driver is the NVIDIA version number or 0.
DetectHardware() {
    local gpus := []
    try {
        for v in ComObjGet("winmgmts:").ExecQuery("SELECT Name, DriverVersion FROM Win32_VideoController") {
            local vendor := GpuVendor(v.Name)
            gpus.Push(Map("name", v.Name, "vendor", vendor,
                "driver", (vendor = "nvidia") ? ParseNvidiaDriver(v.DriverVersion) : 0))
        }
    }
    local ms := Buffer(64, 0)
    NumPut("UInt", 64, ms, 0)
    local ram := 0
    if DllCall("GlobalMemoryStatusEx", "ptr", ms)
        ram := Round(NumGet(ms, 8, "UInt64") / 1073741824)
    return Map("gpus", gpus, "ram_gb", ram)
}

; Which runtime to suggest. Returns Map("id", runtime id, "reason", language key, "arg", text for the reason).
RecommendRuntime(hw, minNvidiaDriver := 551.61) {
    local best := 0
    for g in hw["gpus"]
        if (g["vendor"] = "nvidia" && (!best || g["driver"] > best["driver"]))
            best := g
    if best {
        if (best["driver"] >= minNvidiaDriver)
            return Map("id", "cuda12", "reason", "model.reason.nvidia", "arg", best["name"])
        return Map("id", "vulkan", "reason", "model.reason.nvidia_old", "arg", best["name"])
    }
    for g in hw["gpus"]
        if (g["vendor"] = "amd")
            return Map("id", "vulkan", "reason", "model.reason.gpu", "arg", g["name"])
    for g in hw["gpus"]
        if (g["vendor"] = "intel")
            return Map("id", "vulkan", "reason", "model.reason.gpu", "arg", g["name"])
    return Map("id", "cpu", "reason", "model.reason.none", "arg", "")
}

; Smaller quantization for CPU-only or low-memory machines
RecommendModel(hw, runtimeId) {
    if (runtimeId = "cpu" || (hw["ram_gb"] > 0 && hw["ram_gb"] < 8))
        return "q4_k_m"
    return "q6_k"
}

HardwareSummary(hw) {
    if (hw["gpus"].Length = 0)
        return Tr("model.hw_none", hw["ram_gb"])
    local names := ""
    for g in hw["gpus"]
        names .= (names = "" ? "" : "; ") . g["name"]
    return Tr("model.hw", names, hw["ram_gb"])
}

;---------------------------------------------------------------------
; What is installed
;---------------------------------------------------------------------
; Runtimes installed by this program live in llama\<id>\. An engine placed by hand straight into llama\ is the "legacy" entry: it can be used but is not managed (never deleted) here.
RuntimeDir(id) => ModelsPath("llama\" . id)
RuntimeServerPath(id) => (id = "legacy") ? ModelsPath("llama\llama-server.exe") : RuntimeDir(id) . "\llama-server.exe"
RuntimeServerRel(id) => (id = "legacy") ? "llama\llama-server.exe" : "llama\" . id . "\llama-server.exe"
RuntimeInstalled(id) => FileExist(RuntimeServerPath(id)) != ""

; Ids shown in the engine manager: the manifest's runtimes, plus "legacy" when such a file exists
EngineIds() {
    local ids := []
    for r in MfRuntimes()
        ids.Push(r["id"])
    if RuntimeInstalled("legacy")
        ids.Push("legacy")
    return ids
}

RuntimeName(id) => (id = "legacy") ? Tr("mgr.engine.legacy") : Tr("model.rt." . id)

PathSame(a, b) => StrLower(StrReplace(a, "/", "\")) = StrLower(StrReplace(b, "/", "\"))

; Which engine config.ini points at ("" if none of the known ones)
EngineInUse() {
    local cur := HyServerPath()
    for id in EngineIds()
        if PathSame(RuntimeServerPath(id), cur)
            return id
    return ""
}

ModelFilePath(m) => ModelsPath("models\" . m["file"])

ModelInstalled(m) {
    local p := ModelFilePath(m)
    return FileExist(p) && FileGetSize(p) = m["size"]
}

; Everything the model manager lists: the manifest's models, plus any other .gguf found in models\.
; Map("id", "file", "size", "manifest" (the manifest entry or 0), "installed")
ModelEntries() {
    local list := [], known := Map()
    for m in MfModels() {
        known[StrLower(m["file"])] := true
        list.Push(Map("id", m["id"], "file", m["file"], "size", m["size"], "manifest", m, "installed", ModelInstalled(m)))
    }
    loop files ModelsPath("models\*.gguf") {
        if known.Has(StrLower(A_LoopFileName))
            continue
        list.Push(Map("id", "file:" . A_LoopFileName, "file", A_LoopFileName, "size", A_LoopFileSize, "manifest", 0, "installed", true))
    }
    return list
}

ModelInUse(entry) => PathSame(ModelsPath("models\" . entry["file"]), HyModelPath())

;---------------------------------------------------------------------
; Installing, using, deleting
;---------------------------------------------------------------------
; Steps for DlJob. Engines are extracted into llama.new first and moved into llama\<id> when complete.
EngineSteps(id) {
    local steps := [], r := MfRuntime(id)
    if !r
        return steps
    for f in r["files"]
        steps.Push(Map("name", f["name"], "url", f["url"], "size", f["size"], "sha256", f["sha256"],
            "dest", ModelsPath("downloads\" . f["name"]), "extractTo", ModelsPath("llama.new"),
            "provides", r["provides"]))
    return steps
}

ModelSteps(id) {
    local m := MfModel(id)
    if !m
        return []
    return [Map("name", m["file"], "url", m["url"], "size", m["size"], "sha256", m["sha256"], "dest", ModelFilePath(m))]
}

ModelsStepsBytes(steps) {
    local n := 0
    for s in steps
        n += s["size"]
    return n
}

; Free space in bytes on the drive that holds the program
ModelsFreeBytes() {
    try return DriveGetSpaceFree(ModelsDir()) * 1048576
    return 0
}

; Bytes needed on disk: archives + unpacked runtime (about twice the archive size) + models
ModelsNeededBytes(steps) {
    local n := 0
    for s in steps
        n += s["size"] * (s.Has("extractTo") ? 3 : 1)
    return n
}

; Move the freshly extracted runtime from llama.new into llama\<id>
ModelsFinishRuntime(id) {
    local newDir := ModelsPath("llama.new"), target := RuntimeDir(id)
    if !DirExist(newDir)
        return
    try HyStop()                              ; a running server may hold files of the folder being replaced
    if DirExist(target)
        DirDelete(target, 1)
    DirCreate(ModelsPath("llama"))
    DirMove(newDir, target)
    try DirDelete(ModelsPath("downloads"), 1)
}

; Point config.ini at an installed engine / model (needs Settings.ahk for IniWriteMany; callers run LoadConfig)
UseEngine(id) {
    local items := [["Hy", "server", RuntimeServerRel(id)], ["Hy", "device", ""], ["Hy", "device_name", ""]]   ; device ids differ between engines: back to automatic
    local r := MfRuntime(id)
    if r
        items.Push(["Hy", "gpu_layers", r["gpu"] ? "99" : "0"])
    IniWriteMany(ConfigFile(), items)
    try HyStop()                              ; the next translation starts the newly chosen engine
}

UseModel(entry) {
    IniWriteMany(ConfigFile(), [["Hy", "model", "models\" . entry["file"]]])
    try HyStop()
}

DeleteEngine(id) {
    if (id = "legacy")
        throw Error("legacy engine")
    try HyStop()
    DirDelete(RuntimeDir(id), 1)
}

DeleteModel(entry) {
    try HyStop()
    FileDelete(ModelsPath("models\" . entry["file"]))
}

; Older versions unpacked the engine straight into llama\ and recorded its id in llama\runtime.json. Move such an
; engine into its own llama\<id>\ folder, so that several engines can live side by side. Returns the id moved, or "".
; `base` (default: the program folder) is only overridden by tests.
ModelsMigrateLegacy(base := "") {
    if (base = "")
        base := ModelsDir()
    local llama := base . "\llama", marker := llama . "\runtime.json"
    if (!FileExist(llama . "\llama-server.exe") || !FileExist(marker))
        return ""
    local id := ""
    try {
        local j := JsonParse(FileRead(marker, "UTF-8"))
        if (j is Map && j.Has("id"))
            id := j["id"]
    }
    if (id = "" || !MfRuntime(id) || DirExist(llama . "\" . id))
        return ""
    try HyStop()                              ; the server must not be running while its files move
    local tmp := llama . ".migrate"
    if DirExist(tmp)
        DirDelete(tmp, 1)
    DirMove(llama, tmp)                       ; rename the whole folder, then rebuild llama\ with the engine inside
    DirCreate(llama)
    DirMove(tmp, llama . "\" . id)
    try FileDelete(llama . "\" . id . "\runtime.json")
    return id
}

; Run at start-up (and when the engine window opens): migrate, and repoint config.ini if it used the old path
ModelsMigrateAndRepoint() {
    global cfg
    local id := ""
    try id := ModelsMigrateLegacy()
    if (id = "")
        return
    if PathSame(HyServerPath(), ModelsPath("llama\llama-server.exe")) {
        try IniWriteMany(ConfigFile(), [["Hy", "server", RuntimeServerRel(id)]])
        LoadConfig()
    }
}

; Remove leftovers of a cancelled install (partial extraction), keeps partial downloads for resuming
ModelsCleanup() {
    try DirDelete(ModelsPath("llama.new"), 1)
}

; One-line descriptions of what is in use now (Settings tab)
HyEngineText() {
    local id := EngineInUse()
    if (id != "")
        return RuntimeName(id)
    return FileExist(HyServerPath()) ? cfg["hy_server"] : Tr("settings.hy.none")
}

HyModelText() {
    local f := ""
    SplitPath(cfg["hy_model"], &f)
    if !FileExist(HyModelPath())
        return (f = "" ? Tr("settings.hy.none") : f . " " . Tr("settings.hy.missing"))
    return f
}
