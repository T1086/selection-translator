#Include %A_LineFile%\..\I18n.ahk
;=====================================================================
; Translation engine layer (#Included by Translator.ahk)
;   ecdict    offline dictionary (words and phrases only, Dict.ahk)
;   hy        Hy-MT2 local model (HyMT.ahk)
;   microsoft Microsoft Translator (words use the dictionary endpoint, which returns multiple senses; sentences use the translation endpoint)
;   deepl     DeepL
; Engine is chosen by settings. Failures throw an Error with the exact cause, shown in a dialog (the optional auto-switch on ECDICT failure is handled in ShowEngineResult).
; Engines return Map("kind", "text", "text", translation) or Map("kind", "dict", "entry", entry)
;=====================================================================

global ENGINE_NAMES := Map("ecdict", "ECDICT", "hy", "Hy-MT2", "microsoft", "Microsoft", "deepl", "DeepL")
global ENGINE_WORD_IDS := ["ecdict", "hy", "microsoft", "deepl"]
global ENGINE_SENTENCE_IDS := ["hy", "microsoft", "deepl"]
; Engine to fall back to when ECDICT fails (word not in dictionary, or dictionary missing); none = do not switch, report the error
global ECDICT_FALLBACK_IDS := ["none", "hy", "microsoft", "deepl"]
global MS_ENDPOINT := "https://api.cognitive.microsofttranslator.com"

EngineName(id) => ENGINE_NAMES.Has(id) ? ENGINE_NAMES[id] : id

; Target/source language: a non-empty tgt means "reverse translation" (e.g. zh->en in the input window); then the target is tgt and the source is auto-detected;
; if tgt is empty, the target/source languages from settings are used
EngTarget(tgt) => (tgt != "") ? tgt : cfg["target_lang"]
; The configured source language is only sent when it can be the language of this text; otherwise the service is left to detect it
; (DeepL and Microsoft take it as a fact and do not detect anything when it is given).
EngSource(tgt, text) {
    global cfg
    local src := StrUpper(cfg["source_lang"])
    if (tgt != "" || src = "")
        return ""
    return SourceFits(src, DetectLang(text)) ? src : ""
}

; lang comes from DetectLang. Han without kana can still be Japanese; a Latin text without clear evidence can be any Latin-script language.
SourceFits(src, lang) => (lang = src) || (lang = "ZH" && src = "JA") || (lang = "LATIN" && IsLatinLang(src))

IsLatinLang(code) => (code = "EN" || code = "FR" || code = "DE" || code = "ES")

; Returns ZH / JA / KO / RU; EN / FR / DE / ES when a Latin-script text gives clear evidence; "LATIN" when it does not;
; "OTHER" for any other script; "" when the text has no letters at all.
; Limits: Han characters without kana count as Chinese, so kanji-only Japanese is read as Chinese.
DetectLang(s) {
    s := SubStr(s, 1, 2000)
    if RegExMatch(s, "[\x{3040}-\x{30FF}]")
        return "JA"
    if RegExMatch(s, "[\x{AC00}-\x{D7A3}\x{1100}-\x{11FF}]")
        return "KO"
    if RegExMatch(s, "[\x{3400}-\x{9FFF}]")
        return "ZH"
    if RegExMatch(s, "[\x{0400}-\x{04FF}]")
        return "RU"
    if RegExMatch(s, "[A-Za-z\x{00C0}-\x{024F}]")
        return LatinGuess(s)
    return RegExMatch(s, "\p{L}") ? "OTHER" : ""
}

; Small stop-word count that separates EN / FR / DE / ES. Needs at least 2 points and a clear winner, so a single
; word such as "die" or "cafe" is never classified; those return "LATIN".
LatinGuess(s) {
    static words := Map(
        "EN", " the is are was were of and to on with that this you have for not it ",
        "FR", " le la les des est une et dans pour qui sur pas avec vous nous je ce ",
        "DE", " der die das und ist nicht ein eine mit auf ich sie wir von zu den dem ",
        "ES", " el los las una es y en por para con del pero como se esta ")
    static marks := Map("FR", "[çœèêàù]", "DE", "[ßäöü]", "ES", "[ñ¿¡]")
    local low := StrLower(s), score := Map("EN", 0, "FR", 0, "DE", 0, "ES", 0)
    for w in StrSplit(RegExReplace(low, "[^\p{L}]+", " "), " ")
        if (w != "")
            for code, list in words
                if InStr(list, " " . w . " ", true)
                    score[code] += 1
    for code, re in marks
        if RegExMatch(low, re)
            score[code] += 1
    local best := "", top := 0, second := 0
    for code, n in score {
        if (n > top) {
            second := top, top := n, best := code
        } else if (n > second)
            second := n
    }
    return (top >= 2 && top > second) ? best : "LATIN"
}

RunEngine(engine, text, isWord, tgt := "") {
    switch engine {
        case "ecdict":
            if !isWord
                throw Error(Tr("eng.ecdict_words_only"))
            if !DictAvailable()
                throw Error(Tr("eng.dict_missing", DictDat()))
            local e := DictLookup(text)
            if !e
                throw Error(Tr("eng.dict_no_entry", text))
            return Map("kind", "dict", "entry", e)
        case "hy":
            return Map("kind", "text", "text", HyTranslate(text, tgt))
        case "microsoft":
            return isWord ? MsLookup(text, tgt) : Map("kind", "text", "text", MsTranslate(text, tgt))
        case "deepl":
            return Map("kind", "text", "text", DeepLTranslate(text, tgt))
    }
    throw Error(Tr("eng.unknown", engine))
}

;=========================== HTTP ====================================
; Synchronous request; returns Map("status", HTTP status code, "text", UTF-8-decoded body)
; Network-level failures (offline, timeout, cannot connect) throw an Error whose message is already localized via Tr()
HttpSend(method, url, headers, body := "", timeout := 10000) {
    local wh := ComObject("WinHttp.WinHttpRequest.5.1")
    try {
        wh.Open(method, url, false)
        for k, v in headers
            wh.SetRequestHeader(k, v)
        wh.SetTimeouts(timeout, timeout, timeout, timeout)
        if (body != "")
            wh.Send(Utf8Bytes(body))     ; Send as UTF-8 bytes so non-ASCII characters are not converted using ANSI
        else
            wh.Send()
    } catch as e {
        throw Error(NetErrorText(e.Message))
    }
    return Map("status", wh.Status, "text", BytesToUtf8(wh.ResponseBody))
}

; Retry once on network error or 5xx (for online services; local Hy-MT2 does not retry)
HttpRetry(method, url, headers, body, timeout) {
    local r := 0
    loop 2 {
        try {
            r := HttpSend(method, url, headers, body, timeout)
            if (r["status"] < 500)
                return r
        } catch as e {
            if (A_Index = 2)
                throw e
        }
        Sleep(300)
    }
    return r
}

NetErrorText(msg) {
    static known := Map(
        "80072EE2", "net.timeout",
        "80072EFD", "net.cannot_connect",
        "80072EE7", "net.dns",
        "80072EFE", "net.aborted",
        "80072F7D", "net.tls",
        "80072F0D", "net.cert")
    for code, key in known
        if InStr(msg, code)
            return Tr("net.error", Tr(key))
    return Tr("net.error", Trim(RegExReplace(msg, "\s+", " ")))
}

Utf8Bytes(str) {
    local n := StrPut(str, "UTF-8") - 1
    local arr := ComObjArray(0x11, n)          ; VT_UI1 byte array
    if (n > 0) {
        local buf := Buffer(n + 1), p := 0
        StrPut(str, buf, "UTF-8")
        DllCall("oleaut32\SafeArrayAccessData", "ptr", ComObjValue(arr), "ptr*", &p)
        DllCall("RtlMoveMemory", "ptr", p, "ptr", buf, "uptr", n)
        DllCall("oleaut32\SafeArrayUnaccessData", "ptr", ComObjValue(arr))
    }
    return arr
}

BytesToUtf8(rb) {
    if (!IsObject(rb))
        return ""
    local n := rb.MaxIndex() - rb.MinIndex() + 1
    if (n <= 0)
        return ""
    local p := 0
    DllCall("oleaut32\SafeArrayAccessData", "ptr", ComObjValue(rb), "ptr*", &p)
    local s := StrGet(p, n, "UTF-8")
    DllCall("oleaut32\SafeArrayUnaccessData", "ptr", ComObjValue(rb))
    return s
}

; Extracts a readable message from an error-response JSON (DeepL: message; Microsoft: error.message)
ApiErrorMessage(text) {
    try {
        local j := JsonParse(text)
        for path in [["error", "message"], ["message"]] {
            local v := JsonGet(j, path*)
            if (v != "" && !IsObject(v))
                return v
        }
    }
    return SubStr(Trim(RegExReplace(text, "\s+", " ")), 1, 200)
}

;=========================== DeepL ===================================
GetApiKey() {
    try {
        k := Trim(FileRead("secret.txt"))
        return (StrLen(k) >= 10) ? k : ""
    }
    return ""
}
UrlEnc(s) {
    local out := ""
    local hex := "0123456789ABCDEF"
    local i := 1
    while (i <= StrLen(s)) {
        local ch := SubStr(s, i, 1)
        local code := Ord(ch)
        if ((code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A) || (code >= 0x30 && code <= 0x39))
            out .= ch
        else if InStr("-._~", ch)
            out .= ch
        else {
            ; Percent-escape each byte of the UTF-8 encoding
            local b := StrPut(ch, "UTF-8")
            local bufb := Buffer(b)
            StrPut(ch, bufb, "UTF-8")
            local j := 1
            while (j <= b - 1) {
                local v := NumGet(bufb, j - 1, "UChar")
                out .= "%" . SubStr(hex, (v >> 4) + 1, 1) . SubStr(hex, (v & 0x0F) + 1, 1)
                j += 1
            }
        }
        i += 1
    }
    return out
}

; DeepL target language: English must be written as EN-US / EN-GB (bare EN is deprecated)
DeepLTarget(code) => (StrUpper(code) = "EN") ? "EN-US" : code

DeepLTranslate(text, tgt := "") {
    global cfg
    local key := GetApiKey()
    if (key = "")
        throw Error(Tr("eng.deepl.no_key"))
    local body := "text=" . UrlEnc(text)
    local src := EngSource(tgt, text)
    if (src != "")
        body .= "&source_lang=" . UrlEnc(src)
    body .= "&target_lang=" . UrlEnc(DeepLTarget(EngTarget(tgt)))
    local r := HttpRetry("POST", cfg["api_url"],
        Map("Authorization", "DeepL-Auth-Key " . key,
            "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8"),
        body, Integer(cfg["net_timeout"]))
    switch r["status"] {
        case 200:
            local t := ""
            try t := JsonGet(JsonParse(r["text"]), "translations", 1, "text")
            if (t = "")
                throw Error(Tr("eng.deepl.parse", SubStr(r["text"], 1, 200)))
            return t
        case 403:
            throw Error(Tr("eng.deepl.403"))
        case 456:
            throw Error(Tr("eng.deepl.456"))
        case 429:
            throw Error(Tr("eng.deepl.429"))
    }
    throw Error(Tr("eng.http", "DeepL", r["status"], ApiErrorMessage(r["text"])))
}

;=========================== Microsoft ===============================
; DeepL-style language code -> Microsoft language code
MsLang(code) {
    static m := Map("ZH", "zh-Hans", "EN", "en", "JA", "ja", "KO", "ko",
        "FR", "fr", "DE", "de", "ES", "es", "RU", "ru")
    return m.Has(code) ? m[code] : StrLower(code)
}

; Like DeepL, the Microsoft key is stored in its own file (secret_microsoft.txt in the project directory, containing only the key itself).
; msKeyFile only overrides the path for tests; normally empty.
global msKeyFile := ""
MsKeyPath() {
    global msKeyFile
    if (msKeyFile != "")
        return msKeyFile
    local dir := AppDir()
    return dir . "\secret_microsoft.txt"
}
GetMsKey() {
    try {
        local k := Trim(FileRead(MsKeyPath()), " `t`r`n")
        return (StrLen(k) >= 10) ? k : ""
    }
    return ""
}

MsHeaders() {
    global cfg
    local key := GetMsKey()
    if (key = "")
        throw Error(Tr("eng.ms.no_key"))
    local h := Map("Ocp-Apim-Subscription-Key", key,
        "Content-Type", "application/json; charset=UTF-8")
    if (Trim(cfg["ms_region"]) != "")
        h["Ocp-Apim-Subscription-Region"] := Trim(cfg["ms_region"])
    return h
}

MsCall(path, body) {
    global cfg, MS_ENDPOINT
    local r := HttpRetry("POST", MS_ENDPOINT . path, MsHeaders(), body, Integer(cfg["net_timeout"]))
    if (r["status"] = 200)
        return JsonParse(r["text"])
    local detail := ApiErrorMessage(r["text"])
    switch r["status"] {
        case 401:
            throw Error(Tr("eng.ms.401", detail))
        case 403:
            throw Error(Tr("eng.ms.403", detail))
        case 429:
            throw Error(Tr("eng.ms.429", detail))
    }
    throw Error(Tr("eng.http", "Microsoft", r["status"], detail))
}

MsTranslate(text, tgt := "") {
    global cfg
    local q := "/translate?api-version=3.0&to=" . MsLang(EngTarget(tgt))
    local src := EngSource(tgt, text)
    if (src != "")
        q .= "&from=" . MsLang(src)
    local j := MsCall(q, "[{" . '"Text":' . JsonStr(text) . "}]")
    local t := JsonGet(j, 1, "translations", 1, "text")
    if (t = "")
        throw Error(Tr("eng.ms.parse"))
    return t
}

; Words: the dictionary endpoint returns several translations plus parts of speech, grouped by part of speech into the same entry structure as ECDICT.
; If the dictionary endpoint has no entry for the word (e.g. proper nouns), the regular Microsoft translation endpoint gives a single translation (still the same engine).
MsLookup(word, tgt := "") {
    global cfg
    local src := EngSource(tgt, word)
    local from := (src != "") ? MsLang(src) : "en"
    local q := "/dictionary/lookup?api-version=3.0&from=" . from . "&to=" . MsLang(EngTarget(tgt))
    local j := MsCall(q, "[{" . '"Text":' . JsonStr(word) . "}]")
    local items := JsonGet(j, 1, "translations")
    if (!(items is Array) || items.Length = 0)
        return Map("kind", "text", "text", MsTranslate(word, tgt))
    return Map("kind", "dict", "entry", MsToEntry(JsonGet(j, 1, "displaySource"), items, word))
}

MsToEntry(display, items, word) {
    static posMap := Map("NOUN", "n.", "VERB", "v.", "ADJ", "adj.", "ADV", "adv.",
        "PREP", "prep.", "CONJ", "conj.", "PRON", "pron.", "DET", "det.", "MODAL", "modal.")
    local order := [], groups := Map()
    for it in items {
        local tag := JsonGet(it, "posTag")
        tag := posMap.Has(tag) ? posMap[tag] : "other"
        if !groups.Has(tag) {
            groups[tag] := []
            order.Push(tag)
        }
        groups[tag].Push(JsonGet(it, "displayTarget"))
    }
    local e := Map("word", display != "" ? display : word, "phonetic", "", "exchange", "",
        "lemma", "", "lines", [])
    for tag in order {
        local txt := ""
        for t in groups[tag]
            txt .= (txt = "" ? "" : "；") . t
        if (tag = "other")
            e["lines"].Push(Map("kind", "plain", "tag", "", "text", txt))
        else
            e["lines"].Push(Map("kind", "pos", "tag", tag, "text", txt))
    }
    return e
}
