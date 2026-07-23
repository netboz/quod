# How quod stores and shares knowledge — a plain-language guide

quod lets many computers share collections of facts and keep them in sync, with no
central server. This guide explains how, end to end, with no special background
assumed. The original decisions and trade-offs are preserved in
`content-layer-design.md`; `ordering-layer-spec.md` is the superseded Raft plan.
The current consensus design is `simplex_extended.pdf`; **how ontologies name each
other's things and ask each other questions is specified in `inter-ontology.md`**;
unfinished work is tracked in `deferred.md`.

Two words you'll see throughout:

- An **ontology** is a collection of facts and rules — *a cat is an animal*,
  *animals have legs*, and so on. It's quod's unit of shared knowledge.
- These are written in **Prolog**, a language where you state facts and rules and
  then ask questions, and the system works out the answer from what it knows.

---

## 1. The shape of the problem

We want a network of computers to share ontologies. Two things make this hard:

1. **There's no central server.** The computers find each other and agree among
   themselves.
2. **Content comes in two very different kinds**, which need opposite treatment.
   Some of it — the categories things fall into (a dog is a kind of animal), who
   owns what, the overall structure of the world — changes rarely, but everyone
   must agree on it exactly. Other content — where things are, how they're moving —
   changes constantly, and a lost update doesn't matter because a fresh one arrives
   a split-second later. We'll call this fast-moving kind **physics**.

These two kinds travel on separate routes:

| | Structural facts | Physics |
|---|---|---|
| Changes | rarely | constantly |
| A lost update | must never happen | is fine — the next one fixes it |
| Route | careful, ordered, agreed | quick, send-and-forget |

Most of this guide is about the careful route. Physics gets a short section near
the end.

> One honest wrinkle up front: "fast-changing" and "physics" are *not* the same
> thing. A few facts — who's holding the sword, whether the door is open — change
> often *and* must be agreed on exactly. Those take the careful route and pay its
> cost; only truly throwaway state (position, motion) takes the quick one. We come
> back to this in section 12.

---

## 2. The one idea everything is built on

Here's the move the whole design rests on: **don't try to predict what a question
will do — run it and watch what it touches.**

Why you can't predict: in Prolog, asking a question can quietly *change* things. A
rule, while working out an answer, can add or remove facts. For example, a rule
answering "find me a free meeting room" might *book* the room it finds — the
looking and the changing are tangled together. And a question can reach across into
other ontologies. So you genuinely can't tell, before running it, whether a question
will change anything or which ontologies it'll touch. You only find out by running
it.

So we run it and watch. The question runs against a private throwaway copy (so the
real data isn't touched until we're sure), and we record two things:

- **what it read** — the facts it looked at, and
- **what it changed** — the facts it added or removed.

Together, these two are the question's *footprint* — the marks it left. Once the
question finishes, its nature is obvious:

- **It changed nothing** → it was just a *read*. Hand back the answer; done.
- **It changed something** → it's a *change* that has to be recorded and agreed.

This "run it, then look at the footprint" approach is what lets everything else —
links between ontologies, change notifications, agreement between computers — be
*one* method instead of many separate ones.

There's one more twist. Between running a change on the throwaway copy and making it
official, the world can move — someone else may have changed a fact this change
relied on. So at the moment of making it official, the system re-checks that
everything the change *read* is still true. If it isn't, the change is rejected and
the asker simply tries again. (This is why recording "what it read" matters as much
as "what it changed.")

A small practical note: when a question does change facts, those changes are made as
a clean final step *after* the answer is found, not scattered through the search.
That keeps things tidy and matches how Prolog already works.

---

## 3. Ontologies that reach into each other

Think of each ontology as a separate notebook of facts. Most of the time a question
stays inside one notebook. Two marks reach across (`inter-ontology.md` is the full
specification):

- **`::` asks** — run a question over in another notebook:

```prolog
animals::diet(dog, D)
```

That reads: "work this out over in the *animals* ontology." (`D` is a blank for the
system to fill in — so this is asking "what does a dog eat?")

By default a name is local; a written mark is the only way to cross into another
notebook. That keeps things simple — there's no single master list of which ontology
owns which word, and no confusion when two ontologies happen to use the same name.
(Notebook names themselves carry their owner — `user_xxx:door` is user_xxx's door
notebook — so everyone can have a `door` without collisions.)

- **`:` names** — a *link* between two ontologies — "my_dog is a kind of the `dog`
  that lives in the animals notebook" — is just a fact that *points* across a
  boundary:

```prolog
isa(my_dog, animals:dog)
```

Notice this is a stored fact, not a question — it just *names* something in another
notebook. The system only actually reaches across when it needs something it doesn't
have at home. Asking "is my_dog a dog?" is answered right here from the local fact;
but asking "what does my_dog eat?" has to hop over to *animals*, because the answer
lives there. So a link (`:`) and an ask (`::`) are the same idea at different sizes: a
link names a thing across the boundary, and following it becomes an ask when you
actually need what's over there. Every relation follows its links this way by
default — an ontology that wants a relation's foreign names left alone states a
`no_follow` fact for it.

Because these links are just facts, the **web of connections between ontologies
builds itself** as questions run. We don't draw the map by hand — it emerges from
use, and we keep a directory of it for two jobs: knowing where to send a
cross-notebook question, and knowing who to tell when something changes (next
section).

---

## 4. Reading something means watching it

Here's a nice payoff from recording "what a question read." When the *pets* notebook
reads a fact that lives in the *animals* notebook, pets automatically becomes
*interested* in that fact — without having to say so. So if animals later changes
it, the system already knows exactly who to tell: everyone whose recent questions
read it.

You never declare "please notify me when this changes" — **reading it is subscribing
to it.** That gives change notifications across the whole network essentially for
free, and the kind of link tells the system where to send each one.

(The honest catch: today the system tracks interest in broad *groups* of facts, not
single ones — for example, all "door" facts together rather than one specific door.
So a change to one door can ping everyone watching any door. For rarely-changing
things that's harmless; making it fact-by-fact precise is a later refinement.)

---

## 5. Who's allowed to change what

A fact belongs to the ontology that holds it, and **only that ontology may change
it.** Each ontology is the one that decides its own permissions and runs its own
rules when something is added or changed (adding a fact can trigger other rules,
fill in default values, and so on). *(Today the permission checks are stubbed —
computers trust each other's stated names; real checks arrive with the
trust-the-stranger work in section 9. This section describes the intended shape.)*

That has a clean consequence: to change something in another ontology, you can't
just reach in and overwrite it — you have to **ask the owner to do it**, through the
owner's own rules. "Inventory, please add this sword" — not "I'll just stick this
sword in your inventory."

For now we keep it simple: a question may **read** across ontologies freely, but may
only **change** facts in its own. Changing facts across ontologies — moving a sword
out of one notebook's chest and into another's bag — is genuinely harder: you must
make sure the sword isn't lost or duplicated if something fails halfway. **And this
is not an exotic case — it's the common one.** Every trade, pickup, and crafting
recipe in a game moves something between ontologies. So it matters a lot; it's just
the next big thing to build, not a corner case. When we add it, the safe default
will be **all or nothing** — both the take and the give happen, or neither does.

---

## 6. How a network of computers agrees on changes

When several computers hold the same ontology, they must agree on the **order** of
changes, so they all end up identical. (Order matters: if one computer adds a rule
and another removes it, the final result depends on which happened first.) The
mechanism is a small **committee**.

### The committee

Each ontology is run by a small group of computers — say 4 or 7 — that holds it and
agrees on every change.

- One member is **in charge** for each numbered slot. It collects a short ordered
  batch of incoming changes into a **block** and sends that block to the others. A block
  becomes official once **more than two-thirds** of the committee has signed off on it.
- A change that arrives while the current block is already sealed is not turned away:
  because everyone can compute whose turn comes next, it is sent **straight to the
  member whose turn is coming** and **waits in a bounded line there**, pouring into
  that block the moment the turn opens — block N+1 naturally carries everything that
  arrived during block N, already in place, with no bouncing between members. The line
  is first-come-first-served (so a waiting membership change drains the pipeline
  instead of being overtaken), each member gets a fair share of it, and a request only
  hears "busy" when the line truly overflows or the cluster is genuinely stalled —
  which makes "busy" an alarm, not a retry hint.
- Once a block has enough first-stage support, the next slot may begin while final
  signatures for the parent are still arriving. The pipeline is deliberately only one
  slot deep, and membership changes stop it until they are durably committed. Demand
  already received for that next slot is retained while the parent finishes, then
  becomes the watched head without requiring the client to submit it again.
- If the one in charge stalls or goes quiet, the others **agree to skip it** and move
  on to the next, in a second or two. No human involved.
- Each node keeps one explicit watchdog on the **oldest unfinished slot**. It follows
  that slot from proposal, through first-stage approval, until durable commit or skip;
  approval never cancels finality recovery. Complaint voting pauses unless enough
  validators have both a live authenticated consensus stream and a fresh report that
  they are caught up to the local committed height. A socket opened by a still-recovering
  process therefore does not count as a voter. The first three readiness restorations for
  one unchanged phase grant a fresh timeout; later flaps cannot keep moving the deadline.
  A recovering validator processes a valid proposal it retained through the ordinary
  support or membership-check path. If it already has a notarization certificate, it
  resumes only the missing final vote and never invents support that bypasses validation.
  Before sending any support, commit, or skip signature, it records that small decision
  durably; restarting cannot make it vote differently. One final-vote rule covers both
  live pipeline slots: if enough peers already chose skip, an uncommitted validator joins
  them even when the block was approved meanwhile; otherwise a notarized block selects commit.
  A node that has the approval certificate but not the block asks one candidate holder at a
  time, trying certificate signers before the rest of the committee, and verifies both block
  and certificate before using them; no knowledge-base or full proposal copy is written to
  this journal.
  A final certificate beyond the block frontier also makes the node stop voting and recover
  the missing committed entry from the durable log, including when it is only one block behind.
  When quorum returns before notarization, a validator that already supported the proposal
  re-sends that support once and waits one final timeout before it may complain; this gives
  the leader's retained proposal time to reach a recovered validator without allowing an
  endless retry loop.
  Consensus connections and queued frames are scoped to the current committee: a committed
  membership change closes and forgets transport state for every departed validator.
  This improves **liveness** when a deployment temporarily loses more nodes than its normal
  fault-tolerance bound, while durable vote decisions keep crash-restarted validators honest.
  The Byzantine guarantee still assumes no more than the normal fault bound are malicious.
  A simultaneous, mutually hidden split between final votes remains a later view-change job.

Why "more than two-thirds"? Because any two "more than two-thirds" groups overlap by
enough that they always share at least one **honest** computer — and an honest
computer won't sign two conflicting blocks. So even if some members are actively
lying, the committee can never agree to two different versions of history. That's the
whole safety argument, in one sentence.

The clever part: a committee of **one computer** is just "one computer in charge" —
the simple setup you'd run on your laptop. Grow the *same* committee to 4 or 7 and it
survives some members dying **or lying**, with no change to the code. So "simple now"
and "robust later" aren't two designs — they're one design, sized to taste.

*(For the curious: this is a streamlined **Byzantine** agreement recipe called
**DispersedSimplex** — the modern family payment networks use, which keeps agreeing
even if some members are not just offline but actively lying. We build our own lean
version rather than add a large piece of outside software.)*

### Who sits on the committee is part of the ontology

Committee membership is itself stored as facts in the ontology, and a computer that
wants to join is let in only if it passes a "may I join?" test the ontology defines.
The committee is deliberately **stable** — it changes only on purpose (a member
joins or leaves, and that itself is recorded as a block). That stability is exactly
what lets it keep an exact record.

### Finding the computers vs. running the ontology

Two layers, doing different jobs:

- **Discovery** — a background layer (we call it Brahms) where every computer
  casually passes along which others it has seen lately, like rumors spreading
  through a crowd. It's how computers *find* each other. It doesn't hold ontologies
  or order anything.
- **The committee** — the small, fixed group that actually holds one ontology and
  agrees on its changes.

So discovery *finds* candidates; the committee is the small subset that actually
runs the show. Being one of the many computers out there is not the same as being on
a committee.

---

## 7. The history is a permanent, browsable record

Keep two things separate:

- **The current facts** — the ontology as it is right now, what questions read.
- **The history** — the ordered list of every change ever made (the blocks). If you
  start from nothing and apply every change in order, you get back the current
  facts.

We keep the **full history, forever, and make it browsable** — a permanent record,
like a logbook you can page through on a web page. It's saved to disk on the
committee members. (Normally quod saves nothing to disk; the history is the one
deliberate exception, because everything else can be rebuilt from it. The rule is:
*save the history; rebuild the rest from it.*) Trimming old history to save space is
an option we can add later; by default we keep everything.

For now the history lives only on the committee members. Later, an ontology will be
able to name extra computers that should also keep a full copy — again, just by
stating it as a fact.

---

## 8. Reading is cheap — it doesn't go through the committee

A natural worry: if a popular ontology — say `root`, the basic one everyone builds
on — is run by just 3 computers, does every lookup pile onto those 3?

No — because **the committee is only the authority for *changing* an ontology.**
Reading it needs nothing more than *a copy of the current facts*, and copies can be
everywhere:

1. **Your own cached copy** — for things that rarely change (like the category
   structure), a computer keeps its own copy and is only pinged on the rare change.
   In normal running, a lookup in `root` is answered right on the asking computer,
   with no network at all.
2. **A nearby copy** — one short step away to a neighbouring computer, not all the
   way to the committee.
3. **The committee itself** — only when you need the guaranteed-latest value, which
   is rare.

So the 3 committee computers only carry that ontology's *changes*, and a foundational
ontology like `root` is barely ever changed. If some *other* ontology turns out to
be changed heavily, the fix is to split it into smaller ontologies, each with its
own committee — more committees sharing the load, all working at the same time.

---

## 9. Surviving crashes and lies

The committee protocol now handles both computers that **crash** and computers that
**lie**. Every vote is signed with the member's Ed25519 identity, and a block is final
only with a certificate containing distinct signatures from more than two-thirds of
the current committee. With `3f+1` members, this preserves one history while up to `f`
members are Byzantine.

That does not make every write authorized. Every non-genesis transaction is now
signed by its author and bound to its ontology, but signatures prove identity,
not permission. Until the user/agent capability and membership authorization
policies land, deployment inside a trusted administrative fleet remains the
security boundary for who may request a write.

---

## 10. After a change is agreed: reactions

Once a change is official, three things happen, in order:

1. **The facts change** — the add or remove is applied.
2. **Summaries update** — anything the system keeps that's calculated from the facts
   (quick-lookup tables, the "who's watching what" list, and later things like a
   visual view of the world) is recomputed. This happens immediately, before anyone
   is told, so that by the time you're notified everything lines up.
3. **Reactions happen** — rules that say "when X happens, do Y" now run, messages go
   out, screens update. This is the outward-facing part, and it happens only for a
   genuinely *new* change.

That last point carries the one rule that's easy to get wrong: **when a computer
replays old history** — catching up after falling behind, or rebuilding after a
restart — **it must redo the fact changes but must NOT redo the reactions.**
Otherwise a computer catching up on a thousand old changes would re-send a thousand
old messages. (An earlier, related system handled this badly and only worked by
chance; here the rule is explicit.)

Reactions, like everything else, are just facts: "when this kind of change happens,
run this." This reaction system — together with the cross-ontology notifications
from section 4 — is the next thing to build once the core is solid. The first build
already handles the narrow, safe version of it.

---

## 11. The physics side route

Fast-moving state — positions, motion, anything that updates moment to moment — does
**not** go through the committee or the history. That would be far too slow, and it
doesn't need to be exact. Instead:

- Each moving thing has one computer in charge of it — its **owner** — that
  calculates how it moves. (Same "only the owner may change it" idea as section 5,
  just applied to a moving object instead of a fact.) Every other computer keeps a
  lightweight read-only copy that just mirrors the owner.
- Updates spread by quick, send-and-forget broadcasts. One that gets lost is simply
  overwritten by the next one a moment later.

So physics is a fast, lossy route running alongside the careful one. The only time
the two meet is when something owned by one computer affects something owned by
another — say a push from one area shoves an object that belongs to a different area
— and that has to go politely through the owner, the same "ask the owner" rule as
section 5.

---

## 12. What's settled, and what's still open

**Settled:**

- Run a question, watch what it read and changed; that footprint is the basic
  building block the whole system uses.
- A change is re-checked at the moment it's made official; if something it relied on
  changed underneath it, it's rejected and retried.
- `:` names a thing in another ontology, `::` asks it a question (`inter-ontology.md`);
  reading across is allowed now, changing across is deferred.
- Reading a fact subscribes you to it — that's the notification system.
- Each ontology is run by a small committee that agrees on an ordered list of
  changes; one computer grows to several with the same code.
- The full change history is kept permanently and is browsable.
- Reads are served by cheap copies and caches, not the committee, so popular
  ontologies don't bottleneck.
- Signed Byzantine agreement tolerates crashes and lying committee members.
- Physics is a separate fast, lossy route.

**Still open (and honestly so):**

- **Changing facts across ontologies** — the move-it-without-losing-or-duplicating
  problem. It's common (every trade and pickup), so it matters; it's deferred, and
  the safe **all-or-nothing** version comes next.
- **Fast *and* exact** — some game-state changes (who holds the sword, is the door
  open) are both frequent and must-be-agreed, so today they pay the careful route's
  cost. Whether they deserve a third, faster route is still open.
- **Write authorization** — committee identities and votes are signed, but transaction
  authors are not yet cryptographically bound to their requests. Membership therefore
  remains restricted to a trusted administrative fleet.
- **Reading two ontologies at once** can catch each at a slightly different instant,
  so they may not perfectly line up. We accept that for now.
- **Notification precision** — today we notify about whole groups of facts at once,
  not single facts.

---

## 13. Where the build stands

The careful route is running: each ontology has a signed Byzantine committee, a
durable ordered history, trustless catch-up, deterministic Prolog apply, optimistic
conflict checks, short transaction batches, and a one-block consensus pipeline.
`ordering-layer-spec.md` records the superseded Raft design; the current consensus
implementation and `simplex_extended.pdf` are authoritative. The remaining work is
tracked in `deferred.md`, especially author-aware authorization, epoch-frozen
membership, cross-ontology writes, and history compaction.
