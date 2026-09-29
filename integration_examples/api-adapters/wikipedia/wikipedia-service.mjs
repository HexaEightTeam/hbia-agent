#!/usr/bin/env node
// A HexaEight external service for WIKIPEDIA, fronting the public Wikipedia APIs (free, no key).
//
// An adapter, not a proxy: Wikipedia answers in its own shape; an agent's memory search expects the
// heia-service/1 shape. This program takes the question, searches Wikipedia, reads the best pages'
// summaries and answers in the contract. Copy it as the pattern for any API you want your agent to offer.
//
// THE CONTRACT — heia-service/1:
//
//     GET  /health                            liveness
//     GET  /wikipedia/describe?name=<n>       what this is, written FOR THE MODEL   (also /heia/describe)
//     POST /heia/search                       {"query": "<topic>", "topK": n, "name": "<remote>"}
//                                          -> {"contract","op","status":"ok","results":[…]}
//
// ONE RESULT ROW PER ARTICLE: its title, its link (cite it) and its summary.
//
// Run:      node wikipedia-service.mjs             (listens on 127.0.0.1:38493)
// Publish:  cd <agent folder> && hexaeight-activate add-api --name wikipedia --port 38493
// Node 18+, no packages. Binds loopback only: reached through the agent, so the caller is authenticated
// and the agent's policy applies. Wikipedia text is CC BY-SA — the link in each row is the attribution.
import http from 'node:http';

const CONTRACT = 'heia-service/1';
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const PORT = Number(opt('--port', 38493));
const NAME = opt('--name', 'wikipedia');
// Wikipedia asks every client to identify itself; an anonymous one is throttled or refused.
const UA = { 'User-Agent': 'HexaEight-wikipedia-example/1 (https://github.com/HexaEightTeam/hbia-agent)' };

const describe = (name) => ({
  contract: CONTRACT,
  name: name || NAME,
  description:
    'ENCYCLOPEDIA LOOKUP from English Wikipedia. Search with a topic, a name or a short question ' +
    "('Airbus', 'who founded Airbus', 'zero trust security'). Returns the best-matching articles, one row " +
    'each: the title, the link, and the article\'s summary (its first paragraph). CITE THE LINK. ' +
    'It is summaries, not full articles, and it is general knowledge — not news and not anything private.',
  docs: 1,   // a live service has no corpus, but the registration probe reads docs<=0 as "nothing here"
  ops: [{ op: 'search', kind: 'read',
          args: { query: "string: a topic or question, e.g. 'Airbus'", topK: 'int: articles (default 3)' } }],
});

async function getJson(url) {
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(20000) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

// (rows, error) — never throws.
async function wikipedia(query, limit) {
  const q = String(query || '').trim();
  if (!q) return [null, 'give a topic, a name or a question'];
  let titles;
  try {
    const s = await getJson('https://en.wikipedia.org/w/api.php?' + new URLSearchParams({
      action: 'query', list: 'search', srsearch: q, srlimit: String(Math.max(1, limit)), format: 'json', origin: '*',
    }));
    titles = (s.query?.search || []).map((h) => h.title);
  } catch (e) { return [null, `could not search Wikipedia: ${e.message}`]; }
  if (!titles.length) return [null, `Wikipedia has no article matching '${q}'`];

  const rows = [];
  for (const [i, t] of titles.entries()) {
    try {
      const p = await getJson('https://en.wikipedia.org/api/rest_v1/page/summary/' + encodeURIComponent(t.replace(/ /g, '_')));
      rows.push({
        score: Math.round((1 - i * 0.1) * 100) / 100,
        document: p.title || t,
        source: p.content_urls?.desktop?.page || `https://en.wikipedia.org/wiki/${encodeURIComponent(t)}`,
        text: (p.extract || '(no summary)') + (p.description ? `  [${p.description}]` : ''),
      });
    } catch { /* one missing summary is not a failed search */ }
  }
  return rows.length ? [rows, null] : [null, 'the matching articles could not be read'];
}

const send = (res, code, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
};

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'GET' && u.pathname === '/health')
    return send(res, 200, { contract: CONTRACT, status: 'ok', name: NAME, upstream: 'en.wikipedia.org', search: '/heia/search' });
  if (req.method === 'GET' && ['/wikipedia/describe', '/heia/describe'].includes(u.pathname))
    return send(res, 200, describe(u.searchParams.get('name') || ''));
  if (req.method === 'POST' && ['/wikipedia/search', '/heia/search'].includes(u.pathname)) {
    let raw = '';
    for await (const c of req) raw += c;
    let body;
    try { body = raw ? JSON.parse(raw) : {}; }
    catch (e) { return send(res, 400, { contract: CONTRACT, op: 'search', status: 'error', error: `bad JSON: ${e.message}` }); }
    const [rows, err] = await wikipedia(body.query, Number(body.topK) || 3);
    // An ANSWER, not a transport failure: status 200 with the reason, so the model can act on it.
    if (err) return send(res, 200, { contract: CONTRACT, op: 'search', status: 'error', error: err });
    return send(res, 200, { contract: CONTRACT, op: 'search', status: 'ok', results: rows });
  }
  send(res, 404, { contract: CONTRACT, status: 'error', error: 'GET /health, GET /wikipedia/describe, POST /heia/search' });
}).listen(PORT, '127.0.0.1', () => {
  console.log(`wikipedia-service: listening on http://127.0.0.1:${PORT}  (loopback only)`);
  console.log('  routes: GET /health, GET /wikipedia/describe, POST /heia/search');
});
