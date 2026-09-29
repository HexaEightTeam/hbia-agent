# API adapters — offer any API to other agents, by name

Three small, standalone programs, each putting a public API (free, no key) behind a HexaEight agent.
Copy one as the pattern for your own API.

| Folder | Language | Upstream | Port | Try |
|---|---|---|---|---|
| [`weather/`](weather/weather-service.py) | Python, standard library only | Open-Meteo | 38492 | "weather in London tomorrow" |
| [`bbc-news/`](bbc-news/bbc-news-service.py) | Python, standard library only | BBC RSS feeds | 38491 | "technology", "Ukraine" |
| [`wikipedia/`](wikipedia/wikipedia-service.mjs) | Node 18+, no packages | Wikipedia | 38493 | "Airbus", "zero trust security" |

## Why an adapter, and not the API itself

A calling agent does not talk to an API's own format. It searches a **memory**, and the memory expects
answers in one shape — the **heia-service/1** contract:

```
GET  /health                         is anything there
GET  /<name>/describe  (or /heia/describe)
                                     what this is, WRITTEN FOR THE MODEL: when to use it, what it returns,
                                     what it cannot do. {"contract":"heia-service/1","name","description","docs":1,"ops":[…]}
POST /heia/search                    {"query": "…", "topK": n, "name": "<name>"}
                                  -> {"contract":"heia-service/1","op":"search","status":"ok",
                                      "results":[{"score","document","source","text"}, …]}
```

One result row per thing worth citing: `document` is its title, `source` its link, `text` the content.
A failed lookup is still an ANSWER (`"status":"error","error":"…"` with HTTP 200) so the model can act on it.

The adapter is where that translation happens — and where the description lives, which is what decides
whether a model uses the service at all. It binds **loopback only**: it is reached through the agent, so
every caller is authenticated and the agent's policy applies.

## The three steps

**1. Run the adapter** on the machine of the agent that will offer it:

    python3 weather/weather-service.py              # or: node wikipedia/wikipedia-service.mjs

**2. Publish it on that agent** (from its folder). This probes `/health` and the description, seals the
route, and turns the agent's API layer on; the agent then registers its **API door** in the registry,
separately from its normal door:

    cd ~/heia-agent && hexaeight-activate add-api --name weather --port 38492
    heia restart

**3. Use it from any other agent** — workspace → **Memory → External service**:

| Field | Value |
|---|---|
| agent that serves it | the publishing agent's name |
| service name on that agent | `weather` |

The form makes a real call before it saves anything. From then on, that agent's chats simply search the
`weather` memory. Who may call it is the publishing agent's policy (both directions, both agents):

    hexaeight-activate add-policy --principal <caller>                                    # on the publisher
    hexaeight-activate add-policy --principal '*' --object <publisher> --direction outbound   # on the caller

An API call is answered by the adapter directly — **no model runs on the publishing agent**, so offering
an API costs its owner no tokens.

## Writing your own

Keep the three routes and the result shape; change what happens inside the search. Write the description
for the model: say what it answers, how to phrase a query, and — just as important — what it cannot do.
