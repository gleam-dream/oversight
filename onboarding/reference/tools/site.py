#!/usr/bin/env python3
"""Assemble the onboarding modules into one self-contained website (no quizzes)."""
import json, re, pathlib, importlib.util

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('b', ROOT / 'tools' / 'build.py'); b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

MODS = [  # file stem, route, short title, minutes
    ('Main', 'start', 'Course map', 0),
    ('M1-Beam', 'beam', 'The BEAM', 20),
    ('M2-Otp', 'otp', 'OTP', 20),
    ('M3-Gleam', 'gleam', 'Gleam', 15),
    ('M4-Principles', 'principles', 'How gleam-dream thinks', 20),
    ('M5-Atlas', 'atlas', 'The package atlas', 15),
    ('M6-Foundations', 'foundations', 'Foundations', 20),
    ('M7-Edges', 'outside-world', 'The outside world', 20),
    ('M8-Durable', 'durable-work', 'Work that outlives a request', 20),
    ('M9-Oversight', 'agents', 'Agents & people in the loop', 25),
    ('M10-Compose', 'compose', 'Composition studio', 25),
    ('M11-FieldGuide', 'field-guide', 'Field guide', 15),
]
ROUTE = {m[0]: m[1] for m in MODS}

TOURBAR = '''<sc-if value="{{T.@@.touring}}" hint-placeholder-val="{{true}}"><div class="tourbar" role="region" aria-label="Guided tour">
<div class="tb-top"><span class="tourn">{{T.@@.n}}/{{T.@@.total}}</span><p class="tourtext" aria-live="polite">{{T.@@.text}}</p>
<div class="tb-ctl">
<button type="button" class="tbi tb" onClick="{{T.@@.prev}}" disabled="{{T.@@.atStart}}" aria-label="Previous step"><svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M10 3 L5 8 L10 13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></svg></button>
<sc-if value="{{T.@@.canPlay}}"><button type="button" class="tbi tb" onClick="{{T.@@.toggle}}" aria-label="{{T.@@.playLabel}}"><sc-if value="{{T.@@.paused}}"><svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 1.5 L12.5 7 L3 12.5 Z" fill="currentColor"></path></svg></sc-if><sc-if value="{{T.@@.playing}}"><svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><rect x="2.5" y="1.5" width="3.2" height="11" rx="1" fill="currentColor"></rect><rect x="8.3" y="1.5" width="3.2" height="11" rx="1" fill="currentColor"></rect></svg></sc-if></button></sc-if>
<button type="button" class="tbn tb" onClick="{{T.@@.next}}">{{T.@@.nextLabel}}</button>
</div></div>
<div class="tb-foot"><div class="tdots" aria-hidden="true"><sc-for list="{{T.@@.dots}}" as="d"><span><i style="width:{{d.w}};animation:{{d.anim}}"></i></span></sc-for></div><button type="button" class="tblink tb" onClick="{{T.@@.skip}}">Skip tour · unlock controls</button></div>
</div></sc-if>
<sc-if value="{{T.@@.free}}"><div class="tourbar freebar row" style="gap:12px;justify-content:space-between"><span style="font-size:14px"><b>Free play.</b> Everything is unlocked: try your own experiments.</span><button type="button" class="btn sm tb" onClick="{{T.@@.replay}}">Replay the guided tour</button></div></sc-if>'''

def tourify(body):
    return re.sub(r'<div class="lab" data-tour="([A-Za-z0-9_]+)"([^>]*)>',
                  lambda m: '<div class="lab {{T.%s.cls}}" data-tid="%s"%s>' % (m.group(1), m.group(1), m.group(2)) + TOURBAR.replace('@@', m.group(1)), body)

MSCSVG = '''<div style="overflow-x:auto"><svg viewBox="0 0 {{N.w}} {{N.h}}" width="100%" style="min-width:540px;max-width:{{N.w}}px;display:block;margin:0 auto" role="img" aria-label="{{N.aria}}">
<defs>
<marker id="mk-{{N.id}}-ink" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#17162B"></path></marker>
<marker id="mk-{{N.id}}-red" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#B42318"></path></marker>
<marker id="mk-{{N.id}}-green" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#15803D"></path></marker>
<marker id="mk-{{N.id}}-pink" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#B0186E"></path></marker>
<marker id="mk-{{N.id}}-blue" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#1D4ED8"></path></marker>
<marker id="mk-{{N.id}}-amber" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#B45309"></path></marker>
<marker id="mk-{{N.id}}-grey" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#8A8698"></path></marker>
</defs>
<sc-for list="{{N.lanes}}" as="l"><rect x="{{l.bx}}" y="6" width="140" height="30" rx="8" fill="{{l.active}}"></rect><text x="{{l.x}}" y="26" text-anchor="middle" class="msc-h" style="fill:{{l.fg}}">{{l.label}}</text><line x1="{{l.x}}" y1="38" x2="{{l.x}}" y2="{{N.lineEnd}}" stroke="#D5D1C8" stroke-width="2" stroke-dasharray="4 5"></line></sc-for>
<sc-for list="{{N.arrows}}" as="a"><g opacity="{{a.op}}" class="{{a.cls}}"><path class="{{a.pc}}" pathLength="{{a.pl}}" d="{{a.d}}" stroke="{{a.color}}" stroke-width="{{a.sw}}" fill="none" stroke-dasharray="{{a.dash}}" marker-end="{{a.mark}}"></path><sc-if value="{{a.lost}}"><text x="{{a.cx}}" y="{{a.cy}}" fill="#B42318" style="font:700 18px Inter,sans-serif" dy="6">⚡</text></sc-if><text x="{{a.lx}}" y="{{a.ly}}" text-anchor="{{a.anchor}}" class="msc-l" fill="{{a.color}}">{{a.label}}</text><text x="{{a.nx}}" y="{{a.ny}}" class="msc-l" fill="#8A8698">{{a.num}}</text></g></sc-for>
</svg></div>'''

def mscify(body):
    return re.sub(r'<!--MSC:([A-Za-z0-9_]+)-->', lambda m: MSCSVG.replace('{{N.', '{{' + m.group(1) + '.'), body)

def fix_links(s):
    s = re.sub(r'(Main|M\d+-[A-Za-z]+)\.dc\.html', lambda m: '#' + ROUTE[m.group(1)], s)
    s = re.sub(r'href="(https?://[^"]+)"', r'href="\1" target="_blank" rel="noopener"', s)
    return s

def main_parts():
    src = (ROOT / 'project' / 'Main.dc.html').read_text()
    css = src.split('<style>')[1].split('</style>')[0]
    body = src.split('<div class="pg">', 1)[1].rsplit('</x-dc>', 1)[0]
    body = body.rsplit('</div>', 1)[0]  # drop .pg closer
    body = re.sub(r'<nav class="top".*?</nav>', '', body, flags=re.S)
    js = src.split('data-dc-script')[1].split('>', 1)[1].rsplit('</script>', 1)[0]
    # quiz-free copy edits
    rep = [
        ('<span><b style="color:#17162B">Checks included.</b> Each module ends with a short quiz.</span>', '<span><b style="color:#17162B">Progress saved.</b> Mark modules done as you go.</span>'),
        ('Read a little, play a lot, check, carry one idea forward', 'Read a little, play a lot, carry one idea forward'),
        ('<div class="card"><div class="chip" style="background:#FDF0DC;color:#8A3F06">3 · Check</div><h3 style="font-size:20px;margin:14px 0 6px">A short quiz</h3><p class="muted" style="margin:0;font-size:15px">Three scenario questions with an explanation for every answer.</p></div>',
         '<div class="card"><div class="chip" style="background:#FDF0DC;color:#8A3F06">3 · Tick off</div><h3 style="font-size:20px;margin:14px 0 6px">Mark it done</h3><p class="muted" style="margin:0;font-size:15px">When a module clicks, mark it done. Your progress stays in this browser.</p></div>'),
        ('<div class="card" style="padding:32px">', '<div class="lab" data-tour="stack" style="padding:32px;margin-top:0">'),
        ('<div class="chip" style="background:#DDF3F0;color:#0B5A54">4 · Carry</div>', '<div class="chip" style="background:#DDF3F0;color:#0B5A54">4 · Carry</div>'),
        ('<span class="mnum"><span>Module {{m.n}}</span><span>{{m.min}} min</span></span>', '<span class="mnum"><span>Module {{m.n}}</span><span>{{m.doneLabel}}{{m.min}} min</span></span>'),
    ]
    for a, c in rep:
        assert a in body or a in js, a[:60]
        body = body.replace(a, c)
    js = js.replace("M(11, 'Field guide & final check', 15, 'Retrace, tooling, a cheat sheet and the final quiz.', 'final quiz', 'M11-FieldGuide.dc.html')",
                    "M(11, 'Field guide', 15, 'Retrace, tooling, a glossary and a cheat sheet to keep.', 'session replay', 'M11-FieldGuide.dc.html')")
    js = js.replace("const M = (n, title, min, blurb, play, href) => ({ n, title, min, blurb, play, href });",
                    "const M = (n, title, min, blurb, play, href) => ({ n, title, min, blurb, play, href, doneLabel: GD.isDone(href) ? '\\u2713 done \\u00b7 ' : '' });")
    assert 'doneLabel' in js and "'Field guide'" in js
    return css, body, js

def module_parts(stem):
    body = (ROOT / 'src' / f'{stem}.html').read_text().replace('<!--QUIZ-->', '')
    js = (ROOT / 'src' / f'{stem}.js').read_text().replace('/*HELPERS*/', '')
    js, n = re.subn(r'\n    const qs = \[.*?\n    \];\n', '\n', js, flags=re.S)
    assert n == 1, (stem, n)
    js = js.replace('this.quizVals(qs)', '{}')
    if stem == 'M11-FieldGuide':
        body = body.replace('Field guide &amp; final check', 'Field guide')
        body = body.replace('Meet Retrace and the tooling around the libraries, look anything up in the glossary, take the final check, and leave with a reading plan for the repositories.',
                            'Meet Retrace and the tooling around the libraries, look anything up in the glossary, and leave with a cheat sheet and a reading plan for the repositories.')
        body = re.sub(r'<section class="wrap sec">\s*<div class="dark".*?</section>', '', body, flags=re.S)
        assert 'final check' not in body.lower(), 'final check left'
    return body, js

def build():
    mcss, mbody, mjs = main_parts()
    templates, classes, meta = [], [], []
    for i, (stem, route, title, mins) in enumerate(MODS):
        if stem == 'Main':
            body, js = mbody, mjs
        else:
            body, js = module_parts(stem)
        body, js = fix_links(mscify(tourify(body))), fix_links(js)
        xf = ROOT / 'src' / f'{stem}.x.js'
        if xf.exists():
            js = js.rstrip()
            assert js.endswith('}'), stem
            js = js[:-1] + '\n' + fix_links(xf.read_text()) + '\n}\n'
        cname = 'Mod' + str(i)
        js = js.replace('class Component extends DCLogic', f'class {cname} extends DCLogic', 1)
        assert f'class {cname}' in js
        templates.append(f'<template id="t-{route}">{body}</template>')
        classes.append(js + f'\nGD.register("{route}", {cname});\n')
        meta.append({'route': route, 'title': title, 'min': mins, 'n': i})
    extra_css = '\n'.join(l for l in mcss.splitlines() if re.match(r'\s*\.(layer|ln|lt|ls|mod|mnum|mt|btnl|dark)\b', l))
    html = (ROOT / 'tools' / 'shell.html').read_text()
    html = html.replace('/*CSS*/', b.CSS + '\n' + extra_css)
    html = html.replace('<!--TEMPLATES-->', '\n'.join(templates))
    html = html.replace('/*META*/', json.dumps(meta))
    html = html.replace('/*CLASSES*/', '\n'.join(classes))
    html = html.replace('FONTS_URL', b.FONTS)
    out = ROOT / 'site' / 'index.html'
    out.parent.mkdir(exist_ok=True)
    out.write_text(html)
    low = html.lower()
    print('wrote', out, len(html), 'quiz mentions:', low.count('quiz'), 'dc.html refs:', html.count('.dc.html'))

if __name__ == '__main__':
    build()
