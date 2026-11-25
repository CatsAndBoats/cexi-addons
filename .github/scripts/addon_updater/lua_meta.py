"""
Reading addon.* metadata out of an addon's lua source.

Python twin of LuaMeta.cs in cexi-launcher-v2.App/Source, which is what players'
launchers use to read the version. Keep the two in step.

Comments are stripped first, so a commented-out line like

    --addon.version   = '0.9';

is never picked up. A value assigned from a variable is followed back to its string:

    local ver = '1.0.260921'
    addon.version = ver

Also handles _addon.* (Windower), "..." / '...' / [[...]] strings, numbers,
tostring(x) and .. concatenation of any of those.
"""

import re

_MAX_DEPTH = 8

_IDENTIFIER = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*")
_NUMBER = re.compile(r"0[xX][0-9a-fA-F]+|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}


def get(content, field):
    """
    The value assigned to field (e.g. "addon.version"), or "" if there is no
    uncommented assignment that resolves to a string.
    """
    if not content:
        return ""

    code = strip_comments(content)

    for match in _assignment_pattern(field, True).finditer(code):
        ok, value, _ = _eval(code, match.end(), 0)
        if ok:
            return value

    return ""


def _assignment_pattern(name, is_field):
    # "<name> =" but not "<name> ==", and not as the tail of a longer name
    # (myaddon.version). The addon.* fields also match _addon.* for Windower.
    prefix = "_?" if is_field else r"(?:\blocal\s+)?"
    return re.compile(r"(?<![\w.:])%s%s\s*=(?!=)" % (prefix, re.escape(name)))


def strip_comments(src):
    """
    Blank out -- line comments and --[[ ]] / --[==[ ]==] block comments, leaving
    strings alone (so a "--" inside a string survives). Newlines are kept and every
    other comment character becomes a space, so offsets match the original.
    """
    out = list(src)
    i = 0
    n = len(src)

    while i < n:
        c = src[i]

        if c == "-" and src.startswith("-", i + 1):
            level = _long_bracket_level(src, i + 2)
            if level >= 0:
                close = "]" + "=" * level + "]"
                close_at = src.find(close, i + 2 + level + 2)
                end = n if close_at < 0 else close_at + len(close)
            else:
                newline = src.find("\n", i)
                end = n if newline < 0 else newline

            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        elif c in "'\"":
            i = _skip_quoted_string(src, i)
        elif c == "[" and _long_bracket_level(src, i) >= 0:
            level = _long_bracket_level(src, i)
            close = "]" + "=" * level + "]"
            close_at = src.find(close, i + level + 2)
            i = n if close_at < 0 else close_at + len(close)
        else:
            i += 1

    return "".join(out)


def _long_bracket_level(src, i):
    """At "[[" or "[==[" returns the number of '=', otherwise -1."""
    if i >= len(src) or src[i] != "[":
        return -1
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    return j - i - 1 if j < len(src) and src[j] == "[" else -1


def _skip_quoted_string(src, i):
    """From an opening quote, the index just past the closing one (or the end of
    the line, for an unterminated string)."""
    quote = src[i]
    i += 1
    while i < len(src):
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i + 1
        if c == "\n":
            return i
        i += 1
    return len(src)


def _skip_space(code, pos):
    while pos < len(code) and code[pos].isspace():
        pos += 1
    return pos


def _eval(code, pos, depth):
    """A term, optionally joined by "..". Returns (ok, value, end)."""
    if depth > _MAX_DEPTH:
        return False, "", pos

    ok, term, pos = _term(code, pos, depth)
    if not ok:
        return False, "", pos

    parts = [term]
    while True:
        nxt = _skip_space(code, pos)
        if not code.startswith("..", nxt) or code.startswith("...", nxt):
            break
        ok, term, pos = _term(code, nxt + 2, depth)
        if not ok:
            return False, "", pos
        parts.append(term)

    return True, "".join(parts), pos


def _term(code, pos, depth):
    pos = _skip_space(code, pos)
    if pos >= len(code):
        return False, "", pos

    c = code[pos]

    # 'string' / "string"
    if c in "'\"":
        end = _skip_quoted_string(code, pos)
        if end <= pos + 1 or code[end - 1] != c:
            return False, "", pos
        return True, _unescape(code[pos + 1 : end - 1]), end

    # [[string]] / [==[string]==]
    level = _long_bracket_level(code, pos)
    if level >= 0:
        close = "]" + "=" * level + "]"
        start = pos + level + 2
        close_at = code.find(close, start)
        if close_at < 0:
            return False, "", pos
        # Lua drops a newline straight after the opening bracket
        if code.startswith("\r", start) and start < close_at:
            start += 1
        if code.startswith("\n", start) and start < close_at:
            start += 1
        return True, code[start:close_at], close_at + len(close)

    # 1.0, 2, 0x10
    number = _NUMBER.match(code, pos)
    if number:
        return True, number.group(0), number.end()

    name = _IDENTIFIER.match(code, pos)
    if not name:
        return False, "", pos

    # tostring(x)
    if name.group(0) == "tostring":
        open_at = _skip_space(code, name.end())
        if not code.startswith("(", open_at):
            return False, "", pos
        ok, value, inner = _eval(code, open_at + 1, depth + 1)
        close_at = _skip_space(code, inner)
        if not ok or not code.startswith(")", close_at):
            return False, "", pos
        return True, value, close_at + 1

    end = name.end()

    # a call like string.format(...) is beyond us
    after = _skip_space(code, end)
    if after < len(code) and code[after] in "([:":
        return False, "", pos

    ok, value = _resolve(code, name.group(0), pos, depth + 1)
    return ok, value, end


def _resolve(code, name, used_at, depth):
    """
    Follow a variable back to what was assigned to it: the last assignment before
    it is used, or failing that the first one anywhere in the file.
    """
    if depth > _MAX_DEPTH or name in ("nil", "true", "false"):
        return False, ""

    assignments = list(_assignment_pattern(name, False).finditer(code))
    best = None

    for m in assignments:
        if m.start() >= used_at:
            if best is None:
                best = m
            break
        # skip "ver = ver .. 'x'" resolving ver to itself
        if "\n" in code[m.start() : used_at]:
            best = m

    if best is None:
        return False, ""

    # Try the chosen one first, then the rest in order
    for m in [best] + [a for a in assignments if a is not best]:
        ok, value, _ = _eval(code, m.end(), depth)
        if ok:
            return True, value

    return False, ""


def _unescape(s):
    if "\\" not in s:
        return s
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            i += 1
            out.append(_ESCAPES.get(s[i], s[i]))
        else:
            out.append(s[i])
        i += 1
    return "".join(out)
