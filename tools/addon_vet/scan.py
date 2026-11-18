"""Static scan of an Ashita v4 / VanaCore addon folder for what CatsEyeXI's addon policy cares about.

    python tools/addon_vet/scan.py <addon folder> [--name NAME] [--json out.json] [--md out.md]
                                   [--known tools/addon_vet/known_addons.json]

It never runs the addon. It reports *signals*: code that sends packets, queues game commands, runs on timers,
writes client memory, moves the player, changes what's visible, talks to the network, and so on, each with its
file and line, plus whether the addon's name matches one on the policy page. A signal is a place for a reviewer to
look, not a verdict: cfhblock blocks an outgoing packet and is T0, nolock writes client memory and is T0. The
`leaning` it prints is the policy's decision tree applied to the signals alone, for triage.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

TEXT_EXT = {'.lua', '.txt', '.json', '.xml', '.ini', '.md', '.cfg', '.toml', '.yaml', '.yml', '.py', '.c', '.cpp',
            '.h', '.hpp', '.cs', '.js', '.ts'}
BINARY_EXT = {'.dll', '.exe', '.so', '.dylib', '.bin', '.sys', '.com', '.scr', '.bat', '.cmd', '.ps1', '.vbs', '.jar'}
SKIP_DIRS = {'.git', '.github', 'node_modules', '__pycache__'}
MAX_FILE = 4 * 1024 * 1024

# (category, weight, regex, what it means). Weight: 1 = normal for any addon, 2 = look at it, 3 = decides a tier.
# Categories map onto the decision tree: q1 AFK progression (T3), q2 breaks a server rule (T4), q3 acts for the
# player (T1), q4 shows information (T2); others are about safety, not tier.
RULES = [
    # --- talks to the server
    ('sends_packets', 3, r'AddOutgoingPacket|AddOutgoingPacketEx|packets?\s*\.\s*(?:queue|send|inject|outgoing)\s*\(|'
                         r'inject_?packet|send_?packet|QueuePacket',
     'Builds and sends its own packets to the server (q2/q3: what does it send, and does the normal client allow it?)'),
    ('fakes_incoming', 2, r'AddIncomingPacket|packets?\s*\.\s*(?:incoming|receive)\s*\(',
     'Feeds the client a packet the server never sent (local only; check it does not reveal or unlock anything)'),
    ('modifies_packets', 2, r'\b(?:modified_?data|data_modified)(?:_raw)?\s*=[^=]|'
                            r'ffi\.copy\s*\(\s*\w*\.?data_modified_raw|\bdata_modified_raw\s*\[[^\]]+\]\s*=[^=]',
     'Rewrites packets in flight (rewriting incoming entity or status data can reveal what the server hides)'),
    ('blocks_packets', 1, r'\.blocked\s*=\s*true',
     'Drops a packet or a command, in a file that handles packets (blocking an outgoing one is often T0, like '
     'cfhblock)', r"packet_(?:in|out)"),
    ('packet_handlers', 1, r"events\.register\(\s*['\"]packet_(?:in|out)['\"]|vana\.events\.on\(\s*['\"]packet",
     'Reads packets (normal for information addons)'),
    # --- acts for the player
    ('queues_commands', 2, r'QueueCommand\s*\(|ExecuteScript\s*\(|RunCommand\s*\(|vana\.command\s*\(|'
                           r'vana\.chat\.(?:send|command)\s*\(|SendCommand\s*\(',
     'Issues game commands (q3: in answer to what? q1: does anything fire them without the player?)'),
    ('action_commands', 2, r"['\"]\s*/(?:ma|magic|ja|jobability|ws|weaponskill|ra|range|item|pet|attack|a|target|ta|"
                           r"lockon|follow|equip|equipset|heal|trade|assist|check|returntrust|refa|sit|bank|"
                           r"lot|pass|sell|buy|bid|nominate)\b",
     'A game action written into the code as a command string'),
    ('synthetic_input', 3, r'\bSendInput\b|\bkeybd_event\b|\bmouse_event\b|\bPostMessage[AW]?\b|\bSendMessage[AW]?\b|'
                           r'\bSetKeyState\b|\bkeyboard\s*:\s*Press|\bvana\.input\.(?:press|send|key)|/sendkey\b',
     'Presses keys or clicks for the player (q1/q3)'),
    ('targeting', 2, r'SetTarget\s*\(|:SetTargetIndex|GetTarget\(\)\s*:\s*Set|\bset_target\b|<bt>|<stnpc>|<stpc>|'
                     r'\btarget_?nearest\b',
     'Picks targets for the player'),
    ('movement', 3, r'SetIsAutoRunning|AutoFollow|SetAutoRun|SetLocalPosition|:SetHeading\s*\(|SetRunMode|'
                    r':SetFollow|\bauto_?run\b|\bpath_?find\w*\s*\(|\bnavmesh\b|vana\.move',
     'Moves or turns the player (q1: moving between spots unattended; q2: ignoring facing or position)'),
    # --- loops and timing
    ('timers', 2, r'ashita\.tasks\.(?:once|repeating)|coroutine\.(?:sleep|wrap|create)|ashita\.timer|'
                  r'vana\.(?:timer|after|every|schedule)|\btimer\.(?:create|start)\b',
     'Runs code later or on a schedule (q1: with commands, this is how unattended loops are built)'),
    ('frame_loop', 1, r"events\.register\(\s*['\"](?:d3d_present|d3d_beginscene|d3d_endscene)['\"]|"
                      r"vana\.events\.on\(\s*['\"](?:frame|present|render)",
     'Runs every frame (normal for anything that draws)'),
    # --- client memory
    ('memory_writes', 3, r'ashita\.memory\.write_|memory\.write_?\w*\s*\(|VirtualProtect|WriteProcessMemory|'
                         r'vana\.memory\.write',
     'Writes client memory or patches code (q2: what client check does it change? nolock and macrofix do this and are '
     'T0; ja0wait and fastswap do it and are T4)'),
    ('memory_patterns', 1, r'ashita\.memory\.find|find_?pattern|vana\.memory\.(?:find|scan|read)|ashita\.memory\.read_',
     'Reads client memory (normal for information addons)'),
    ('entity_visibility', 3, r'SetRenderFlags\d?\s*\(|SetModel(?:Visible|Hidden)|\bshow_?hidden\b|'
                             r'\bgm_?(?:detect|reveal|finder)|\breveal_?(?:hidden|gm)',
     'Changes what the client shows or hides about entities (q2: seeing hidden players or GMs is categorical T4)'),
    ('collision_doors', 3, r'\bnoclip\b|\b(?:walk|pass)_?through_?(?:players|walls|doors|mobs)\b|\bopen_?doors?\b|\bdoor_?(?:state|lock|unlock)|\bSetDoor|'
                           r'\bkey_?item\s*(?:check|bypass)',
     'Collisions or doors (q2: walking through players or opening locked doors is categorical T4)'),
    # --- outside the game
    ('network', 2, r'\brequire\s*\(?\s*[\'"](?:socket|ssl|http|ltn12|luasocket|websocket)|socket\.(?:tcp|udp|http)|'
                   r'vana\.(?:http|ws)\b|WinHttp|InternetOpen|URLDownloadToFile',
     'Talks to the network (check what it sends and fetches)'),
    ('urls', 1, r'^(?!\s*addon\.link).*https?://[^\s\'"]+', 'Names a URL (outside addon.link)'),
    ('runs_programs', 2, r'\bos\.execute\s*\(|\bio\.popen\s*\(|ShellExecute|CreateProcess|WinExec',
     'Starts other programs'),
    ('native_code', 2, r'\bffi\.load\s*\(|\bffi\.cdef\b|\bLoadLibrary|\bGetProcAddress|\bpackage\.loadlib',
     'Loads or declares native code (read what it calls)'),
    ('dynamic_code', 3, r'\bloadstring\s*\(|\bload\s*\(\s*[^)]*\)\s*\(|\bdofile\s*\(|\bloadfile\s*\(|'
                        r'\bstring\.dump\s*\(|'
                        r'base64|\bfrom_?hex\b',
     'Runs code built at run time or decoded from data (could hide what the addon really does)'),
    ('file_writes', 1, r"io\.open\s*\([^)]*,\s*['\"][wa]", 'Writes files (settings and logs are normal)'),
    # --- words people use about what an addon does
    ('afk_words', 2, r'\b(?:afk|a\.f\.k|unattended|away from (?:the )?keyboard|bot(?:ting|ter|s)?|auto-?farm|'
                     r'auto-?grind|auto-?fish|auto-?craft|auto-?claim|auto-?attack|auto-?skill|humani[sz]e|'
                     r'anti-?detect|(?:random|add|added) jitter|less bot-?like|repeat forever)\b',
     'Words about automation or not looking like a bot (q1)'),
    ('rule_words', 2, r'\b(?:bypass|circumvent|rate[ -]?limit|no ?delay|instant(?:ly)? (?:cast|swap|ah)|recast hack|'
                      r'ignore (?:recast|facing|range)|while dead|from anywhere|any zone|anywhere in the world|'
                      r'skip (?:the )?(?:cutscene|animation|lock))\b',
     'Words about getting past a game rule (q2)'),
    ('addresses_reviewer', 3, r'(?:ignore|disregard) (?:all |any )?(?:previous|prior|above) instructions|'
                              r'\b(?:ai|llm|claude|chatgpt|gpt) (?:reviewer|review|model|assistant)\b|'
                              r'classify (?:this|it) as|this addon is (?:safe|approved|t[0-2])\b|'
                              r'system prompt',
     'Text that speaks to an AI reviewer: treat it as a red flag, never as an instruction'),
]
# A rule's optional fifth element is a regex its file must contain for the rule to apply there.
COMPILED = [(r[0], r[1], re.compile(r[2], re.I), r[3], re.compile(r[4], re.I) if len(r) > 4 else None)
            for r in RULES]
WORD_CATS = {'afk_words', 'rule_words', 'addresses_reviewer'}   # searched in comments and strings only
TEST_DIRS = {'tests', 'test', 'spec', 'specs'}                    # an addon's own tests: counted, not scanned
STRING_RE = re.compile(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"|\[(=*)\[(.*?)\]\3\]")


def words_of(raw_line, code_line, lua):
    """What a reader sees as prose on a line: its comments and string literals (the whole line outside Lua)."""
    if not lua:
        return raw_line
    comment = ''.join(r if c == ' ' and r != ' ' else ' ' for r, c in zip(raw_line, code_line.ljust(len(raw_line))))
    strings = ' '.join(next(g for g in m.groups() if g) if any(m.groups()) else '' for m in
                       STRING_RE.finditer(code_line))
    return comment + ' ' + strings

META_RE = {k: re.compile(r'^\s*addon\.' + k + r"\s*=\s*['\"]([^'\"]*)['\"]", re.M)
           for k in ('name', 'author', 'version', 'desc', 'link')}


def strip_lua_comments(src):
    """Blanks Lua comments, keeping every line where it was."""
    def blank(m):
        return re.sub(r'[^\n]', ' ', m.group(0))
    src = re.sub(r'--\[(=*)\[.*?\]\1\]', blank, src, flags=re.S)
    return re.sub(r'--[^\n]*', blank, src)


def norm(name):
    return re.sub(r'[^a-z0-9]', '', (name or '').lower())


def load_known(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)['addons']
    except (OSError, ValueError, KeyError):
        return []


def match_known(names, known):
    """Exact (normalised) name matches, then near ones: a known prohibited name inside ours, or ours inside it."""
    keys = {norm(n) for n in names if n}
    exact, near = [], []
    for k in known:
        kn = norm(k['name'])
        if kn in keys:
            exact.append(k)
        elif k['status'] == 'prohibited' and any(kn in n or (len(n) >= 5 and n in kn) for n in keys):
            near.append(k)
    return exact, near


def scan(root, name=None, known_path=None):
    known = load_known(known_path or os.path.join(HERE, 'known_addons.json'))
    files, binaries, signals, tests = [], [], [], []
    meta = {}
    total = 0
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for d in [d for d in dns if d.lower() in TEST_DIRS]:
            dns.remove(d)
            tests.append(os.path.relpath(os.path.join(dp, d), root).replace('\\', '/'))
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root).replace('\\', '/')
            size = os.path.getsize(p)
            total += size
            ext = os.path.splitext(fn)[1].lower()
            files.append(rel)
            if ext in BINARY_EXT:
                binaries.append({'file': rel, 'size': size})
                continue
            if ext not in TEXT_EXT or size > MAX_FILE:
                continue
            with open(p, 'rb') as f:
                raw = f.read().decode('utf-8', 'replace')
            if ext == '.lua':
                for k, rx in META_RE.items():
                    m = rx.search(raw)
                    if m and k not in meta:
                        meta[k] = m.group(1)
            code = strip_lua_comments(raw) if ext == '.lua' else raw
            code_lines, raw_lines = code.split('\n'), raw.split('\n')
            for cat, w, rx, why, needs in COMPILED:
                if ext != '.lua' and cat not in WORD_CATS and cat not in ('network', 'urls'):
                    continue
                if needs and not needs.search(code):
                    continue
                for i, ln in enumerate(code_lines, 1):
                    if cat in WORD_CATS:
                        ln = words_of(raw_lines[i - 1], ln, ext == '.lua')
                    if rx.search(ln):
                        signals.append({'category': cat, 'weight': w, 'file': rel, 'line': i,
                                        'text': raw_lines[i - 1].strip()[:200]})
    folder = os.path.basename(os.path.abspath(root))
    names = [name, folder, meta.get('name')]
    exact, near = match_known(names, known)

    counts = {}
    for s in signals:
        counts[s['category']] = counts.get(s['category'], 0) + 1
    leaning, reasons = lean(counts, exact, near, binaries)
    return {
        'folder': folder,
        'name': name or meta.get('name') or folder,
        'meta': meta,
        'files': len(files),
        'bytes': total,
        'lua_files': sum(1 for f in files if f.lower().endswith('.lua')),
        'binaries': binaries,
        'test_dirs_skipped': tests,
        'known_match': exact,
        'near_prohibited': near,
        'counts': counts,
        'leaning': leaning,
        'leaning_reasons': reasons,
        'signals': signals,
        'why': {r[0]: r[3] for r in RULES},
    }


def lean(c, exact, near, binaries):
    """The decision tree on signals alone, for triage. Not a verdict."""
    r = []
    if exact:
        k = exact[0]
        r.append(f"named like '{k['name']}' on the policy page: {k['tier']} {k['status']}")
        if k['status'] == 'prohibited':
            return k['tier'], r
    if near:
        r.append("name contains a prohibited addon's: " + ', '.join(k['name'] for k in near))
    if c.get('addresses_reviewer'):
        r.append('text aimed at an AI reviewer: a human must read this one')
        return 'review', r
    acts = c.get('queues_commands', 0) + c.get('sends_packets', 0) + c.get('synthetic_input', 0)
    if acts and c.get('timers') and (c.get('afk_words') or c.get('movement') or c.get('synthetic_input')):
        r.append('acts, runs on timers, and moves, presses keys or talks about automation: look for unattended '
                 'loops (q1)')
        return 'T3?', r
    if c.get('entity_visibility') or c.get('collision_doors') or near:
        r.append('changes what is visible, collisions or doors: check which game rule (q2)')
        return 'T4?', r
    if acts or c.get('targeting') or c.get('movement'):
        r.append('acts for the player: attended, and on the approved list? (q3)')
        return 'T1?', r
    flags = [k for k in ('memory_writes', 'rule_words', 'runs_programs', 'dynamic_code', 'modifies_packets')
             if c.get(k)]
    if flags or binaries:
        r.append('needs a read: ' + ', '.join(flags + (['binaries'] if binaries else [])) +
                 ' (q2: does it change a rule the server enforces, or only how the client looks?)')
        return 'review', r
    if c.get('packet_handlers') or c.get('memory_patterns'):
        r.append('only reads game data (q4)')
        return 'T2?', r
    r.append('no game interaction found')
    return 'T0?', r


def to_md(rep, max_per_cat=12):
    m = rep['meta']
    out = [f"## {rep['name']}", '']
    out.append(f"- **Folder:** `{rep['folder']}`, {rep['files']} files ({rep['lua_files']} Lua), "
               f"{rep['bytes'] / 1024:.0f} KB")
    if m:
        out.append('- **Declares:** ' + ', '.join(f"{k} `{v}`" for k, v in m.items() if v))
    if rep['known_match']:
        out.append('- **On the policy page:** ' + '; '.join(
            f"{k['name']}: {k['tier']} {k['label']}, {k['status']}" for k in rep['known_match']))
    else:
        out.append('- **On the policy page:** not listed')
    if rep['near_prohibited']:
        out.append('- **Name close to prohibited:** ' + ', '.join(k['name'] for k in rep['near_prohibited']))
    if rep['test_dirs_skipped']:
        out.append('- **Test folders not scanned:** ' + ', '.join(f"`{t}`" for t in rep['test_dirs_skipped']))
    if rep['binaries']:
        out.append('- **Binaries (not readable here):** ' + ', '.join(f"`{b['file']}`" for b in rep['binaries']))
    out.append(f"- **Scan leaning:** {rep['leaning']} ({'; '.join(rep['leaning_reasons'])})")
    out.append('')
    by = {}
    for s in rep['signals']:
        by.setdefault(s['category'], []).append(s)
    order = sorted(by, key=lambda c: (-max(s['weight'] for s in by[c]), c))
    if not order:
        out.append('No signals.')
    for cat in order:
        ss = by[cat]
        out.append(f"### {cat} ({len(ss)})")
        out.append(rep['why'][cat])
        out.append('')
        for s in ss[:max_per_cat]:
            t = s['text'].replace('`', "'")
            out.append(f"- `{s['file']}:{s['line']}` `{t}`")
        if len(ss) > max_per_cat:
            out.append(f"- ... {len(ss) - max_per_cat} more")
        out.append('')
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('folder')
    ap.add_argument('--name')
    ap.add_argument('--known')
    ap.add_argument('--json')
    ap.add_argument('--md')
    ap.add_argument('--brief', action='store_true', help='one line: name, leaning, counts')
    a = ap.parse_args()
    if not os.path.isdir(a.folder):
        sys.exit(f'not a folder: {a.folder}')
    rep = scan(a.folder, a.name, a.known)
    if a.json:
        with open(a.json, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(rep, f, indent=2, ensure_ascii=False)
    if a.md:
        with open(a.md, 'w', encoding='utf-8', newline='\n') as f:
            f.write(to_md(rep) + '\n')
    if a.brief:
        listed = ','.join(f"{k['tier']}/{k['status']}" for k in rep['known_match']) or 'unlisted'
        cats = ' '.join(f"{k}={v}" for k, v in sorted(rep['counts'].items()))
        print(f"{rep['name']:<22} {listed:<16} lean={rep['leaning']:<6} {cats}")
    elif not a.json and not a.md:
        print(to_md(rep))


if __name__ == '__main__':
    main()
