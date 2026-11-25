"""Builds Profguild/Data.lua: for every recipe the item that teaches it, where that item comes from,
the skill needed to learn it, the skill levels at which it turns yellow and grey, and its skill line.

    python -I tools/recipe_data.py [--recheck] [--build 1.60.1.71037]

--recheck asks Wowhead again for the recipe items it named no source for.

Recipes, recipe items and skill levels come from the WoW Forever client's own tables, exported by
wago.tools (product "wowf"):
  SkillLineAbility   every recipe of a crafting skill line, with TrivialSkillLineRankLow (yellow)
                     and TrivialSkillLineRankHigh (grey); green is the middle of the two
  ItemXItemEffect,   the items whose "learn" effect (TriggerType 6) teaches the recipe
  ItemEffect
  ItemSparse         RequiredSkillRank of a recipe item: the skill needed to learn it (orange)
How a recipe item is obtained (looted, sold by NPCs, quest reward, crafted) is not in the client;
it comes from Wowhead's item XML ("source" in its json, WoW Forever path /forever/).

Recipes learned from a trainer have no recipe item; the skill a trainer asks for is server data,
so their learn level stays 0 (unknown).

The client tables are kept in tools/.wago/<build>/, Wowhead answers in tools/.wowhead_cache.json,
and Wowhead requests are paced, so a rerun costs only what is new.
"""
import csv, json, os, re, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, 'Profguild', 'Data.lua')
CACHE = os.path.join(ROOT, 'tools', '.wowhead_cache.json')
WAGO = os.path.join(ROOT, 'tools', '.wago')
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/130.0'
PACE = 2.0  # seconds between two Wowhead requests; faster runs get the IP blocked by its firewall
BUILD = '1.60.1.71037'
# Crafting skill lines: Blacksmithing, Leatherworking, Alchemy, Cooking, Mining (smelting),
# Tailoring, Engineering, First Aid, Enchanting
SKILL_LINES = {164, 165, 171, 185, 186, 197, 202, 129, 333}
# Wowhead's source ids -> the letters Data.lua uses
SOURCES = {2: 'd', 5: 'v', 4: 'q', 1: 'c'}
LETTERS = 'dvqc'
UNWANTED = re.compile(r'^(Deprecated|\[PH\])|\bOLD\b|\bTEST\b', re.I)

cache = json.load(open(CACHE, encoding='utf-8')) if os.path.exists(CACHE) else {}


class Blocked(Exception):
    """Wowhead refuses requests (403/429): stop at once, keep what is done, try again later."""


class Transient(Exception):
    """No usable answer this time (5xx, timeout, firewall page): not cached, asked again next run."""


def fetch(url):
    time.sleep(PACE)
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            raise Blocked('HTTP %d' % e.code)
        if e.code != 404:
            raise Transient('HTTP %d' % e.code)
        return 404, ''
    except (urllib.error.URLError, OSError) as e:  # timeouts, refused connections
        raise Transient(str(e))


def wago_table(name, build):
    """Rows of a client table as dicts, downloaded once per build."""
    path = os.path.join(WAGO, build, name + '.csv')
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        status, body = fetch('https://wago.tools/db2/%s/csv?build=%s' % (name, build))
        if status != 200 or not body.startswith(('ID,', '"ID"')) and ',ID,' not in body.split('\n', 1)[0]:
            sys.exit('wago.tools gave no %s table for build %s' % (name, build))
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(body)
    with open(path, encoding='utf-8', newline='') as f:
        return list(csv.DictReader(f))


def item_url(item_id):
    return 'https://www.wowhead.com/forever/item=%d&xml' % item_id


def cached_info(item_id):
    """What the cache holds for an item: { src: Wowhead source ids, rank, name, found }, or None.
    Older runs kept only the source ids as a string: rank and name are missing there."""
    v = cache.get(item_url(item_id))
    if v is None:
        return None
    if isinstance(v, str):
        return {'src': v}
    return v


def item_info(item_id):
    """Wowhead's data of an item: source letters, skill rank to learn it, name, whether it exists."""
    info = cached_info(item_id)
    if info is None or 'found' not in info:
        status, body = fetch(item_url(item_id))
        if status == 404 or '<error>' in body:
            info = {'src': '', 'found': False}
        elif '<wowhead>' not in body:
            raise Transient('not XML')  # e.g. a firewall challenge page
        else:
            src = re.search(r'"source":\[([\d,]*)\]', body)
            rank = re.search(r'"reqskillrank":(\d+)', body)
            name = re.search(r'<name><!\[CDATA\[(.*?)\]\]></name>', body)
            info = {'src': src.group(1) if src else '', 'rank': int(rank.group(1)) if rank else 0,
                    'name': name.group(1) if name else '', 'found': True}
        cache[item_url(item_id)] = info
    return info


def letters(info):
    ids = {int(x) for x in (info or {}).get('src', '').split(',') if x}
    return ''.join(SOURCES[i] for i in sorted(SOURCES, key=lambda i: LETTERS.index(SOURCES[i])) if i in ids)


def read_data():
    """The recipe items and source letters Data.lua already has."""
    data = {}
    if os.path.exists(DATA):
        text = open(DATA, encoding='utf-8').read()
        for rid, item, src in re.findall(r'\[(\d+)\] = \{ (\d+), "([a-z]*)" \}', text):
            data[int(rid)] = (int(item), src)
    return data


def client_recipes(build):
    """{ recipeID: (yellow, grey, skill line) } and { recipeID: [(itemID, learn skill, name)] } from the client.
    The export lacks ItemSparse rows of many items: their learn skill and name are None here and
    come from Wowhead (an item Wowhead does not know either is a leftover of another version)."""
    colors = {}
    for r in wago_table('SkillLineAbility', build):
        if int(r['SkillLine']) in SKILL_LINES and int(r['TrivialSkillLineRankHigh']) > 0:
            colors[int(r['Spell'])] = (int(r['TrivialSkillLineRankLow']), int(r['TrivialSkillLineRankHigh']),
                                       int(r['SkillLine']))
    learn_effects = {r['ID']: int(r['SpellID']) for r in wago_table('ItemEffect', build) if r['TriggerType'] == '6'}
    sparse = {int(r['ID']): r for r in wago_table('ItemSparse', build)}
    items = {}
    for r in wago_table('ItemXItemEffect', build):
        spell = learn_effects.get(r['ItemEffectID'])
        item = sparse.get(int(r['ItemID']))
        if spell not in colors or (item and UNWANTED.search(item['Display_lang'])):
            continue
        items.setdefault(spell, []).append((int(r['ItemID']), int(item['RequiredSkillRank']) if item else None,
                                            item['Display_lang'] if item else None))
    return colors, items


def write_data(entries):
    lines = [
        '-- Profguild: Data (generated by tools/recipe_data.py, do not edit by hand)',
        '-- From the WoW Forever client tables (wago.tools) and Wowhead\'s item data.',
        '-- [recipeID] = { recipe item, how the item is obtained, skill to learn it, yellow, grey, skill line }',
        '--   recipe item: false when no item teaches it (a trainer recipe or similar)',
        '--   obtained: d looted, v sold by NPCs, q quest reward, c crafted ("" unknown)',
        '--   skill to learn it: 0 unknown (trainer recipes); the recipe is orange from there',
        '--   yellow / grey: skill at which it turns yellow / grey; green from the middle of the two',
        '',
        'local _, ns = ...',
        'ns = ns or {}',
        '',
        'ns.RecipeData = {',
    ]
    for rid in sorted(entries):
        item, src, learn, yellow, grey, line = entries[rid]
        lines.append('\t[%d] = { %s, "%s", %d, %d, %d, %d },' % (rid, 'false' if item is False else item, src, learn, yellow, grey, line))
    lines += ['}', '']
    with open(DATA, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))


def main(build, recheck):
    colors, items = client_recipes(build)
    old = read_data()
    if recheck:
        for url in [u for u, v in cache.items() if '&xml' in u and v == '']:
            del cache[url]
    # every recipe item once; an item without client data also needs its rank and name
    todo = sorted({i for lst in items.values() for i, learn, _ in lst
                   if cached_info(i) is None or (learn is None and 'found' not in cached_info(i))})
    print('recipes %d, with a recipe item %d; Wowhead lookups to do %d (about %d min)'
          % (len(colors), len(items), len(todo), len(todo) * PACE / 60 + 1))
    stopped = False
    for n, item in enumerate(todo, 1):
        try:
            item_info(item)
        except Blocked as e:
            print('Wowhead refused a request (%s) after %d of %d. Stopped; run again later.' % (e, n - 1, len(todo)))
            stopped = True
            break
        except Transient as e:
            print('  item %d: no answer (%s), skipped' % (item, e))
        if n % 25 == 0:
            json.dump(cache, open(CACHE, 'w', encoding='utf-8'))
            print('  %d / %d' % (n, len(todo)), flush=True)
    json.dump(cache, open(CACHE, 'w', encoding='utf-8'))

    entries = {}
    for rid, (yellow, grey, line) in colors.items():
        cands = []
        for item, learn, name in items.get(rid, []):
            info = cached_info(item)
            if learn is None:  # no client data: Wowhead's, or not in the game at all
                if not info or not info.get('found') or UNWANTED.search(info.get('name', '')):
                    continue
                learn = info.get('rank', 0)
            src = letters(info)
            prev = old.get(rid)
            if prev and prev[0] == item:  # Wowhead's search named sources too: keep both
                src = ''.join(c for c in LETTERS if c in src or c in prev[1])
            # prefer the item Data.lua had, then one Wowhead knows a source for, then the lowest id
            cands.append((not (prev and prev[0] == item), src == '', item, learn, src))
        if cands:
            _, _, item, learn, src = min(cands)
            entries[rid] = (item, src, learn, yellow, grey, line)
        else:
            entries[rid] = (False, '', 0, yellow, grey, line)
    write_data(entries)
    with_item = sum(1 for e in entries.values() if e[0] is not False)
    with_src = sum(1 for e in entries.values() if e[1])
    print('Data.lua: %d recipes, %d with a recipe item, %d with a known source%s'
          % (len(entries), with_item, with_src, ' (incomplete, Wowhead stopped)' if stopped else ''))


if __name__ == '__main__':
    args = sys.argv[1:]
    build = args[args.index('--build') + 1] if '--build' in args else BUILD
    main(build, '--recheck' in args)
