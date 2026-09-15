# Seal — Trust & Proof-of-Humanity Design

*How the in-person social graph becomes a score, a set of claims, and the access-control engine for the Square. Companion to [VISION.md](VISION.md), [SRS.md](../SRS.md), and [SDS.md](../SDS.md). The crypto that makes edges unforgeable lives in SDS; this doc is about what we **compute on top of** those edges.*

**Status:** design — not yet implemented. **Core decisions D1–D5 locked 2026-06-13** (see §7). Remaining tuning marked **[OPEN]**.

---

## 1. The invariant this protects

One rule governs every mechanic below:

> **Reach requires real human edges.** Nothing — posting, discovery, status — can be earned except through in-person ceremonies with distinct humans. Every feature must preserve this or it doesn't ship.

The graph is the product. The score is just a way to read it.

---

## 2. What we are actually proving

"Proof of humanity" is three different claims that get mashed together. They need different machinery and Seal is good at exactly one of them:

| Claim | Question | Can the graph prove it? |
|---|---|---|
| **Liveness** | Is there a human at all? | Weakly. One person with two keys can tap themselves and forge a single edge. A lone edge proves almost nothing. |
| **Distinctness (Sybil-resistance)** | Are you a *different* human from these other accounts? | **Yes — this is our wedge.** One person can mint many keys but cannot manufacture many distinct, well-connected humans willing to meet them. |
| **Reputation** | Are you trustworthy / known to *me*? | Partially, and only locally (paths, vouches). Not a global "good person" score — we explicitly don't build that. |

**Design consequence:** the score targets *distinctness and embeddedness*, never "how many friends" and never "how good a person." Everything downstream follows from this choice.

---

## 3. Why the obvious score fails

A raw **friend count** dies to three attacks immediately:

1. **Self-ceremony.** One person, two keys, taps themselves → a fake edge from nothing.
2. **Mutual inflation.** Two real people tap repeatedly → unbounded count from one relationship. (Mitigated by counting *distinct neighbors*, one edge per pair.)
3. **The ring / sock-puppet farm.** One operator with N keys taps them all together → a dense fake clique with a huge internal count.

Distinct-neighbor counting kills #1 and #2 but **not #3** — the ring has many distinct internal neighbors. The fix isn't a better *local* count; it's making the score *structural*. That's what the algorithms below buy us.

The key realisation, borrowed from the Sybil-defense literature: a fake cluster can have arbitrarily many edges *among itself*, but only a few **attack edges** — edges crossing from the fake region into the honest, densely-connected core. And in Seal an attack edge is uniquely expensive: it is a **real in-person ceremony with a real, already-trusted human**. You cannot phish or botnet your way across it. So if the score is built to ignore internal density and only reward connection to the honest core, the ring collapses to near-zero no matter how big it is.

---

## 4. What we borrow, and from where

Three classical algorithms, each contributing one idea. We are not adopting any wholesale.

### PageRank (Brin & Page)
*Idea we take:* a node is important if important nodes point to it — computed by **power iteration** to the principal eigenvector, with a **damping/teleport** term so rank can't be trapped or pumped in cycles. The teleport is what stops a pure cycle of links from manufacturing infinite rank. We reuse power iteration and the teleport-to-seed idea.

### EigenTrust (Kamvar, Schlosser, Garcia-Molina, 2003)
*Ideas we take:* (a) **normalize each node's outgoing trust to sum to 1**, so a malicious node can't assign arbitrarily large trust to its friends — it can only redistribute its own fixed budget; (b) **pre-trusted peers** — a seed set of known-good nodes that anchors the whole computation and is what makes it Sybil-*resistant* rather than Sybil-blind. EigenTrust's own paper notes that *without* seed trust the scheme is weak against Sybils; the seed set is load-bearing.

### SybilRank (Cao, Sirivianos, Yang, Pregueiro — used at Tuenti/Facebook scale)
*This is the closest fit and the spine of our design.* It computes, for each node, the **landing probability of short random walks that start from the trusted seeds, normalized by node degree**. The insight: short walks from the honest core are very unlikely to traverse the few attack edges into the Sybil region, so honest nodes get high degree-normalized landing probability and Sybils get near-zero. Crucially it uses **truncated (early-terminated) power iteration** — *few* iterations on purpose — so trust does **not** fully mix across the graph. With weighted edges, trust spreads proportionally to weight, which means a Sybil must build *more, higher-weight* attack edges to gain anything — i.e. more real in-person ceremonies.

We do **not** take: EigenRank (it's a collaborative-filtering ranking method for recommender systems — relevant only if/when we rank *content* in the Square, noted in §9, not for personhood).

---

## 5. ForgeRank — the Seal trust score

A degree-normalized, seeded, truncated power iteration over the forge graph. SybilRank adapted to a graph whose edges are cryptographic in-person ceremonies.

### 5.1 The graph
- **Nodes** = identities (root WebAuthn credential).
- **Edges** = forged friendships, undirected and deduped (**one edge per pair**, regardless of how many times they meet — re-meets raise *weight*, not count).
- **Edge weight `w(u,v)`** combines:
  - **Tier** of the counterparties — a ceremony with a **Verified** (hardware-key) human weighs more than one with a **standard** (passkey) human. Verified edges are costlier to fake, so they carry more trust.
  - **Diversity / recurrence** — meeting across *different months* or *different sub-communities* raises weight (a relationship with real duration, not one party). This is the cryptographic basis for "physical streaks" in VISION.
  - **Recency decay** — weight decays slowly over time so the graph reflects a *living* social life, not a 5-year-old snapshot. **Locked: ~18-month half-life** (an un-renewed edge keeps most of its weight for over a year). Forgiving enough not to punish real friends you see less often; still ages out stale graphs. Exact curve **[OPEN]** but anchored to that half-life.
  - **Vouched edges** (remote co-signed intros) carry a **fraction** of a real-meeting weight and are visibly dashed; they upgrade to full weight on an actual ceremony.

### 5.2 The seed set `S` (the trusted core)
The pre-trusted anchor. Total trust mass `1.0` is distributed across `S` and **nothing is trusted a priori outside it**. This is the single most important — and most dangerous — parameter. See decision **D2**.

### 5.3 The computation
Let `deg(v)` = weighted degree of `v`. Initialise trust `t` as the seed distribution. Then run a small number of iterations (`O(log N)`, "short walks"):

```
t ← seed_distribution                       # mass 1.0 on S, 0 elsewhere
repeat  k = O(log N)  times:                # truncated on purpose — short walks
    t'(v) = Σ_{u ~ v}  t(u) · w(u,v) / deg(u)    # spread, weight-proportional
    t   = (1−β)·t' + β·seed_distribution     # optional TrustRank-style teleport to S
score(v) = t(v) / deg(v)                     # degree-normalized landing probability
```

Then map `score` to a **percentile within the user's region/cohort**, not a raw global number (see §6 on why we never surface the raw value).

- **Why degree-normalize:** without it, high-degree hubs always win; with it, the score measures "trust per connection," which is what distinguishes a genuinely-embedded human from a popular Sybil hub.
- **Why truncate (few iterations):** long walks eventually reach everywhere and wash out the seed signal. Short walks stay near the honest core and rarely leak across attack edges — that *is* the defense.
- **`β` teleport:** optional. `β=0` is pure SybilRank; `β>0` is personalized-PageRank/TrustRank, more robust to seed dropout but mixes faster. Start `β=0`, tune later.

### 5.4 Why the ring dies (the load-bearing argument)
A sock-puppet farm of N fake keys is connected to the honest core **only through the genuine ceremonies the operator personally performed** — their own handful of real attack edges. Trust entering the farm is bounded by `≈ (mass arriving at those few edges)`, then **split across all N puppets**. So each puppet's score → ~0 as N grows. The farm's *total* stealable trust is capped by the operator's *own real* embeddedness, and dividing it among more fakes only dilutes each one. **You cannot inflate personhood by manufacturing accounts; you can only divide your own.** That is the whole game.

---

## 6. From score to claims — what users actually see

We do **not** show a global leaderboard rank. That recreates follower-count media — the exact thing VISION says we invert, and it instantly creates a number to farm. The score is mostly **invisible plumbing**, surfaced three honest ways:

1. **Truthful badges, not ranks.** A profile/post carries *facts*: `7 forged friendships · 2 Verified · active in 3 cities · forging since 2025`. Verifiable, signed, comparative-but-not-ranked. No "you are #4,182."
2. **Access, not status.** The score gates *capability*, primarily **the right to post in the Square** (e.g. ForgeRank above a regional percentile, or ≥ k distinct edges into the core). Reading is open; voice is earned. A Sybil army is useless because each fake voice still costs real ceremonies.
3. **Per-viewer paths.** "This person is 2 taps from you, via Alice." A trust signal computed *relative to you*, which is far more meaningful — and harder to game — than any global figure. This doubles as the discovery mechanic ("paths, not search").

**Later (§9):** zero-knowledge claims — prove "I have ≥3 Verified friendships" or "ForgeRank > 90th percentile" **without revealing who or the number**, exportable as a "verify with Seal" primitive for other apps.

---

## 7. The five core decisions — LOCKED 2026-06-13

| # | Decision | Locked choice | Rationale |
|---|---|---|---|
| **D1** | **Edge-weight formula** | **Minimal, then iterate.** `w = tier_factor × recency_decay` plus a small discrete bonus for re-meeting in a *new month*. Add further factors only after observing real distributions. | Explainable and hard to game by accident. Keeps the first build's behavior legible; richer factors (community diversity, vouch fraction) are additive later. |
| **D2** | **Seed set `S`** | **Vetted start → auto-decentralize.** Bootstrap with founder edges + a few *manually vetted* early Verified users; **auto-promote** anyone sustaining a high ForgeRank percentile over several epochs into `S`. | Gives the score meaning at cold-start without making founders permanent kingmakers. The anchor spreads out as the honest graph grows. |
| **D3** | **Graph privacy** | **Counts public, edges private.** Public: counts, badges, tier mix. Private: the **identities** of your edges. Paths revealed only with **mutual consent** of both endpoints. | Preserves discovery and truthful badges while treating who-met-whom as the intimate, safety-sensitive data it is. |
| **D4** | **Trust healing** | **Passive only, at launch.** No explicit downvote. Bad actors fall via edge-decay + friends un-forging. Negative attestations (SybilFence-style, costly/non-anonymous/rate-limited) deferred — revisit only if a real need appears. **[OPEN: whether to ever add them]** | Cannot be weaponized for harassment. Slower to react, but the failure mode of a reputation-destruction tool is worse than slowness. |
| **D5** | **What the score unlocks** | **Access + truthful facts only.** Gates posting/reach and produces honest badges; **never a public rank, never purchasable.** Revenue = Verified tier, key sales, events — not score. | This is the one-way door. Tying money or visible rank to the score corrupts proof-of-humanity into pay-to-look-human and recreates follower-count media. |

**Recency half-life (D1 sub-parameter): ~18 months.** Forgiving toward real friends seen less often; still ages out stale graphs.

---

## 8. Threat model (graph layer)

| Attack | Mechanism | Defense |
|---|---|---|
| **Self-ceremony** | One person, multiple keys, taps self. | Distinct-neighbor counting; the self-cluster has no edges to the honest core → ForgeRank ~0. Plus 1-key-1-identity exclusion (SDS §7). |
| **Mutual inflation** | Two real people re-tap for count. | One edge per pair; re-meets raise weight sub-linearly, not count. |
| **Sock-puppet ring** | N keys, dense internal forging. | Degree-normalized truncated power iteration: trust bounded by the operator's *real* attack edges, then divided across N → each ~0. (§5.4) |
| **Infiltration / bridge-building** | Operator does real ceremonies to gain attack edges, then mints puppets behind them. | Cost scales with *real meetings*; weighted edges mean puppets need *high-weight* (Verified, recurring) attack edges, which are the hardest to fake. Detectable as anomalous fan-out behind a single bridge node. |
| **Seed capture** | Compromise/bias the trusted core. | D2 auto-decentralization; multiple seeds so no single point; monitor seed-set composition. |
| **Vouch abuse** | Spam weak remote intros. | Vouched edges carry fractional weight, are dashed, rate-limited per vouching identity, and decay if never upgraded by a real meeting. |

---

## 9. Phased rollout

1. **Instrument first.** Compute ForgeRank *server-side-free* on-device from the public directory; log distributions; **don't surface it.** Validate that honest test clusters and a deliberately-built fake ring separate cleanly before any gating goes live.
2. **Badges** (truthful facts) — low risk, immediate value, no gating.
3. **Paths + vouched intros** — discovery without a feed.
4. **The Square, per-city, read-open / post-gated** — the first place ForgeRank controls access. Watch for farming; tune D1/D2.
5. **ZK claims + "verify with Seal"** — export the primitive.
6. *(Maybe, much later)* **content ranking** inside the Square — *this* is where EigenRank-style methods could rank posts, a separate problem from personhood. Out of scope until consumer traction.

---

## 10. References

- S. Kamvar, M. Schlosser, H. Garcia-Molina. *The EigenTrust Algorithm for Reputation Management in P2P Networks.* WWW 2003. — normalized local trust, pre-trusted peers, power iteration. <https://nlp.stanford.edu/pubs/eigentrust.pdf>
- L. Page, S. Brin, et al. *The PageRank Citation Ranking.* — power iteration, damping/teleport.
- Q. Cao, M. Sirivianos, X. Yang, T. Pregueiro. *Aiding the Detection of Fake Accounts in Large Scale Social Online Services (SybilRank).* NSDI 2012. — degree-normalized short-walk landing probability; deployed at Tuenti.
- H. Yu, P. Gibbons, M. Kaminsky, F. Xiao. *SybilLimit: A Near-Optimal Social Network Defense against Sybil Attacks.* — attack-edge bound, O(log n) Sybils per attack edge.
- Alvisi, Clement, Epasto, Lattanzi, Panconesi. *SoK: The Evolution of Sybil Defense via Social Networks.* IEEE S&P 2013. — survey framing of attack edges and trust propagation.
- SybilFence (negative feedback) — basis for the cautious D4 negative-attestation path.

*Core decisions D1–D5 locked 2026-06-13. Remaining open tuning: exact `tier_factor` values, D2 promotion percentile + epoch count, exact recency curve (half-life fixed at ~18mo), whether D4 ever adds negative attestations, ZK claim circuits, and the Square posting threshold.*
