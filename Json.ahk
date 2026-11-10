;=====================================================================
; Minimal JSON parser/generator (#Included by Translator.ahk)
; JsonParse: object -> Map, array -> Array, true/false -> 1/0, null -> ""
; JsonStr: converts an AHK string into a quoted, escaped JSON string literal
;=====================================================================

JsonParse(s) {
    local pos := 1
    local v := JsonValue(s, &pos)
    JsonSkipWs(s, &pos)
    if (pos <= StrLen(s))
        throw Error("JSON: unexpected trailing content (at position " pos ")")
    return v
}

JsonValue(s, &pos) {
    JsonSkipWs(s, &pos)
    local ch := SubStr(s, pos, 1)
    switch ch {
        case "{":
            local obj := Map()
            pos += 1
            JsonSkipWs(s, &pos)
            if (SubStr(s, pos, 1) = "}") {
                pos += 1
                return obj
            }
            loop {
                JsonSkipWs(s, &pos)
                if (SubStr(s, pos, 1) != '"')
                    throw Error("JSON: object key must be a string (at position " pos ")")
                local k := JsonString(s, &pos)
                JsonSkipWs(s, &pos)
                if (SubStr(s, pos, 1) != ":")
                    throw Error("JSON: missing colon (at position " pos ")")
                pos += 1
                obj[k] := JsonValue(s, &pos)
                JsonSkipWs(s, &pos)
                local sep := SubStr(s, pos, 1)
                pos += 1
                if (sep = "}")
                    return obj
                if (sep != ",")
                    throw Error("JSON: object is missing a comma or } (at position " (pos - 1) ")")
            }
        case "[":
            local arr := []
            pos += 1
            JsonSkipWs(s, &pos)
            if (SubStr(s, pos, 1) = "]") {
                pos += 1
                return arr
            }
            loop {
                arr.Push(JsonValue(s, &pos))
                JsonSkipWs(s, &pos)
                local sep := SubStr(s, pos, 1)
                pos += 1
                if (sep = "]")
                    return arr
                if (sep != ",")
                    throw Error("JSON: array is missing a comma or ] (at position " (pos - 1) ")")
            }
        case '"':
            return JsonString(s, &pos)
        default:
            if RegExMatch(s, "\G-?\d+(\.\d+)?([eE][+-]?\d+)?", &m, pos) {
                pos += m.Len
                return m[0] + 0
            }
            for lit, val in Map("true", 1, "false", 0, "null", "")
                if (SubStr(s, pos, StrLen(lit)) == lit) {
                    pos += StrLen(lit)
                    return val
                }
            throw Error("JSON: malformed (at position " pos ")")
    }
}

; Reads a string starting at the quote at pos; returns the decoded content and moves pos past the closing quote
JsonString(s, &pos) {
    local out := ""
    pos += 1
    local n := StrLen(s)
    loop {
        ; Consume a run of plain characters (no escapes or quotes) at once, to avoid slow char-by-char concatenation
        if RegExMatch(s, '\G[^"\\]+', &m, pos) {
            out .= m[0]
            pos += m.Len
        }
        if (pos > n)
            throw Error("JSON: unterminated string")
        local ch := SubStr(s, pos, 1)
        if (ch = '"') {
            pos += 1
            return out
        }
        local nx := SubStr(s, pos + 1, 1)
        switch nx, true {
            case '"': out .= '"'
            case "\": out .= "\"
            case "/": out .= "/"
            case "n": out .= "`n"
            case "r": out .= "`r"
            case "t": out .= "`t"
            case "b": out .= "`b"
            case "f": out .= "`f"
            case "u":
                local code := Integer("0x" . SubStr(s, pos + 2, 4))
                ; Surrogate pairs (emoji and other non-BMP characters) can be concatenated as-is in UTF-16
                out .= Chr(code)
                pos += 4
            default:
                throw Error("JSON: invalid escape \" nx)
        }
        pos += 2
    }
}

JsonSkipWs(s, &pos) {
    if RegExMatch(s, "\G\s+", &m, pos)
        pos += m.Len
}

JsonStr(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    ; Escape all other control characters as \u sequences
    while RegExMatch(s, "[\x00-\x1F]", &m)
        s := StrReplace(s, m[0], Format("\u{:04x}", Ord(m[0])))
    return '"' . s . '"'
}

; Safe path lookup: JsonGet(obj, "choices", 1, "message", "content"); returns "" if not found
JsonGet(v, path*) {
    for key in path {
        if (v is Map) {
            if !v.Has(key)
                return ""
            v := v[key]
        } else if (v is Array) {
            if (!IsInteger(key) || key < 1 || key > v.Length)
                return ""
            v := v[key]
        } else
            return ""
    }
    return v
}
