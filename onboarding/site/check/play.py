import asyncio, pathlib
import os
# The built site; SITE points the check at another build or an HTTP URL.
SITE = os.environ.get('SITE') or (pathlib.Path(__file__).resolve().parent.parent / 'dist' / 'index.html').as_uri()
OUT = pathlib.Path(__file__).resolve().parent / 'out'
OUT.mkdir(exist_ok=True)
import sys
from playwright.async_api import async_playwright
route, idx, wait, out, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(); pg = await b.new_page(viewport={'width':w,'height':h}); errs=[]
        pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto(SITE + '#' + route); await pg.wait_for_timeout(500)
        lab = pg.locator('#view .lab').nth(idx)
        await lab.locator('.tbi').nth(1).click()   # play
        await pg.wait_for_timeout(wait)
        await pg.screenshot(path=str(OUT / out))
        print('errs', errs); await b.close()
asyncio.run(main())
