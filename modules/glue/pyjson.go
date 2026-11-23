package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	kindNull = iota
	kindBool
	kindNum
	kindStr
	kindArr
	kindObj
)

const (
	jCompact = iota
	jSpaced
	jIndent
)

type JVal struct {
	Kind int
	Bool bool
	Num  string
	Str  string
	Arr  []JVal
	Obj  []JPair
}

type JPair struct {
	Key string
	Val JVal
}

func jNull() JVal                { return JVal{Kind: kindNull} }
func jBool(b bool) JVal          { return JVal{Kind: kindBool, Bool: b} }
func jNum(n string) JVal         { return JVal{Kind: kindNum, Num: n} }
func jStr(s string) JVal         { return JVal{Kind: kindStr, Str: s} }
func jArr(vs ...JVal) JVal       { return JVal{Kind: kindArr, Arr: vs} }
func jObj(ps ...JPair) JVal      { return JVal{Kind: kindObj, Obj: ps} }
func jkv(k string, v JVal) JPair { return JPair{Key: k, Val: v} }

func (v *JVal) Set(key string, val JVal) {
	for i := range v.Obj {
		if v.Obj[i].Key == key {
			v.Obj[i].Val = val
			return
		}
	}
	v.Obj = append(v.Obj, JPair{Key: key, Val: val})
}

func (v *JVal) ObjAt(key string) *JVal {
	if v == nil || v.Kind != kindObj {
		return nil
	}
	for i := range v.Obj {
		if v.Obj[i].Key == key && v.Obj[i].Val.Kind == kindObj {
			return &v.Obj[i].Val
		}
	}
	return nil
}

func (v *JVal) setDefaultObj(key string) (*JVal, error) {
	if v.Kind != kindObj {
		return nil, fmt.Errorf("%s is not an object", key)
	}
	for i := range v.Obj {
		if v.Obj[i].Key == key {
			if v.Obj[i].Val.Kind != kindObj {
				return nil, fmt.Errorf("%s is not an object", key)
			}
			return &v.Obj[i].Val, nil
		}
	}
	v.Obj = append(v.Obj, JPair{Key: key, Val: jObj()})
	return &v.Obj[len(v.Obj)-1].Val, nil
}

func parseJSON(s string) (JVal, error) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	v, err := decodeJ(dec)
	if err != nil {
		return JVal{}, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return JVal{}, fmt.Errorf("trailing data in json")
	}
	return v, nil
}

func decodeJ(dec *json.Decoder) (JVal, error) {
	tok, err := dec.Token()
	if err != nil {
		return JVal{}, err
	}
	switch t := tok.(type) {
	case nil:
		return jNull(), nil
	case bool:
		return jBool(t), nil
	case json.Number:
		return jNum(t.String()), nil
	case string:
		return jStr(t), nil
	case json.Delim:
		switch t {
		case '{':
			var obj []JPair
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return JVal{}, err
				}
				key, ok := kt.(string)
				if !ok {
					return JVal{}, fmt.Errorf("json key is not a string")
				}
				val, err := decodeJ(dec)
				if err != nil {
					return JVal{}, err
				}
				obj = append(obj, JPair{Key: key, Val: val})
			}
			if _, err := dec.Token(); err != nil {
				return JVal{}, err
			}
			return JVal{Kind: kindObj, Obj: obj}, nil
		case '[':
			var arr []JVal
			for dec.More() {
				val, err := decodeJ(dec)
				if err != nil {
					return JVal{}, err
				}
				arr = append(arr, val)
			}
			if _, err := dec.Token(); err != nil {
				return JVal{}, err
			}
			return JVal{Kind: kindArr, Arr: arr}, nil
		default:
			return JVal{}, fmt.Errorf("unexpected json delimiter")
		}
	default:
		return JVal{}, fmt.Errorf("unexpected json token %T", tok)
	}
}

func (v JVal) Marshal(mode int) []byte {
	return v.appendJSON(nil, mode, 0)
}

func (v JVal) appendJSON(dst []byte, mode, level int) []byte {
	switch v.Kind {
	case kindNull:
		return append(dst, "null"...)
	case kindBool:
		if v.Bool {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case kindNum:
		return append(dst, v.Num...)
	case kindStr:
		return appendPyString(dst, v.Str)
	case kindArr:
		if len(v.Arr) == 0 {
			return append(dst, '[', ']')
		}
		if mode != jIndent {
			dst = append(dst, '[')
			for i, el := range v.Arr {
				if i > 0 {
					dst = appendSep(dst, mode)
				}
				dst = el.appendJSON(dst, mode, level+1)
			}
			return append(dst, ']')
		}
		dst = append(dst, '[', '\n')
		for i, el := range v.Arr {
			if i > 0 {
				dst = append(dst, ',', '\n')
			}
			dst = append(dst, pad(2*(level+1))...)
			dst = el.appendJSON(dst, mode, level+1)
		}
		dst = append(dst, '\n')
		dst = append(dst, pad(2*level)...)
		return append(dst, ']')
	case kindObj:
		if len(v.Obj) == 0 {
			return append(dst, '{', '}')
		}
		if mode != jIndent {
			dst = append(dst, '{')
			for i, p := range v.Obj {
				if i > 0 {
					dst = appendSep(dst, mode)
				}
				dst = appendPyString(dst, p.Key)
				dst = appendColon(dst, mode)
				dst = p.Val.appendJSON(dst, mode, level+1)
			}
			return append(dst, '}')
		}
		dst = append(dst, '{', '\n')
		for i, p := range v.Obj {
			if i > 0 {
				dst = append(dst, ',', '\n')
			}
			dst = append(dst, pad(2*(level+1))...)
			dst = appendPyString(dst, p.Key)
			dst = appendColon(dst, mode)
			dst = p.Val.appendJSON(dst, mode, level+1)
		}
		dst = append(dst, '\n')
		dst = append(dst, pad(2*level)...)
		return append(dst, '}')
	default:
		return append(dst, "null"...)
	}
}

func appendSep(dst []byte, mode int) []byte {
	if mode == jCompact {
		return append(dst, ',')
	}
	return append(dst, ',', ' ')
}

func appendColon(dst []byte, mode int) []byte {
	if mode == jCompact {
		return append(dst, ':')
	}
	return append(dst, ':', ' ')
}

func pad(n int) []byte {
	if n <= 0 {
		return nil
	}
	return bytes.Repeat([]byte{' '}, n)
}

func appendPyString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for _, r := range s {
		switch r {
		case '"':
			dst = append(dst, '\\', '"')
		case '\\':
			dst = append(dst, '\\', '\\')
		case '\b':
			dst = append(dst, '\\', 'b')
		case '\f':
			dst = append(dst, '\\', 'f')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\r':
			dst = append(dst, '\\', 'r')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			if r < 0x20 || r == 0x2028 || r == 0x2029 || r > 0x7f {
				dst = appendPyRune(dst, r)
			} else {
				dst = utf8.AppendRune(dst, r)
			}
		}
	}
	return append(dst, '"')
}

func appendPyRune(dst []byte, r rune) []byte {
	if r > 0xFFFF {
		r -= 0x10000
		hi := rune(0xD800 + (r >> 10))
		lo := rune(0xDC00 + (r & 0x3FF))
		dst = fmt.Appendf(dst, `\u%04x`, hi)
		return fmt.Appendf(dst, `\u%04x`, lo)
	}
	return fmt.Appendf(dst, `\u%04x`, r)
}

func readJSONFile(path string) (JVal, error) {
	b, err := osReadFile(path)
	if err != nil {
		return JVal{}, err
	}
	v, err := parseJSON(string(b))
	if err != nil {
		return JVal{}, fmt.Errorf("%s: %w", path, err)
	}
	if v.Kind != kindObj {
		return JVal{}, fmt.Errorf("%s: json root is not an object", path)
	}
	return v, nil
}

func writeJSONFile(path string, v JVal, mode int, newline bool) error {
	buf := v.Marshal(mode)
	if newline {
		buf = append(buf, '\n')
	}
	return osWriteFile(path, buf, 0o644)
}
