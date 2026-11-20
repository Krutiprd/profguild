"""Builds Profguild/Data.lua: for every recipe the item that teaches it and where that item comes from.

    python -I tools/recipe_data.py [--recheck] <path to SavedVariables/Profguild.lua> [more files]

--recheck also looks up again the recipes Data.lua lists without a recipe item.

Recipe IDs come from the recipe catalog and from every guild member's record in the saved
files. For each recipe the spell name is read from Wowhead's tooltip API (WoW Forever is
dataEnv 16) and the recipe item from Wowhead's search ("Recipe: <name>", "Pattern: ..."). The
search result says how the item is obtained (looted, sold by NPCs, quest reward, crafted).

Only recipes not yet in Data.lua are looked up, answers are cached in tools/.wowhead_cache.json
and requests are paced, so a rerun after opening a new profession costs a few requests.
"""
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, 'Profguild', 'Data.lua')
CACHE = os.path.join(ROOT, 'tools', '.wowhead_cache.json')
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/130.0'
PACE = 2.0  # seconds between two requests; faster runs get the IP blocked by Wowhead's firewall
PREFIX = r'^(Recipe|Formula|Pattern|Plans|Schematic|Manual|Design|Technique)\s*:'

cache = json.load(open(CACHE, encoding='utf-8')) if os.path.exists(CACHE) else {}
RECHECK = False
RECHECK_IDS = set()


class Blocked(Exception):
    """Wowhead refuses requests (403/429): stop at once, keep what is done, try again later."""


class Transient(Exception):
    """No usable answer this time (5xx, timeout, not JSON): not cached, asked again next run."""


def get(url):
    """JSON answer of a URL. Only real answers are cached: 200 with JSON, and 404 (unknown id)."""
    if url in cache:
        return json.loads(cache[url])
    time.sleep(PACE)
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            raise Blocked('HTTP %d' % e.code)
        if e.code != 404:
            raise Transient('HTTP %d' % e.code)
        body = json.dumps({'error': 'HTTP 404'})
    except (urllib.error.URLError, OSError) as e:  # timeouts, refused connections
        raise Transient(str(e))
    try:
        answer = json.loads(body)
    except ValueError:
        raise Transient('not JSON')  # e.g. a firewall challenge page
    cache[url] = body
    return answer


def block(text, start):
    i = text.find(start)
    if i < 0:
        return ''
    depth = 0
    for k in range(i, len(text)):
        if text[k] == '{':
            depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0:
                return text[i:k]
    return ''


def recipe_ids(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    ids = set()
    # catalog: [skillLine] = { [recipeID] = itemID }
    for m in re.finditer(r'\[\d+\] = \{([^{}]*)\}', block(text, '["catalog"] = {')):
        ids.update(int(a) for a in re.findall(r'\[(\d+)\] = \d+', m.group(1)))
    # guild records: ["r"] = { [recipeID] = itemID }
    for m in re.finditer(r'\["r"\] = \{([^{}]*)\}', block(text, '["guilds"] = {')):
        ids.update(int(a) for a in re.findall(r'\[(\d+)\] = \d+', m.group(1)))
    return ids


def source_code(description):
    d = description.lower()
    code = ''
    if 'looted' in d or 'drop' in d:
        code += 'd'
    if 'sold by' in d:
        code += 'v'
    if 'quest' in d:
        code += 'q'
    if 'crafted' in d:
        code += 'c'
    return code


def norm(t):
    return re.sub(r'[^a-z0-9]', '', t.lower())


def lookup(recipe_id):
    tip = get('https://nether.wowhead.com/tooltip/spell/%d?dataEnv=16' % recipe_id)
    name = tip.get('name')
    if not name:
        return None
    url = 'https://www.wowhead.com/forever/search/suggestions-template?q=' + urllib.parse.quote(name)
    if RECHECK and recipe_id in RECHECK_IDS:
        cache.pop(url, None)  # --recheck: ask the search again, not the cached answer
    answer = get(url)
    if 'results' not in answer:
        cache.pop(url, None)  # no usable answer: not kept, looked up again next time
        return None
    for r in answer['results']:
        if r.get('type') == 3 and re.match(PREFIX, r.get('name', '')) and norm(r['name'].split(':', 1)[1]) == norm(name):
            return r['id'], source_code(r.get('pinDescription', ''))
    return False  # the game knows it, Wowhead lists no item: learned from a trainer or found otherwise


def read_data():
    data = {}
    if os.path.exists(DATA):
        for rid, item, src in re.findall(r'\[(\d+)\] = \{ (\d+), "([a-z]*)" \}', open(DATA, encoding='utf-8').read()):
            data[int(rid)] = (int(item), src)
        for rid in re.findall(r'\[(\d+)\] = false', open(DATA, encoding='utf-8').read()):
            data[int(rid)] = False
    return data


def write_data(data):
    lines = [
        '-- Profguild: Data (generated by tools/recipe_data.py from Wowhead, do not edit by hand)',
        '-- [recipeID] = { recipe item, how the item is obtained }: d looted, v sold by NPCs,',
        '-- q quest reward, c crafted. false: Wowhead lists no item that teaches the recipe.',
        '',
        'local _, ns = ...',
        'ns = ns or {}',
        '',
        'ns.RecipeData = {',
    ]
    for rid in sorted(data):
        v = data[rid]
        lines.append('\t[%d] = false,' % rid if v is False else '\t[%d] = { %d, "%s" },' % (rid, v[0], v[1]))
    lines += ['}', '']
    with open(DATA, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))


def main(paths):
    ids = set()
    for p in paths:
        ids |= recipe_ids(p)
    data = read_data()
    # new recipes first; "no recipe item" entries are checked again only with --recheck, and
    # keep their value until a lookup gives a real answer
    todo = sorted(i for i in ids if i not in data)
    if RECHECK:
        RECHECK_IDS.update(r for r, v in data.items() if v is False)
        todo += sorted(RECHECK_IDS)
    print('recipes %d, already in Data.lua %d, to look up %d' % (len(ids), len(ids) - len(todo), len(todo)))
    for n, rid in enumerate(todo, 1):
        try:
            found = lookup(rid)
        except Blocked as e:
            print('Wowhead refused a request (%s) after %d of %d. Stopped; run again later.' % (e, n - 1, len(todo)))
            break
        except Transient as e:
            print('  recipe %d: no answer (%s), skipped' % (rid, e))
            continue
        if found is not None:
            data[rid] = found
        if n % 25 == 0:
            json.dump(cache, open(CACHE, 'w', encoding='utf-8'))
            print('  %d / %d' % (n, len(todo)))
    json.dump(cache, open(CACHE, 'w', encoding='utf-8'))
    write_data(data)
    items = sum(1 for v in data.values() if v)
    print('Data.lua: %d recipes, %d with a recipe item' % (len(data), items))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--recheck']
    RECHECK = '--recheck' in sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    main(args)
