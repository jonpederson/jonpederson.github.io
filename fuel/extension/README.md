# Wisconsin Fuel Agent — Data Capture (Chrome extension)

Companion extension for the [Wisconsin Fuel Buy/Wait report](https://jonpederson.github.io/fuel/). It watches the pages you already have to visit for that report — MarketWatch futures quotes, EIA inventory pages, AAA state gas prices, GasBuddy city pages — captures the numbers it finds, and autofills the report form for you.

## Design: review before fill, always

This extension never writes a scraped number straight into the report. Every capture lands in a **Needs review** queue in the popup first, showing the exact page it came from and the raw text it matched. You accept, edit, or reject each one. Only accepted values feed the autofill and the running price history — a wrong silent guess in a financial decision tool is worse than no data at all, so nothing is trusted sight unseen. Values well outside a sane range for that field (e.g. a "$31.90" scraped as a retail gas price) are flagged as suspect in the queue rather than dropped or auto-accepted.

It also can't and doesn't try to auto-fill the judgment calls the report's own methodology deliberately leaves to a human: whether a retail move is "broad" (several stations/a chain, not one outlier), the catch-up/cycle-position calls, refinery & pipeline news credibility, the crack-spread read, or seasonal context. Those fields stay exactly as manual as they are today.

## What it captures

| Source | Field(s) |
|---|---|
| MarketWatch RBOB futures quote (`RB.1`) | RBOB current price |
| MarketWatch ULSD futures quote (`HO.1`) | ULSD current price |
| MarketWatch Brent / WTI crude quotes | Brent, WTI current price |
| EIA weekly PADD 2 stocks pages | PADD 2 gasoline stock, PADD 2 distillate stock |
| AAA state gas price pages (`?state=WI` / `?state=MN`) | WI avg regular/diesel, "Twin Cities" proxy regular/diesel |
| GasBuddy city price pages (New Auburn, Chippewa Falls, Eau Claire, Minneapolis, St. Paul) | median of visible station prices for that city |

Every accepted value is stored with the date it was captured (America/Chicago). Once you've captured the same source across a few different days, the extension automatically computes the report's 24h / ~3-session / ~5-session change fields from that history — no more doing the subtraction by hand. It also suggests the RBOB/ULSD momentum ("accelerating") select from three consecutive daily changes, and derives the Twin Cities restoration/decline and Eau Claire catch-up magnitude fields the same way. All of these are clearly re-editable on the report page after filling.

## Install (unpacked, for now)

This isn't published to the Chrome Web Store — load it as an unpacked extension:

1. Open `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and select this `fuel/extension` folder.
4. Pin the extension (puzzle-piece icon in the toolbar → pin) so the popup is one click away.

## Using it

1. Click through the **Open a source** links in the popup (or just browse to MarketWatch/EIA/AAA/GasBuddy as usual) — each matching page gets scanned automatically after it loads.
2. Open the popup. Review anything in **Needs review**: accept, edit, or reject each candidate.
3. Repeat daily (or whenever you're pulling a fresh report) to build up the multi-day history the delta calculations need — the first day or two, 24h/3-session/5-session fields will show "need more days" until there's enough history.
4. Click **Autofill Wisconsin Fuel Report**. It opens (or switches to) the report tab and fills every numeric field it has confirmed data for; filled fields are outlined briefly and their section auto-expands so you can see what changed.
5. Finish the report as usual — confirm the "broad move" checkboxes, catch-up/cycle-position selects, refinery/pipeline news, and seasonal context, then generate the report.

## If a site stops matching

These are HTML scrapers against public pages the extension doesn't control, so a redesign on MarketWatch/EIA/AAA/GasBuddy's end can break extraction for that source. When that happens the popup's **Needs review** list just won't get a new candidate from that source (or you'll see a "couldn't auto-read" note) — nothing breaks silently, you just fall back to typing that one field in by hand on the report page like before. The extraction logic for each source lives in `content-capture.js`, one function per site, if you want to patch a broken selector.

## Data & privacy

Everything is stored locally in the extension's `chrome.storage.local` — nothing is sent to any server other than the pages you already chose to visit. **Clear all captured data** in the popup wipes it.
