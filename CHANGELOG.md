# SentinelReady — Release Notes

What changed in each release, and whether you need to do anything about it.
Upgrade with `docker compose pull && docker compose up -d`.

---

## 1.0.10 — 2026-09-18

**Recommended for everyone.** SentinelReady now judges an alert's number
against what it has actually seen from that alert before, instead of against
nothing.

### What changed

Deciding whether an alert can wait means deciding whether its number is
unusual. Until now SentinelReady asked the model to work that out on its own,
and a small local model cannot — reliably, and in a way that is easy to
reproduce. Given "this metric has run 610 to 720 seconds" and a reading of 38
seconds, it answered *"within the recorded range."* Given a solar inverter
rated 210–260 kW and a reading of 3 kW, it answered *"not close to any limit."*

So SentinelReady now does that comparison itself, and tells the model what it
found in plain language:

> Across 26 occurrences this pattern has never been recorded below 210 kW.
> It is now 3 kW — 70x below that floor.

The model still makes the call about whether that deserves interrupting you.
It is simply no longer asked to do arithmetic it is bad at.

On our test set of twelve invented alerts — deliberately not Kubernetes ones,
with units from cold chain, payroll, courier and claims systems — this took the
default model from 3 of 12 correct to 12 of 12, reproduced exactly. Half those
cases are alerts where the dangerous reading is unusually **low**, which is the
case SentinelReady previously got wrong almost every time.

### What you need to do

Nothing. It is on by default and needs no configuration.

### What to expect on day one

**Nothing changes immediately, and that is expected.** SentinelReady has never
recorded the value an alert fired at, so after upgrading it starts learning
from zero — even for a pattern it has seen four hundred times. It needs about
five occurrences of a given alert before it will describe a range as a range.

Frequently-firing alerts cross that in a day. A monthly one takes a month.
Until then SentinelReady says so honestly rather than guessing: an alert it
cannot judge goes to your sitrep, where nothing is lost, and sacred severities
page immediately regardless, exactly as before.

This is the shape of the product: **every alert carrying a measurement makes
the next judgement of that pattern better.**

### Related alerts no longer page you about the wrong machine

SentinelReady groups alerts that fire close together and tries to explain them
as one incident. It was saying they were related **every single time** — 24 out
of 24 on our own instance, across three days, never once declining. Alerts that
shared nothing were being welded together.

The result reached real pages. A volume at 2.0% full — correctly judged as
something that could wait — was combined with an unrelated CPU alert on a
different machine and delivered as *"potential resource exhaustion on
k8s-node"*. Wrong machine, wrong urgency, and the volume's own 2.0% appeared
nowhere in the message. Others asserted one alert was *"causing write failures
and increased CPU usage"* on another, a connection nothing in the data
supported.

Three changes:

- **Grouping no longer changes urgency.** Whether an alert interrupts you is
  decided by triage, on that alert's own evidence. Correlation still tells you
  what else fired at the same time — it just cannot turn something that could
  wait into a 3am page, or quiet something that shouldn't wait.
- **No invented causes.** Correlation describes what fired together. It no
  longer asserts that one thing caused another.
- **Every alert leads with what fired and what it read.** `HIGH: VolumeUsage =
  2.0%` comes first, then any explanation. The name and the number come
  straight from your monitoring; the explanation is the AI's account of it, and
  it belongs after the facts.

**This affects 1.0.9 and earlier.** If you have received a page whose headline
described a system other than the one that alerted, this is why.

### Also in this release

- **`ai.timeout_seconds`** — how long one AI call may take before the alert is
  delivered untriaged. Defaults to 300, unchanged. Worth lowering on fast
  hardware, raising on slow. Fail-open is unchanged at any value: an alert that
  outruns the budget is still delivered, marked "AI too slow, not triaged".

- **Configuration files now merge properly.** Settings nested two levels deep
  used to replace their whole parent section. Setting one value under
  `resilience.breakers` removed the other circuit breakers — including the one
  that protects SentinelReady during a database problem. Nothing failed
  visibly; the protection was simply gone. If you have ever edited a nested
  setting, this release restores the defaults you did not set.

  Email delivery was not affected: those settings were re-applied further
  downstream, so a partial `delivery.smtp` block always worked.

---

## 1.0.9 — 2026-09-16

**Recommended for everyone, and urgent if you receive alerts by email without
an outbound webhook configured.**

### Alerts graded "interrupt me now" were not being delivered

In 1.0.8 and earlier, an alert that triage decided should interrupt you
immediately was routed to a delivery channel that had never been implemented.
It was a log line and a `TODO`. The decision was made correctly, recorded
correctly, and counted in `/metrics` as an escalation — and then nothing was
sent.

Verified against the published 1.0.8 image: six alerts produced twelve
escalations in `/metrics` and **zero delivery attempts**.

**Who this affected.** If your alert delivery is email only, with no outbound
webhook, you did not receive these. Only alerts carrying a sacred severity
(`critical` by default, which page unconditionally and never depend on triage)
reached you. If you have Slack or PagerDuty configured, you were not affected —
those channels worked.

This predates 1.0.8. We found it while auditing what the escalation counters
actually counted, and it is fixed in this release: a page now means a delivery
was attempted, not that a decision was made. The counter counts deliveries too,
which is why your escalation numbers may read lower after upgrading — the old
number included decisions that never reached anyone.

Also fixed alongside it: three verdicts described themselves as "notify only"
while delivering nothing, and the word "paged" was used to describe an
intention rather than an event. Both now say what actually happens.

### The default AI model has changed

**If you have `model:` set in your `sentinelready.yaml` you need to change it
yourself to get the fix.**

```yaml
ai:
  model: mistral:7b-instruct-v0.3-q4_K_M
```

### Why

SentinelReady's job is deciding which alerts can wait. It was getting that
decision wrong, and the reason turned out to be the default model: **llama3.1
does not read the number in your alert.**

Tested on six controlled cases — the same alert at disk usages from 2% to
99.4% — llama3.1 answered "interrupt someone immediately" to **all six**. At
12% full it explained itself as *"disk usage is critically high, above 90%"*,
a figure that appears nowhere in the alert. It was pattern-matching on the
words "disk" and "full" and never reading the value.

That is why triage escalated nearly everything. It was not tuning, and it was
not your alert rules.

`mistral` got all six right, twice, reproducibly. It is smaller (4.4GB vs
~5GB), so the memory requirement goes **down**, and it is Apache 2.0 licensed.

Also evaluated and rejected: qwen2.5:14b (graded well but timed out writing
summaries), qwen2.5:7b, granite3-dense:8b, phi4-mini, phi3:medium, gemma3:12b,
llama3.2:3b. Only mistral scored full marks.

### What you need to do

**If you never set `ai.model`** — nothing. You get the new default on upgrade,
and Ollama downloads it on first start (~4.4GB, a few minutes).

**If you set `ai.model: llama3.1`** — your setting wins over our default, so
you will keep the old behaviour until you change it. Edit
`sentinelready.yaml`, set the model as above, and restart.

**If you use a hosted provider** (Claude, OpenAI) — nothing changes. This only
affects local Ollama models.

### Honest note

The model is pinned to an exact build rather than the moving `mistral` tag.
Which model you run determines whether triage works at all, so it should not
be able to change under you without a release saying so.

We also reduced what the model is asked to do in one go. The routing decision
— when you need to see this — is now asked on its own, before any summary is
written, and summaries are only written for alerts that are actually
interrupting you. That is fewer AI calls, not more.

---

## 1.0.8 — 2026-09-07

**Recommended for everyone.** SentinelReady can now find and repair bad
entries in its own pattern library, and it tells you when it does.

- **Self-repair.** SentinelReady learns a verdict for each alert pattern and
  reuses it, which is what makes repeat alerts instant and free. Occasionally a
  stored verdict goes bad — and a bad verdict never fixes itself, because it is
  either never reused (so never re-examined) or always reused (so never
  re-examined). It now checks daily at 03:00 and repairs what it finds.

  You can also look yourself, any time, the same way you run `--doctor`:

  ```bash
  docker compose exec sentinelready ./nuitka_launcher.bin --cure
  ```

  That shows what is wrong and changes nothing. Add `--clean` to repair it.
  See the README section "Pattern Library Health" for what each condition
  means.

- **Repairs are never silent.** Every repair appears in your next sitrep,
  naming the pattern and what was wrong with it. SentinelReady does not change
  its own learning without telling you.

- **Your history is kept.** The pattern, how many times it has fired, when it
  was first and last seen, and every recorded outcome are untouched. Only the
  bad verdict goes — and with it the confidence score, because that score was
  earned by agreeing with the verdict being discarded. The pattern re-earns
  confidence over its next few occurrences, which is the honest position rather
  than inheriting certainty from an answer that turned out to be wrong.

- **A pattern that resolved is no longer overwritten.** When an alert resolved,
  SentinelReady could replace whatever that pattern had learned with a generic
  "escalate" verdict. That is fixed. If you have been seeing patterns drift
  toward escalating when they used to be handled quietly, this is why.

- Change the schedule, or turn it off, in `sentinelready.yaml`:

  ```yaml
  maintenance:
    poison_check_hour: 3    # or null to disable
  ```

**Nothing to do beyond upgrading.** The first scheduled check will report what
it found in your next sitrep. If you would rather look before it runs, use
`--cure` — it changes nothing.

---

## 1.0.7 — 2026-09-04

**Recommended for everyone, and important if you run a local model on CPU.**

- **SentinelReady no longer re-analyses alerts it already recognises.** A
  pattern it had seen over a thousand times, holding a perfectly good stored
  verdict, was still being sent to the AI on every single occurrence — because
  the check asked "am I confident in this verdict?" when it should have been
  asking "do I recognise this alert?". A pattern past 25 occurrences now
  answers from memory unless something about it has changed.

  On a local CPU model this was doing real damage. Analysis takes minutes, and
  alerts were arriving faster than they could be processed, so the model
  saturated and calls began timing out — at which point alerts were delivered
  with no triage at all. Nothing was lost (SentinelReady always delivers), but
  the triage you were paying for wasn't happening. In our own environment this
  change cut AI calls by roughly two thirds and took untriaged alerts from 50%
  to under 8%.

  **Change still gets a fresh look.** If a pattern starts firing far more than
  usual, the stored verdict is not reused — that is exactly when re-analysis is
  worth the cost.

- **Reused verdicts say so.** When an answer comes from memory rather than
  fresh analysis, the alert carries a line telling you: how many times the
  pattern has fired, the confidence, and that the AI was not consulted. You
  should always be able to tell what you are looking at.

- **Background work can no longer starve live alerts.** Generating the sitrep's
  recommendations shares the same AI as real-time triage, and on a single local
  model everything queues. That work is now time-limited and falls back to
  simpler recommendations rather than holding up alerts behind it.

- **"AI calls avoided" is now "Answered from memory", and the number was
  wrong.** It counted only one of the two ways SentinelReady reuses an answer,
  so it under-reported what you were actually saving — by about 10x in our
  measurements. If the figure jumps after upgrading, nothing changed in
  behaviour; it is now counting correctly.

- **Fixed:** a burst-detection rule that had never worked, because it read a
  field that alerts do not carry.

## 1.0.6 — 2026-09-03

**Recommended for everyone. Improves what SentinelReady tells you, and stops
it telling you things it could not actually know.**

- **Sitrep recommendations now come from the AI, on your measured data.**
  "Patterns Worth Fixing" used to be produced by fixed thresholds written into
  the code — they could only recognise situations we had thought of in
  advance. The AI now receives the real figures for each pattern (how often it
  fires, how long it takes to clear, how many times it was escalated, how long
  it has been known, its severity and blast radius) and decides what deserves
  engineering effort. It is also told what the data cannot tell it, so it does
  not reason past the evidence.

  Practically: a pattern that fires rarely but takes hours to clear can now be
  ranked above one that fires constantly and clears in seconds. No threshold
  could express that. And a pattern that has fired hundreds of times unchanged
  is treated as an unaddressed condition weighed against what it would affect,
  rather than as noise because it repeats.

- **Removed a claim we could not support.** Earlier sitreps said things like
  "self-resolves 100% of the time — consider suppressing permanently". That
  percentage was not measured. SentinelReady knows when an alert *cleared*,
  because your alerting system tells it — but an alert an engineer fixed and
  one that cleared by itself look identical from outside. It should never have
  reported the second as if it knew. It no longer claims a self-resolve rate,
  and no longer recommends silencing anything on that basis. The section now
  says where your volume is and suggests re-evaluating it, which is what the
  data actually supports.

  The same claim was being passed into the AI's own prompt, describing patterns
  as "known noise in this environment". That is removed too: the AI now judges
  from figures, not from a conclusion we handed it.

- **Triage no longer invents probable causes.** The AI had three slots for
  probable causes and no way to decline, so it filled them with plausible-
  sounding generalities when the alert supported none. It may now return a
  single cause, or say the alert lacks the signal to name one, and say what it
  would need instead.

- **Blast radius no longer names the monitoring endpoint.** For metric-derived
  alerts the AI sometimes reported the scrape target (e.g. a kubelet address)
  as the affected service — that is where the measurement came from, not what
  breaks.

- **Cosmetic:** numbers in AI prose round to one decimal place, and time
  estimates carry a unit.

**If you are on 1.0.5 or earlier with `outcome_learning: true` (the shipped
default in `sentinelready.yaml.example`), please upgrade.** In those versions
SentinelReady could promote a pattern to `suppress` on its own, using how
often alerts appeared to resolve themselves — a figure it was not actually
measuring. It never dropped an alert, and a suppressed pattern still appears
in your sitrep, but it could have stopped paging you for something that
warranted it. Upgrading disables that path. Any pattern already changed this
way corrects itself the next time it fires and is re-triaged; you can also
force it immediately with `POST /patterns/invalidate`.

**Note on model choice.** Two of these improvements are instructions to the AI,
and how well they are followed depends on the model. A small local model may
still produce a vaguer answer than the instruction asks for. If triage quality
matters to you, a larger local model or a hosted provider (`ai.provider:
claude` or `openai_compatible`) will follow them more closely.

## 1.0.5 — 2026-09-02

**Upgrade if you are on a paid plan.**

- **Fixed: a false "license renewal has not landed" warning.** Every sitrep
  and the dashboard warned that check-ins were not reaching the licensing
  service, on instances where they were working perfectly. Subscription
  entitlements are short-lived and refresh automatically, so the old check —
  "expires within 7 days" — was true from the moment a licence was issued.
  It now warns only when a refresh has genuinely not succeeded for 24 hours.
  If you saw this warning, nothing was ever wrong with your licence.

- **Fixed: repeat alerts were re-analysed instead of served from the pattern
  library.** The AI was being asked whether an alert "requires review" without
  being told what the question meant, and reasonably answered "yes, a human
  should look at this incident" — which the library treated as "never reuse
  this verdict". Recognised patterns now serve from the library as intended.
  Existing patterns correct themselves the next time they fire; nothing to do.

- **Fixed:** the sitrep preview endpoint built a report for the wrong customer
  code when called without one, showing zero alerts on a busy instance.

## 1.0.4 — 2026-09-02

**Upgrade immediately if you are on a paid plan. 1.0.3 cannot activate a
licence at all.**

- **Fixed: a paid licence could not activate.** On startup with a licence key
  present, the container failed and restarted in a loop, never reaching Pro.
  Community installs were unaffected — the fault was on the licence path only.

## 1.0.3 — 2026-09-01

- Burst handling reworked. A pattern firing far above its usual rate no longer
  discards what has been learned about it and re-analyses from scratch. The
  protection is unchanged: an alert that would normally be suppressed is
  surfaced in the digest while it is bursting, so a known-noisy pattern firing
  abnormally never goes silent.
- Run against a hosted AI provider without a local model: see
  `docker-compose.no-ollama.yml`.
- Pointing at an existing Ollama on your network now actually works — the
  override set a variable the application did not read.

## 1.0.2 — 2026-08-31

- Reliability fixes to log collection and AI provider handling.

---

Full source and issues: https://github.com/sentinelready/sentinelready-docker
