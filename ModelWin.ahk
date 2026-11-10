#Include %A_LineFile%\..\Models.ahk
;=====================================================================
; ModelWin.ahk - the two manager windows of the local translation model: "Inference engines" and
; "Translation models". Both list what can be installed, what is installed and what is in use, and let
; the user download, use or delete an entry. Opened from Settings -> Hy-MT2 and from the first-run wizard.
;
;   ShowEngineWin(opts) / ShowModelWin(opts)
;       opts: Map("wizard", true) changes the Close button to "Continue";
;             Map("onClose", callback) is called after the window has closed.
;=====================================================================

global MG := Map()          ; kind ("engine" | "model") -> state Map of the open window

ShowEngineWin(opts := "") => MgShow("engine", opts)
ShowModelWin(opts := "") => MgShow("model", opts)

MgShow(kind, opts) {
    global MG
    if (MG.Has(kind) && MG[kind]["gui"] != 0) {
        MG[kind]["gui"].Show()
        return
    }
    if (kind = "engine")
        ModelsMigrateAndRepoint()
    local s := Map("kind", kind, "opts", IsObject(opts) ? opts : Map(), "job", 0, "items", [], "ctl", Map(),
        "gui", 0, "filling", false)
    MG[kind] := s
    s["hw"] := DetectHardware()
    s["rec"] := RecommendRuntime(s["hw"], MfRuntime("cuda12")["min_nvidia_driver"])
    s["recModel"] := RecommendModel(s["hw"], s["rec"]["id"])

    local title := (kind = "engine") ? Tr("mgr.engine.title") : Tr("mgr.model.title")
    local intro := (kind = "engine") ? Tr("mgr.engine.intro") : Tr("mgr.model.intro")
    local g := Gui("+AlwaysOnTop", title)
    g.SetFont("s10", "Microsoft YaHei")
    g.MarginX := 18, g.MarginY := 14
    local c := s["ctl"]

    g.SetFont("s12 bold")
    g.Add("Text", "x18 y14 w564", title)
    g.SetFont("s9 norm c555555")
    g.Add("Text", "x18 y+6 w564", intro)
    if (kind = "engine") {
        g.SetFont("s9 norm c333333")
        g.Add("Text", "x18 y+10 w564", HardwareSummary(s["hw"]))
        g.SetFont("s9 norm c555555")
        g.Add("Text", "x18 y+6 w564", Tr("model.engine_hint"))
    }

    g.SetFont("s10 norm cDefault")
    c["lv"] := g.Add("ListView", "x18 y+10 w564 r6 -Multi NoSortHdr",
        [Tr("mgr.col.name"), Tr("mgr.col.size"), Tr("mgr.col.status"), Tr("mgr.col.use")])
    c["lv"].OnEvent("ItemSelect", (*) => MgSync(kind))
    g.SetFont("s9 norm c808080")
    c["note"] := g.Add("Text", "x18 y+8 w564 h" . (kind = "engine" ? 52 : 20), "")
    g.SetFont("s9 norm c555555")
    g.Add("Link", "x18 y+4 w564", MgLicenseText(kind))
    g.SetFont("s9 norm c333333")
    c["need"] := g.Add("Text", "x18 y+10 w564", "")
    c["prog"] := g.Add("Progress", "x18 y+6 w564 h14 Range0-100", 0)
    c["status"] := g.Add("Text", "x18 y+6 w564 h36", "")

    g.SetFont("s10 norm cDefault")
    c["dl"] := g.Add("Button", "x18 y+12 w120 h32", Tr("mgr.btn.download"))
    c["dl"].OnEvent("Click", (*) => MgDownload(kind))
    c["use"] := g.Add("Button", "x+8 yp w100 h32", Tr("mgr.btn.use"))
    c["use"].OnEvent("Click", (*) => MgUse(kind))
    c["del"] := g.Add("Button", "x+8 yp w80 h32", Tr("mgr.btn.delete"))
    c["del"].OnEvent("Click", (*) => MgDelete(kind))
    c["cancel"] := g.Add("Button", "x+8 yp w110 h32", Tr("mgr.btn.cancel"))
    c["cancel"].OnEvent("Click", (*) => MgCancel(kind))
    c["close"] := g.Add("Button", "x482 yp w100 h32", Tr(s["opts"].Has("wizard") ? "mgr.btn.continue" : "mgr.btn.close"))
    c["close"].OnEvent("Click", (*) => MgClose(kind))
    g.OnEvent("Close", (*) => MgClose(kind))
    g.OnEvent("Escape", (*) => MgClose(kind))
    s["gui"] := g

    MgFill(kind, "")
    g.Show("w600")
}

MgLicenseText(kind) {
    local mf := ManifestLoad()
    if (kind = "engine")
        return Tr("mgr.engine.licenses", mf["llama_cpp"]["license_url"], mf["llama_cpp"]["license"],
            "https://docs.nvidia.com/cuda/eula/index.html")
    return Tr("mgr.model.licenses", mf["model_license"]["url"], mf["model_license"]["name"])
}

; The rows of one manager: Map("id", "name", "bytes", "installed", "inUse", "rec", "note", "legacy")
MgBuildItems(kind) {
    local s := MG[kind], items := []
    if (kind = "engine") {
        local inUse := EngineInUse()
        for id in EngineIds() {
            local legacy := (id = "legacy"), r := legacy ? 0 : MfRuntime(id)
            local rec := (!legacy && s["rec"]["id"] = id)
            local note := legacy ? Tr("mgr.engine.legacy_note") : Tr("model.rt_note." . id)
            if (rec && s["rec"]["reason"] != "")
                note := Tr(s["rec"]["reason"], s["rec"]["arg"]) . "`n" . note
            items.Push(Map("id", id, "name", RuntimeName(id), "bytes", legacy ? 0 : MfRuntimeBytes(r),
                "installed", RuntimeInstalled(id), "inUse", inUse = id, "rec", rec, "note", note, "legacy", legacy))
        }
        return items
    }
    for e in ModelEntries() {
        local isManifest := (e["manifest"] != 0)
        items.Push(Map("id", e["id"], "name", isManifest ? Tr("model.q." . e["id"]) : e["file"], "bytes", e["size"],
            "installed", e["installed"], "inUse", e["installed"] && ModelInUse(e), "rec", e["id"] = s["recModel"],
            "note", isManifest ? "" : Tr("mgr.model.extra_note"), "legacy", false, "entry", e))
    }
    return items
}

; (Re)fill the list and re-select `keepId` (or the item in use, else the recommended one)
MgFill(kind, keepId) {
    local s := MG[kind], lv := s["ctl"]["lv"]
    s["filling"] := true
    s["items"] := MgBuildItems(kind)
    lv.Delete()
    local pick := 0, pickInUse := 0, pickRec := 0
    for i, it in s["items"] {
        local name := it["name"] . (it["rec"] ? "  (" . Tr("model.recommended") . ")" : "")
        lv.Add("", name, it["bytes"] ? FormatBytes(it["bytes"]) : "-",
            it["installed"] ? Tr("model.installed") : Tr("mgr.not_installed"), it["inUse"] ? "✓" : "")
        if (keepId != "" && it["id"] = keepId)
            pick := i
        if it["inUse"]
            pickInUse := i
        if it["rec"]
            pickRec := i
    }
    lv.ModifyCol(1, 310), lv.ModifyCol(2, 75), lv.ModifyCol(3, 120), lv.ModifyCol(4, 55)
    pick := pick ? pick : (pickInUse ? pickInUse : (pickRec ? pickRec : (s["items"].Length ? 1 : 0)))
    if pick
        lv.Modify(pick, "Select Focus Vis")
    s["filling"] := false
    MgSync(kind)
}

MgSelected(kind) {
    local s := MG[kind]
    local row := s["ctl"]["lv"].GetNext(0)
    return (row >= 1 && row <= s["items"].Length) ? s["items"][row] : 0
}

; Buttons, note and "to download" line for the current selection
MgSync(kind) {
    local s := MG[kind]
    if s["filling"]
        return
    local c := s["ctl"], it := MgSelected(kind), running := s["job"] != 0
    c["note"].Text := it ? it["note"] : ""
    if (it && !it["installed"] && !running) {
        local steps := (kind = "engine") ? EngineSteps(it["id"]) : ModelSteps(it["id"])
        c["need"].Text := Tr("model.will_download", FormatBytes(ModelsStepsBytes(steps)), FormatBytes(ModelsFreeBytes()))
    } else if !running {
        c["need"].Text := ""
    }
    c["dl"].Enabled := !running && it && !it["installed"]
    c["use"].Enabled := !running && it && it["installed"] && !it["inUse"]
    c["del"].Enabled := !running && it && it["installed"] && !it["legacy"]
    c["cancel"].Enabled := running
    c["lv"].Enabled := !running
}

MgDownload(kind) {
    local s := MG[kind], it := MgSelected(kind)
    if (s["job"] != 0 || !it || it["installed"])
        return
    local steps := (kind = "engine") ? EngineSteps(it["id"]) : ModelSteps(it["id"])
    local owner := s["gui"].Hwnd
    if (ModelsNeededBytes(steps) > ModelsFreeBytes()) {
        Notice(Tr("model.title"), Tr("model.err.space"), Tr("model.err.space_detail",
            FormatBytes(ModelsNeededBytes(steps)), FormatBytes(ModelsFreeBytes())), Map("owner", owner))
        return
    }
    if !Confirm(Tr("model.title"), Tr("model.confirm.heading"), Tr("model.confirm.msg", FormatBytes(ModelsStepsBytes(steps))),
        "", Tr("mgr.btn.download"), false, Map("owner", owner))
        return
    s["job"] := DlJob(steps, MgOnUpdate.Bind(kind, it))
    s["ctl"]["prog"].Value := 0
    MgSync(kind)
    s["job"].Start()
}

MgCancel(kind) {
    local s := MG[kind]
    if (s["job"] != 0)
        s["job"].Cancel()
}

; Called by the download job on every change
MgOnUpdate(kind, it, job) {
    if (!MG.Has(kind) || MG[kind]["gui"] = 0)
        return
    local s := MG[kind], c := s["ctl"]
    c["prog"].Value := job.Percent()
    switch job.state {
        case "downloading":
            c["status"].Text := Tr("model.st.downloading", job.index, job.steps.Length, job.Step()["name"],
                FormatBytes(job.bytes), FormatBytes(job.total), FormatBytes(Round(job.Speed())))
        case "verifying":
            c["status"].Text := Tr("model.st.verifying", job.Step()["name"])
        case "extracting":
            c["status"].Text := Tr("model.st.extracting", job.Step()["name"])
        case "done":
            s["job"] := 0
            try {
                if (kind = "engine") {
                    ModelsFinishRuntime(it["id"])
                    UseEngine(it["id"])
                } else {
                    UseModel(it["entry"])
                }
                LoadConfig()
            } catch as e {
                c["status"].Text := Tr("model.st.error", e.Message)
                MgFill(kind, it["id"])
                return
            }
            c["prog"].Value := 100
            c["status"].Text := Tr("mgr.download.done", it["name"])
            MgFill(kind, it["id"])
            SettingsRefreshHy()
        case "error":
            s["job"] := 0
            ModelsCleanup()
            c["status"].Text := Tr("model.st.error", job.err)
            MgSync(kind)
        case "cancelled":
            s["job"] := 0
            ModelsCleanup()
            c["status"].Text := Tr("model.st.cancelled")
            MgSync(kind)
    }
}

MgUse(kind) {
    local s := MG[kind], it := MgSelected(kind)
    if (!it || !it["installed"] || it["inUse"])
        return
    try {
        if (kind = "engine")
            UseEngine(it["id"])
        else
            UseModel(it["entry"])
        LoadConfig()
        s["ctl"]["status"].Text := Tr("mgr.use.done", it["name"])
    } catch as e {
        s["ctl"]["status"].Text := Tr("model.st.error", e.Message)
    }
    MgFill(kind, it["id"])
    SettingsRefreshHy()
}

MgDelete(kind) {
    local s := MG[kind], it := MgSelected(kind)
    if (!it || !it["installed"] || it["legacy"])
        return
    local msg := Tr("mgr.delete.msg", FormatBytes(it["bytes"]))
    if it["inUse"]
        msg .= "`n" . Tr("mgr.delete.in_use")
    if !Confirm(Tr("model.title"), Tr("mgr.delete.heading", it["name"]), msg, "", Tr("mgr.btn.delete"), false,
        Map("owner", s["gui"].Hwnd))
        return
    try {
        if (kind = "engine")
            DeleteEngine(it["id"])
        else
            DeleteModel(it["entry"])
        s["ctl"]["status"].Text := Tr("mgr.delete.done", it["name"])
    } catch as e {
        s["ctl"]["status"].Text := Tr("mgr.delete.fail", e.Message)
    }
    MgFill(kind, it["id"])
    SettingsRefreshHy()
}

MgClose(kind) {
    local s := MG[kind]
    if (s["job"] != 0)
        s["job"].Cancel()
    ModelsCleanup()
    local cb := s["opts"].Has("onClose") ? s["opts"]["onClose"] : 0
    try s["gui"].Destroy()
    s["gui"] := 0
    if cb
        cb.Call()
}
