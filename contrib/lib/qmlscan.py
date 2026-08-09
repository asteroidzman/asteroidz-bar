"""Text-like blocks that do not set a font property THEMSELVES.

Two mistakes are baked into this file as guards, because both produced a clean
report against a tree that was not clean:

  Indentation. Finding a block's end by looking for the opener's indent followed
  by `}` ends the block early. That reported elements as missing a font they
  already set and produced 33 duplicate insertions. Braces are counted instead,
  skipping strings and comments.

  Nesting. A Text containing another Text satisfied the OUTER element's check
  with the INNER element's property -- so an element whose own font was missing
  was reported as fine. Only depth-1 lines count now.

An element that assigns the whole `font:` group -- `font: input.font`, taking
another element's -- counts as satisfied and MUST NOT be "fixed". QML rejects a
group assignment alongside a sub-property with "Property has already been
assigned a value", and because these are singletons the failure is not local:
one bad Field.qml took out every type in the shell behind a cascade of "Type X
unavailable", and the panel tests went from 4/4 to 1/4.
"""
import re, pathlib

OPENER = re.compile(r'(?m)^([ \t]*)(Text|TextInput|TextEdit)\s*\{[ \t]*$')

def block_end(s, i):
    depth = 1; n = len(s)
    while i < n and depth:
        ch = s[i]
        if ch in '"\'':
            q = ch; i += 1
            while i < n and s[i] != q:
                i += 2 if s[i] == '\\' else 1
        elif s.startswith("//", i):
            j = s.find("\n", i)
            if j < 0: return n
            i = j
        elif s.startswith("/*", i):
            j = s.find("*/", i)
            i = n if j < 0 else j + 1
        elif ch == '{': depth += 1
        elif ch == '}': depth -= 1
        i += 1
    return i

def own_text(s, start, end):
    """The block's own source, with nested {...} bodies blanked out."""
    out = []; depth = 0; i = start
    while i < end:
        ch = s[i]
        if ch in '"\'':
            q = ch; j = i + 1
            while j < end and s[j] != q:
                j += 2 if s[j] == '\\' else 1
            if depth == 0: out.append(s[i:j+1])
            i = j + 1; continue
        if s.startswith("//", i):
            j = s.find("\n", i); j = end if j < 0 else j
            if depth == 0: out.append(s[i:j])
            i = j; continue
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        elif depth == 0: out.append(ch)
        i += 1
    return "".join(out)

def scan(root, prop="font.family"):
    """-> (offenders, total); offender = (path, line, kind, insert_at, indent)."""
    pat = re.compile(r'(?m)^\s*%s\s*:' % re.escape(prop))
    group = re.compile(r'(?m)^\s*font\s*:')
    offenders, total = [], 0
    for f in sorted(pathlib.Path(root, "shell").rglob("*.qml")):
        s = f.read_text()
        for m in OPENER.finditer(s):
            total += 1
            start = m.end(); end = block_end(s, start)
            own = own_text(s, start, end)
            if not pat.search(own) and not group.search(own):
                offenders.append((f, s[:m.start()].count("\n") + 1,
                                  m.group(2), start, m.group(1)))
    return offenders, total
