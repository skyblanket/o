# O visual feedback widget

A Vorflux-style, drop-in annotation layer for your dev app. Hover any element,
click it, type what should change, batch a few, and **Send to O** — the O daemon
files a single `origin='feedback'` issue that the autonomous loop picks up like
any other work item.

Zero dependencies, no build step, one file: [`o-feedback.js`](./o-feedback.js).
The only network request it ever makes is the one POST to your configured O
endpoint.

---

## Embed it (simplest path)

Copy the script tag into your dev app's `index.html` (or any page you want to
annotate). Point it at your running O daemon and the company that owns the repo:

```html
<script
  src="/o-feedback.js"
  data-endpoint="http://127.0.0.1:4100"
  data-company="co_XXXXXXXX"></script>
```

Serve `o-feedback.js` from wherever your app already serves static assets
(copy the file into `public/`, or reference it from any URL you host). The O
daemon itself serves **JSON only** — it does not host this script.

Alternatively configure via a global before the script loads:

```html
<script>
  window.O_FEEDBACK = { endpoint: "http://127.0.0.1:4100", company: "co_XXXXXXXX" };
</script>
<script src="/o-feedback.js"></script>
```

`window.O_FEEDBACK` wins over the `data-*` attributes.

## Use it

- **Alt+Shift+A** toggles annotate mode (or call `window.OFeedback.toggle()`).
- In annotate mode a highlight tracks the hovered element. **Click** to capture
  it; a small input opens — type the instruction and press **Enter**.
- **Esc** exits annotate mode.
- The panel (bottom-right) shows the batch. Remove individual items, **Clear**
  the batch, or **Send to O**. On success it shows the created issue identifier
  and clears the batch.

`window.OFeedback` also exposes `open()`, `close()`, `clear()`, `batch()`, and
`config()` for programmatic control.

## Bookmarklet (no edit to the app)

If you can't add a script tag, host `o-feedback.js` somewhere reachable and set
its config, then inject it on demand. Replace the URL/company with yours:

```
javascript:(function(){window.O_FEEDBACK={endpoint:'http://127.0.0.1:4100',company:'co_XXXXXXXX'};var s=document.createElement('script');s.src='https://YOUR-HOST/o-feedback.js';document.body.appendChild(s);})();
```

Save that as a bookmark; click it on any page to load the widget. (The O daemon
serves JSON only, so the script must come from a URL you host — your app's
static dir, a gist raw URL, an S3 bucket, etc.)

---

## Endpoint contract

`POST {endpoint}/api/companies/{company}/feedback`

Request body:

```json
{
  "page_url": "http://localhost:3000/dashboard",
  "title": "optional — defaults to 'Feedback: N annotation(s) on {page_url}'",
  "annotations": [
    {
      "selector": "#hero > h1.title",
      "html": "<h1 class=\"title\">Welcome</h1>",
      "styles": { "color": "rgb(0,0,0)", "font-size": "32px", "font-weight": "700" },
      "instruction": "make the heading bigger and use the brand purple"
    }
  ]
}
```

- `page_url` — **required**. `400` if missing.
- `annotations` — **required**, non-empty array. `400` if missing/empty.
- `title` — optional; a sensible default is composed and truncated.
- Each annotation's `html` is truncated to ~2000 chars server-side.

Response `201` — the created issue row (JSON), including `id`, `identifier`,
`origin: "feedback"`, and the composed markdown `body` (one `### Annotation N`
section per annotation). The issue is filed **outside** the loop's auto/reflect
self-file daily cap, so operator feedback is never silently dropped.

`404` if the company does not exist. `400` on a malformed body.

---

## Follow-up: a proper Chrome extension

This widget is the fast, embeddable proof. The natural next step is a Chrome
extension wrapping this **same** endpoint: it can inject on any origin without a
script tag, add **cropped element screenshots** to each annotation (via
`chrome.tabs.captureVisibleTab` + canvas crop to the element's bounding box),
and attach them to the issue body / an asset store. The intake contract above
stays identical — the extension just enriches the payload.
