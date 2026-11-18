import asyncio, pathlib
import os
# The built site; SITE points the check at another build or an HTTP URL.
SITE = os.environ.get('SITE') or (pathlib.Path(__file__).resolve().parent.parent / 'dist' / 'index.html').as_uri()
OUT = pathlib.Path(__file__).resolve().parent / 'out'
OUT.mkdir(exist_ok=True)
import sys
from playwright.async_api import async_playwright
ROUTES = sys.argv[1].split(',')
SHOT = sys.argv[2] if len(sys.argv) > 2 else None
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(); errs = []
        pg = await b.new_page(viewport={'width': 1280, 'height': 900})
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.on('console', lambda m: errs.append('console: ' + m.text) if m.type == 'error' else None)
        await pg.goto(SITE); await pg.wait_for_timeout(300)
        for r in ROUTES:
            await pg.evaluate(f"location.hash='{r}'"); await pg.wait_for_timeout(300)
            tours = await pg.locator('#view .tourbar:not(.freebar)').count()
            clicks = 0
            for _ in range(80):
                btn = pg.locator('#view .tourbar:not(.freebar) .tbn').first
                if await btn.count() == 0: break
                await btn.click(); clicks += 1; await pg.wait_for_timeout(120)
            free = await pg.locator('#view .freebar').count()
            # free play: click unlocked buttons
            btns = await pg.locator('#view .lab button').count(); ok = 0
            for i in range(min(btns, 60)):
                el = pg.locator('#view .lab button').nth(i)
                try:
                    if await el.is_visible() and await el.is_enabled(): await el.click(timeout=400); ok += 1
                except Exception: pass
            await pg.wait_for_timeout(300)
            holes = await pg.evaluate("(document.getElementById('view').innerHTML.match(/\\{\\{/g)||[]).length")
            print(f'{r:14} tours={tours} tourClicks={clicks} free={free} freeClicks={ok} holes={holes} errs={len(errs)}')
        if SHOT:
            await pg.evaluate(f"location.hash='{ROUTES[0]}'"); await pg.wait_for_timeout(300)
            for sel in SHOT.split('|'):
                loc = pg.locator(sel).first
                await loc.scroll_into_view_if_needed(); await pg.wait_for_timeout(400)
                await loc.screenshot(path=str(OUT / ('shot_' + str(abs(hash(sel)) % 1000) + '.png')))
                print('shot', sel, 'shot_' + str(abs(hash(sel)) % 1000) + '.png')
        for e in errs[:8]: print('ERR', e[:300])
        await b.close()
asyncio.run(main())
