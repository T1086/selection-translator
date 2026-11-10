;=====================================================================
; UI localization (included first by Translator.ahk)
;   Tr("key", args...)   returns the text for the current language; {1} {2} ... are placeholders
;   Language files: lang\zh.ini, lang\en.ini. Format: key=value (lines starting with ';' are comments,
;   [section] lines only group keys, \n = newline, \\ = backslash). A key missing in the current language
;   falls back to English; if English lacks it too the key itself is shown, so missing translations are easy to spot.
;   Language choice: config.ini [UI] language = auto | zh | en (auto follows the Windows display language).
;   SELTR_LANG=zh|en in the environment forces a language (used by the automated tests).
;=====================================================================

global I18N_LANG := "en"
global I18N_CUR := Map()
global I18N_FB := Map()
global I18N_CODES := ["zh", "en"]

; Reads a language file into a Map; a missing file gives an empty Map
I18nLoadFile(path) {
    local m := Map()
    local txt := ""
    try txt := FileRead(path, "UTF-8")
    catch
        return m
    for ln in StrSplit(txt, "`n", "`r") {
        ln := LTrim(ln)
        if (ln = "" || SubStr(ln, 1, 1) = ";" || SubStr(ln, 1, 1) = "[")
            continue
        local p := InStr(ln, "=")
        if (p < 2)
            continue
        local v := SubStr(ln, p + 1)
        v := StrReplace(v, "\\", Chr(1))
        v := StrReplace(v, "\n", "`n")
        m[Trim(SubStr(ln, 1, p - 1))] := StrReplace(v, Chr(1), "\")
    }
    return m
}

; Program folder. A_LineFile is not a path in a compiled program, and A_ScriptDir is the wrong folder for a test script that #Includes this one.
AppDir() {
    if A_IsCompiled
        return A_ScriptDir
    SplitPath(A_LineFile, , &dir)
    return dir
}

I18nDir() => AppDir() . "\lang"

; Returns "zh" when the Windows display language is Chinese (simplified or traditional), otherwise "en"
I18nSystemLang() => (SubStr(A_Language, -2) = "04") ? "zh" : "en"

; pref = "auto" | "zh" | "en" (anything else is treated as auto); returns the language code actually used
I18nInit(pref := "auto") {
    global I18N_LANG, I18N_CUR, I18N_FB
    local env := EnvGet("SELTR_LANG")
    if (env != "")
        pref := env
    pref := StrLower(Trim(pref))
    local code := (pref = "zh" || pref = "en") ? pref : I18nSystemLang()
    I18N_FB := I18nLoadFile(I18nDir() . "\en.ini")
    I18N_CUR := (code = "en") ? I18N_FB : I18nLoadFile(I18nDir() . "\" . code . ".ini")
    I18N_LANG := code
    return code
}

Tr(key, args*) {
    global I18N_CUR, I18N_FB
    local s := I18N_CUR.Has(key) ? I18N_CUR[key] : (I18N_FB.Has(key) ? I18N_FB[key] : key)
    for i, a in args
        s := StrReplace(s, "{" . i . "}", a)
    return s
}

I18nInit("auto")        ; system language until config.ini is read; Translator.ahk calls it again with the saved setting
